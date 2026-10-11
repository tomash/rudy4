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

module rudy.defs;

import rudy.bind.value;
import rudy.convert;
import std.traits;
import std.string : toStringz;
import std.array : join;
import std.conv : to;

private:

// ------------------------------------------------------------------
// Trampolines: fixed-arity extern(C) shims that Ruby can call.
// One is instantiated per (function, arity) pair at def!() time.
// ------------------------------------------------------------------

extern(C)
VALUE rudy_trampoline_0(alias fn)()
{
    return to_ruby_value(fn());
}

extern(C)
VALUE rudy_trampoline_1(alias fn)(VALUE self, VALUE a1)
{
    alias P = Parameters!(fn);
    static if (is(P[0] == VALUE))                 // raw VALUE passthrough
        return to_ruby_value(fn(a1));
    else
        return to_ruby_value(fn(d_type!(P[0])(a1)));
}

extern(C)
VALUE rudy_trampoline_2(alias fn)(VALUE self, VALUE a1, VALUE a2)
{
    alias P = Parameters!(fn);
    static if (is(P[0] == VALUE) && is(P[1] == VALUE))
        return to_ruby_value(fn(a1, a2));
    else
        return to_ruby_value(fn(d_type!(P[0])(a1), d_type!(P[1])(a2)));
}

extern(C)
VALUE rudy_trampoline_3(alias fn)(VALUE self, VALUE a1, VALUE a2, VALUE a3)
{
    alias P = Parameters!(fn);
    static if (is(P[0] == VALUE) && is(P[1] == VALUE) && is(P[2] == VALUE))
        return to_ruby_value(fn(a1, a2, a3));
    else
        return to_ruby_value(
            fn(d_type!(P[0])(a1), d_type!(P[1])(a2), d_type!(P[2])(a3)));
}

// ------------------------------------------------------------------
// Variadic trampoline: argc/argv style (registered with arity -1).
// Instantiated only when fn has D default arguments; each missing
// argument is substituted with its declared default value.
// ------------------------------------------------------------------

// Strip leading `void` entries (params without D defaults) off a
// ParameterDefaults tuple; the count of stripped voids = required
// arguments. Alias-slicing only — arithmetic recursion on an
// eponymous enum is a circular reference under GDC-14.
private template shrinkVoids(D...)
{
    static if (D.length > 0 && is(D[0] == void))
        alias shrinkVoids = shrinkVoids!(D[1 .. $]);
    else
        alias shrinkVoids = D;
}

extern(C)
VALUE rudy_trampoline_var(alias fn)(int argc, const(VALUE)* argv, VALUE self)
{
    alias P = Parameters!(typeof(&fn));
    enum total = P.length;
    alias DEFAULTS = ParameterDefaults!(fn);   // AliasSeq: void where none

    // how many params lack defaults (must all be supplied)
    enum required = total - shrinkVoids!DEFAULTS.length;

    if (argc < required || argc > total)
    {
        const(char)* expect = required == total ? toStringz("".dup)
                           : (required == 0 ? toStringz("0..") : toStringz(""));
        rb_raise(rb_eArgError, "wrong number of arguments (given %d, expected %s%d)",
                 argc, expect, total);
    }

    // Unwrap supplied args, then substitute declared defaults for the
    // rest — static foreach resolves each index at compile time
    // (GDC-14 rejects runtime-indexed static-if on tuples).
    P args;                                   // default-initialized
    static foreach (j; 0 .. total)
    {
        static if (is(DEFAULTS[j] == void))   // mandatory: always from argv
        {
            static if (is(P[j] == VALUE))
                args[j] = argv[j];
            else
                args[j] = d_type!(P[j])(argv[j]);
        }
        else                                   // optional: argv or default
        {
            if (argc > j)
            {
                static if (is(P[j] == VALUE))
                    args[j] = argv[j];
                else
                    args[j] = d_type!(P[j])(argv[j]);
            }
            else
            {
                static if (is(DEFAULTS[j] == VALUE))
                    args[j] = cast(VALUE) DEFAULTS[j];
                else
                    args[j] = DEFAULTS[j];
            }
        }
    }

    // call fn with all `total` args — the tuple expands into the call
    return to_ruby_value(fn(args));
}

/// Picks the right trampoline instantiation for fn's parameter count.
template rudy_trampoline(alias fn)
{
    alias P = Parameters!(typeof(&fn));
    enum hasDefaults = hasDefaultArgs!(fn);
    static if (hasDefaults)         alias rudy_trampoline = rudy_trampoline_var!(fn);
    else static if (P.length == 0)  alias rudy_trampoline = rudy_trampoline_0!(fn);
    else static if (P.length == 1) alias rudy_trampoline = rudy_trampoline_1!(fn);
    else static if (P.length == 2) alias rudy_trampoline = rudy_trampoline_2!(fn);
    else static if (P.length == 3) alias rudy_trampoline = rudy_trampoline_3!(fn);
    else static assert(0, "def!: only 0..3 arguments (or defaults) supported");
}

/// true if any parameter of fn has a D default value
template hasDefaultArgs(alias fn)
{
    alias D = ParameterDefaults!(fn);
    enum bool hasDefaultArgs = hasDefaultArgsImpl!D;
}

private template hasDefaultArgsImpl(D...)
{
    static if (D.length == 0)
        enum bool hasDefaultArgsImpl = false;
    else static if (!is(D[0] == void))
        enum bool hasDefaultArgsImpl = true;
    else
        enum bool hasDefaultArgsImpl = hasDefaultArgsImpl!(D[1 .. $]);
}

/// Registered arity for Ruby: fixed count for fixed-arity functions;
/// -1 (argc/argv style) when defaults are in play.
enum int rudy_arity(alias fn) = hasDefaultArgs!(fn)
    ? -1
    : cast(int) Parameters!(typeof(&fn)).length;

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
    pragma(msg, "rudy def!: " ~ name ~ " in " ~ modulename);

    VALUE parent = rb_cObject;
    if (modulename != "Object")
        parent = rb_const_get(rb_cObject, rb_intern(toStringz(modulename)));

    alias tramp = rudy_trampoline!(fn);

    // T_MODULE == 0x03 per value.d
    if (rb_type_guess(parent) == RUBY_T_MODULE)
        rb_define_module_function(parent, toStringz(name),
                                  cast(AnyMethod) &tramp, rudy_arity!(fn));
    else
        rb_define_method(parent, toStringz(name),
                         cast(AnyMethod) &tramp, rudy_arity!(fn));
}

/// rb_type is a macro in ruby.h; there is no exported rb_type function,
/// so classify via exported helpers. Class/Module both respond correctly:
private int rb_type_guess(VALUE v)
{
    // RUBY_T_MODULE == 0x03, RUBY_T_CLASS == 0x02, others
    // rb_obj_class won't tell us Module directly; use rb_check_funcall's
    // Qundef-free protocol instead: is_a?(Module)
    VALUE[1] av = [rb_const_get(rb_cObject, rb_intern("Module"))];
    VALUE res = rb_funcallv_public(v, rb_intern("is_a?"), 1, av.ptr);
    return res == Qtrue_ ? RUBY_T_MODULE : RUBY_T_CLASS;
}
