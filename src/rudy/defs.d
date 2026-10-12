/// `def!` — register a D function as a Ruby method, with automatic
/// argument unwrapping (VALUE -> native D) and result rewrapping
/// (native D -> VALUE). The 2010 original passed raw VALUEs through;
/// this one finally does the wrapping PyD-style.
///
///     def!(myFunc);                     // global (Kernel) function
///     def!("MyClass", myFunc);          // instance method of MyClass
///     def!("MyModule", myFunc);         // module function
///
/// The D function may take native D types (int, double, string, ...) as
/// parameters; each argument is converted from the incoming VALUE with
/// d_type!T, and the return value goes back through to_ruby_value.
///
/// ---
///
/// Special parameter types (rudy/args.d) extend the model beyond fixed
/// positional arguments:
///
///   RubyBlock (last param)  — receives the caller's block as a Proc;
///                             blk.call(...) invokes it; blk.given says
///                             whether a block was passed at all.
///   Rest                    — captures *rest into a Ruby Array.
///   KwArgs                  — captures **kwargs into a Ruby Hash
///                             (given()==false when none passed).
///   Self (first param)      — the receiver as raw VALUE.
///   Raw!T                   — opt-in raw VALUE passthrough.
///
/// Any def!'d function using a special parameter (or D default args) is
/// registered with arity -1 (argc/argv style); rb_scan_args splits the
/// arguments per a compile-time-generated format string and raises the
/// standard ArgumentError on wrong arity. Plain fixed-arity functions
/// go through the same uniform trampoline (also registered -1): one
/// code path for every def!'d method.
module rudy.defs;

import rudy.bind.value;
import rudy.convert;
import rudy.args;
import std.traits;
import std.string : toStringz;
import std.conv : to;
import std.meta : AliasSeq, anySatisfy;
import std.algorithm.iteration : splitter;

private:

// ------------------------------------------------------------------
// Parameter classification
// ------------------------------------------------------------------

/// True for parameter types the trampoline fills in ITSELF (never
/// decoded from a positional VALUE): the rudy/args.d wrappers, the
/// Self receiver, and the opt-in Raw!T passthrough.
template isValueParam(T)
{
    static if (is(T == RubyBlock) || is(T == Rest) || is(T == KwArgs)
               || is(T == Self) || isRaw!T)
        enum bool isValueParam = true;
    else
        enum bool isValueParam = false;
}

/// Decode one positional argument VALUE into parameter type T.
/// Raw!T passthrough wraps the bits; everything else goes through
/// d_type!T. (There is deliberately no plain-VALUE branch: VALUE is
/// aliased to ulong, and a ulong parameter means "Ruby Integer ->
/// machine word", NOT raw passthrough — see issue #1.)
T argFrom(T)(VALUE v)
{
    static if (isRaw!T)
        return T(v);
    else
    {
        static assert(!isValueParam!T, "def!: " ~ T.stringof
                      ~ " is filled by the trampoline, not decoded from argv");
        return d_type!T(v);
    }
}

private template isRestParam(T)  { enum bool isRestParam = is(T == Rest);     }
private template isKwParam(T)    { enum bool isKwParam   = is(T == KwArgs);   }
private template isBlockParam(T) { enum bool isBlockParam = is(T == RubyBlock); }
private template isSelfParam(T)  { enum bool isSelfParam = is(T == Self);     }

/// Index of the first parameter satisfying pred, or -1.
template findIdx(alias pred, P...)
{
    static if (P.length == 0)
        enum int findIdx = -1;
    else static if (pred!(P[0]))
        enum int findIdx = 0;
    else
        enum int findIdx = findIdx!(pred, P[1 .. $]) == -1
            ? -1 : 1 + findIdx!(pred, P[1 .. $]);
}

// ------------------------------------------------------------------
// ArgInfo: compile-time layout of a def!'d function's parameters.
//
// nLead / nOpt / nTrail / hasAsterisk — pieces of the rb_scan_args
//   format string. At most one of { Rest, KwArgs, RubyBlock } per
//   function (static assert'ed).
// posSlots — decodable positional slots in scan order (mandatory
//   first, then optional): each element is the parameter index it
//   maps to.
// restIdx / kwIdx / blkIdx / selfIdx — parameter indices, -1 when
//   absent; filled by the trampoline (self from the self argument).
// ------------------------------------------------------------------

struct ArgInfo(alias fn)
{
    alias P = Parameters!(typeof(&fn));
    alias DEFAULTS = ParameterDefaults!(fn);

    enum bool hasRest  = anySatisfy!(isRestParam, P);
    enum bool hasKw    = anySatisfy!(isKwParam, P);
    enum bool hasBlock = anySatisfy!(isBlockParam, P);
    enum bool hasSelf  = anySatisfy!(isSelfParam, P);

    enum int restIdx  = findIdx!(isRestParam, P);
    enum int kwIdx    = findIdx!(isKwParam, P);
    enum int blkIdx   = findIdx!(isBlockParam, P);
    enum int selfIdx  = findIdx!(isSelfParam, P);

    // positional classification of one parameter: is it a decodable
    // argv slot, and must the caller supply it? Raw!T params are
    // ordinary positional slots (raw passthrough instead of d_type).
    template slotKind(size_t i)
    {
        static if (is(P[i] == RubyBlock) || is(P[i] == Rest)
                   || is(P[i] == KwArgs) || is(P[i] == Self))
            enum string slotKind = "none";      // filled by trampoline
        else static if (!is(DEFAULTS[i] == void))
            enum string slotKind = "opt";       // optional positional
        else
            enum string slotKind = "req";       // mandatory positional
    }

    enum nLead  = countLead;
    enum nOpt   = countOpt;
    enum nTrail = 0;                    // trailing mandatory after splat:
                                        // not supported yet
    enum bool hasAsterisk = hasRest;

    // positional slots in scan order: mandatory first, then optional
    template posSlotsOf(size_t i = 0)
    {
        static if (i >= P.length)
            alias posSlotsOf = AliasSeq!();
        else static if (slotKind!i == "none")
            alias posSlotsOf = posSlotsOf!(i + 1);
        else static if (slotKind!i == "req")
            alias posSlotsOf = AliasSeq!(i, posSlotsOf!(i + 1));
        else
            alias posSlotsOf = AliasSeq!(i, posSlotsOf!(i + 1));
    }
    alias posSlots = posSlotsOf!();

    // mandatory = leading run of "req" slots in scan order
    private template countLeadImpl(size_t i, int acc)
    {
        static if (i >= P.length || slotKind!i != "req")
            enum int countLeadImpl = acc;
        else
            enum int countLeadImpl = countLeadImpl!(i + 1, acc + 1);
    }
    enum int countLead = countLeadImpl!(0, 0);

    enum int countOpt = posSlots.length - countLead;

    // DEBUG

    static assert(!(hasRest && hasKw), "def!: Rest + KwArgs in one function not supported yet");
    static assert(blkIdx == -1 || blkIdx == P.length - 1,
                  "def!: RubyBlock must be the LAST parameter");
    static assert(countLead + countOpt + (hasRest ? 1 : 0)
                  + (hasKw || hasBlock ? 1 : 0) + (hasSelf ? 1 : 0)
                  == P.length,
                  "def!: unsupported parameter layout — special params (Rest/KwArgs/RubyBlock/Self) must not carry D default values");
}

// ------------------------------------------------------------------
// rb_scan_args format string, generated at compile time:
//   digits: nLead, then nOpt, then '*' when hasRest, then nTrail, then
//   ':' when hasKw, then '&' when hasBlock.
// Examples: "0" (no args), "1", "12&" (1 req + up to 2 opt + block),
// "1*", "2*:", "0&", "1*&" (1 req + *rest + block).
// ------------------------------------------------------------------

private string scanFmt(alias AI)()
{
    string s;
    static if (AI.nLead > 0)
        s ~= AI.nLead.to!string;
    static if (AI.nOpt > 0)
        s ~= AI.nOpt.to!string;
    static if (AI.hasAsterisk)
        s ~= "*";
    static if (AI.nTrail > 0)
        s ~= AI.nTrail.to!string;
    static if (AI.hasKw)
        s ~= ":";
    static if (AI.hasBlock)
        s ~= "&";
    if (s.length == 0)
        s = "0";                    // zero-arg functions still get the
                                    // argc == 0 arity check
    return s;
}

// ------------------------------------------------------------------
// The one uniform trampoline. Registered with arity -1 for every
// def!'d function; Ruby calls it as
//   VALUE f(int argc, const(VALUE)* argv, VALUE self)
// (the classic variadic C-method ABI). rb_scan_args splits argv per
// the generated format (raising the standard ArgumentError on wrong
// arity), omitted optional slots become Qnil, and wrappers
// (Rest/KwArgs/RubyBlock) + Self/Raw slots are filled directly.
// ------------------------------------------------------------------

extern(C)
VALUE rudy_trampoline_var(alias fn)(int argc, const(VALUE)* argv, VALUE self)
{
    alias AI = ArgInfo!(fn);
    alias P = Parameters!(typeof(&fn));
    alias DEFAULTS = ParameterDefaults!(fn);
    alias SLOTS = AI.posSlots;

    P args;                                       // default-initialized

    // rb_scan_args targets (positional slots in scan order); optional
    // slots omitted by the caller are filled with Qnil by Ruby itself.
    static if (SLOTS.length > 0)
        VALUE[SLOTS.length] slotVals = Qnil_;

    // NB: rb_scan_args' vararg order is FORMAT ORDER — '*' slot first,
    // then ':' tail, then '&' tail. Rest+block is therefore two targets:
    // restAry AND tail. KwArgs + RubyBlock can't coexist (: then & would
    // be fine, but a function taking both kwargs and a block with the
    // same Hash/Proc split is untestable through get!T semantics — see
    // the static assert below).
    static if (AI.hasRest)
    {
        VALUE restAry = Qnil_;
        static if (AI.hasBlock)
        {
            VALUE tail = Qnil_;                   // '&' after '*'
            static if (SLOTS.length == 0)
                rb_scan_args(argc, argv, toStringz(scanFmt!(AI)), &restAry, &tail);
            else static if (SLOTS.length == 1)
                rb_scan_args(argc, argv, toStringz(scanFmt!(AI)),
                             &slotVals[0], &restAry, &tail);
            else static if (SLOTS.length == 2)
                rb_scan_args(argc, argv, toStringz(scanFmt!(AI)),
                             &slotVals[0], &slotVals[1], &restAry, &tail);
            else static if (SLOTS.length == 3)
                rb_scan_args(argc, argv, toStringz(scanFmt!(AI)),
                             &slotVals[0], &slotVals[1], &slotVals[2], &restAry, &tail);
            else
                static assert(0, "def!: max 3 positional slots + special params");
        }
        else static if (SLOTS.length == 0)
            rb_scan_args(argc, argv, toStringz(scanFmt!(AI)), &restAry);
        else static if (SLOTS.length == 1)
            rb_scan_args(argc, argv, toStringz(scanFmt!(AI)),
                         &slotVals[0], &restAry);
        else static if (SLOTS.length == 2)
            rb_scan_args(argc, argv, toStringz(scanFmt!(AI)),
                         &slotVals[0], &slotVals[1], &restAry);
        else static if (SLOTS.length == 3)
            rb_scan_args(argc, argv, toStringz(scanFmt!(AI)),
                         &slotVals[0], &slotVals[1], &slotVals[2], &restAry);
        else
            static assert(0, "def!: max 3 positional slots + special params");
    }
    else static if (AI.hasKw || AI.hasBlock)
    {
        VALUE tail = Qnil_;                       // kwargs hash / block proc
        static if (SLOTS.length == 0)
            rb_scan_args(argc, argv, toStringz(scanFmt!(AI)), &tail);
        else static if (SLOTS.length == 1)
            rb_scan_args(argc, argv, toStringz(scanFmt!(AI)),
                         &slotVals[0], &tail);
        else static if (SLOTS.length == 2)
            rb_scan_args(argc, argv, toStringz(scanFmt!(AI)),
                         &slotVals[0], &slotVals[1], &tail);
        else static if (SLOTS.length == 3)
            rb_scan_args(argc, argv, toStringz(scanFmt!(AI)),
                         &slotVals[0], &slotVals[1], &slotVals[2], &tail);
        else
            static assert(0, "def!: max 3 positional slots + special params");
    }
    else static if (SLOTS.length > 0)
    {
        static if (SLOTS.length == 1)
            rb_scan_args(argc, argv, toStringz(scanFmt!(AI)), &slotVals[0]);
        else static if (SLOTS.length == 2)
            rb_scan_args(argc, argv, toStringz(scanFmt!(AI)),
                         &slotVals[0], &slotVals[1]);
        else static if (SLOTS.length == 3)
            rb_scan_args(argc, argv, toStringz(scanFmt!(AI)),
                         &slotVals[0], &slotVals[1], &slotVals[2]);
        else
            static assert(0, "def!: max 3 positional slots (extend the ladder for more)");
    }

    // fill wrapper params from the scan results
    static if (AI.hasRest)
        args[AI.restIdx] = Rest(restAry);
    static if (AI.hasKw)
        args[AI.kwIdx] = KwArgs(tail);
    static if (AI.hasBlock)
        args[AI.blkIdx] = RubyBlock(tail);
    static if (AI.hasSelf)
        args[AI.selfIdx] = Self(self);

    // decode positional slots; D default values substitute for omitted
    // optional arguments (Qnil means "not supplied"). Two-var static
    // foreach: si = slot position (argv order), i = parameter index.
    // NB: an AliasSeq passed as an alias template arg EXPANDS into
    // separate args (a slotPos!(SLOTS, i) helper died exactly that
    // way) - iterating it in foreach is the safe pattern.
    static foreach (si, i; SLOTS)
    {{
        static if (is(DEFAULTS[i] == void))
            args[i] = argFrom!(P[i])(slotVals[si]);
        else
        {
            if (slotVals[si] == Qnil_)
            {
                static if (is(P[i] == VALUE))
                    args[i] = cast(VALUE) DEFAULTS[i];
                else static if (isRaw!(P[i]))
                    args[i] = P[i](cast(VALUE) DEFAULTS[i]);
                else
                    args[i] = DEFAULTS[i];
            }
            else
                args[i] = argFrom!(P[i])(slotVals[si]);
        }
    }}

    return to_ruby_value(fn(args));
}

// ------------------------------------------------------------------
// Trampoline selection. Every def!'d function — fixed arity, defaults,
// or wrapper params — uses the uniform argc/argv trampoline, registered
// with arity -1. (The old per-arity extern(C) shims rudy_trampoline_0..
// _3 are gone: one code path, and blocks/rest/kwargs would not fit the
// fixed-arity ABI anyway.)
// ------------------------------------------------------------------

template rudy_trampoline(alias fn)
{
    alias rudy_trampoline = rudy_trampoline_var!(fn);
}

/// Registered arity for Ruby: always -1 (argc/argv style).
enum int rudy_arity(alias fn) = -1;

// ------------------------------------------------------------------
// def! — the public interface
// ------------------------------------------------------------------

public:

/// Define fn as a global function (on Object).
void def(alias fn, string name = __traits(identifier, fn))()
{
    // NB: alias template params must be forwarded in the bang-list;
    // def!"Object"(fn, name) misparses under GDC-14 as a runtime call.
    def!("Object", fn, name)();
}

/// Define fn in the scope of `modulename` (class -> method, module ->
/// module function, anything else -> global on Object).
void def(string modulename, alias fn, string name = __traits(identifier, fn))()
{
    VALUE parent = rb_const_get(rb_cObject, rb_intern(toStringz(modulename)));
    alias tramp = rudy_trampoline!(fn);

    // T_MODULE == 0x03 per value.d; rb_type is macro-only, classify
    // via is_a?(Module)
    VALUE[1] av = [rb_const_get(rb_cObject, rb_intern("Module"))];
    VALUE res = rb_funcallv_public(parent, rb_intern("is_a?"), 1, av.ptr);

    if (res == Qtrue_)
        rb_define_module_function(parent, toStringz(name),
                                  cast(AnyMethod) &tramp, rudy_arity!(fn));
    else
        rb_define_method(parent, toStringz(name),
                         cast(AnyMethod) &tramp, rudy_arity!(fn));
}

/// Define fn as a PRIVATE instance method (e.g. DSL-style callbacks).
void def_private(string modulename, alias fn,
                 string name = __traits(identifier, fn))()
{
    VALUE parent = rb_const_get(rb_cObject, rb_intern(toStringz(modulename)));
    alias tramp = rudy_trampoline!(fn);
    rb_define_private_method(parent, toStringz(name),
                             cast(AnyMethod) &tramp, rudy_arity!(fn));
}

/// Define fn as a PROTECTED instance method.
void def_protected(string modulename, alias fn,
                   string name = __traits(identifier, fn))()
{
    VALUE parent = rb_const_get(rb_cObject, rb_intern(toStringz(modulename)));
    alias tramp = rudy_trampoline!(fn);
    rb_define_protected_method(parent, toStringz(name),
                               cast(AnyMethod) &tramp, rudy_arity!(fn));
}

/// Define fn as a SINGLETON method of `modulename`'s class object
/// (i.e. a class-level method: MyClass.def!'d_thing).
void def_singleton(string modulename, alias fn,
                   string name = __traits(identifier, fn))()
{
    VALUE klass = rb_const_get(rb_cObject, rb_intern(toStringz(modulename)));
    alias tramp = rudy_trampoline!(fn);
    rb_define_singleton_method(klass, toStringz(name),
                               cast(AnyMethod) &tramp, rudy_arity!(fn));
}

/// Define fn as a singleton method of a specific OBJECT (per-object
/// method; the object must be reachable by name at def! time).
void def_singleton_on(string objectname, alias fn,
                      string name = __traits(identifier, fn))()
{
    // "A::B" paths walk the scope chain (rb_const_get resolves one
    // constant per call, not a path)
    VALUE obj = rb_cObject;
    foreach (part; objectname.splitter("::"))
        obj = rb_const_get(obj, rb_intern(toStringz(part)));
    alias tramp = rudy_trampoline!(fn);
    rb_define_singleton_method(obj, toStringz(name),
                               cast(AnyMethod) &tramp, rudy_arity!(fn));
}
