/// exp_defargs — torture the def! argument-passing extensions (backlog
/// item 5): block parameters, *rest, **kwargs, receiver Self, visibility
/// variants (private/protected), and singleton methods.
///
/// Every function here is registered by Init_exp_defargs via the
/// def!/def_private/def_protected/def_singleton interface itself — the
/// point is to exercise the generated trampolines, not hand-written
/// extern(C) shims.
///
/// Torture elements:
/// - RubyBlock: call with 0..3 args, given/!given, arity, LocalJumpError
///   on block-less call, block raising through the D frame, blocks
///   calling BACK into other def!'d D methods (reentrancy).
/// - Rest: empty rest, mixed required+rest, hostile values (bignums,
///   frozen strings), to!T conversion, foreach via opApply, opIndex.
/// - KwArgs: given/!given, get!T with D defaults, symbol+string key
///   probing, to!(V,K) walk (symbol keys normalized via to_s),
///   unknown keys ignored.
/// - Self: receiver class/identity — module_function self == module,
///   singleton self == the class object / the named constant.
/// - Visibility: def_private callable via send() but not directly;
///   def_protected callable only from inside the class hierarchy.
/// - Combined layouts: optional+block, rest+block, Raw positional+block.
///
/// Layout:
///   DDefArgs.each_twice(n)         -> yields i*2 for i in 0...n
///   DDefArgs.map_twice(n)          -> block-mapped array
///   DDefArgs.block_optional(a, b)  -> block only when given
///   DDefArgs.raise_walk(n)         -> block raises mid-walk; scope(exit)
///   DDefArgs.raise_walk_last       -> scope(exit) ran?
///   DDefArgs.block_arity(blk)      -> Proc#arity passthrough
///   DDefArgs.rest_sum(first, ...)  -> required + *rest
///   DDefArgs.rest_join(first, ...) -> rest to!string[] join
///   DDefArgs.rest_first(...)      -> opIndex into hostile values
///   DDefArgs.rest_count(...)       -> rest.length
///   DDefArgs.kw_pick(**kw)         -> get!T with defaults
///   DDefArgs.kw_all(**kw)          -> to!(V,K) walk (Raw!VALUE out)
///   DDefArgs.self_class            -> receiver's class name
///   DDefArgs::TARGET.self_is_const -> singleton_on receiver identity
///   DDefArgs.hidden_times_two      -> def_private
///   DDefArgs.shielded_times_three  -> def_protected
///   DDefArgs.opt_block(a, b=10, blk)     -> optional + block
///   DDefArgs.rest_block(first, rest, blk)-> rest + block
///   DDefArgs.raw_block(v, n, blk)        -> Raw + block
///   DDefArgs.klass_factory(x)      -> def_singleton (class-level)
///   DDefArgs::COUNTER.bump(by)     -> def_singleton_on (per-object)

module exp_defargs;

import rudy.bind.value;
import rudy.convert;
import rudy.args;
import rudy.defs;

private:

// lazily-interned to_s (args.d's copy is private to that module)
private __gshared ID exp_id_to_s;
private ID id_to_s() { if (!exp_id_to_s) exp_id_to_s = rb_intern("to_s"); return exp_id_to_s; }

// ------------------------------------------------------------------ blocks

// yield i*2 for i in 0...n; returns the block's last value (like times)
long each_twice(long n, RubyBlock blk)
{
    if (!blk.given)
        rb_raise(rb_eArgError, "block required");
    VALUE last = Qnil_;
    foreach (i; 0 .. n)
    {
        VALUE[1] av = [rb_ll2inum(i * 2)];
        last = blk.call(av[0]);
    }
    return d_type!long(last);
}

// map: collect block results into a Ruby array. NB: returns Raw!VALUE —
// a plain VALUE return value goes through to_ruby_value, which converts
// it as a machine word (finding #17), not as the object.
Raw!VALUE map_twice(long n, RubyBlock blk)
{
    if (!blk.given)
        rb_raise(rb_eArgError, "block required");
    VALUE outv = rb_ary_new();
    foreach (i; 0 .. n)
    {
        VALUE[1] av = [rb_ll2inum(i)];
        rb_ary_push(outv, blk.call(av[0]));
    }
    return Raw!VALUE(outv);
}

// block optional: different result with and without a block
string block_optional(long a, long b)
{
    import std.conv : to;
    if (b == 10)
        return "b-was-default";
    return "b=" ~ to!string(b);
}

// block raising through the D frame: the block raises, the longjmp
// unwinds the D frames; raise_walk_last must show the scope(exit)
// counter incremented (D cleanup ran despite the Ruby-side raise)
__gshared long raise_walk_count = 0;

long raise_walk(long n, RubyBlock blk)
{
    scope (exit) raise_walk_count++;
    foreach (i; 0 .. n)
    {
        VALUE[1] av = [rb_ll2inum(i)];
        blk.call(av[0]);                       // raises when i == 2
    }
    return n;
}

long raise_walk_last() { return raise_walk_count; }

// block arity passthrough (Proc#arity of the caller's block)
long block_arity(RubyBlock blk)
{
    return blk.arity;
}

// ------------------------------------------------------------------ rest

long rest_sum(long first, Rest rest)
{
    long total = first;
    foreach (v; rest)                          // opApply
        total += d_type!long(v);
    return total;
}

string rest_join(string first, Rest rest)
{
    string s = first;
    foreach (v; rest)
        s ~= "," ~ d_type!string(v);
    return s;
}

// first rest value decoded via opIndex (hostile values: near-long-max
// fixnums; real bignums raise RangeError — see test)
long rest_first(Rest rest)
{
    if (rest.empty)
        return -1;
    return d_type!long(rest[0]);               // opIndex
}

long rest_count(Rest rest)
{
    return cast(long) rest.length;
}

// ------------------------------------------------------------------ kwargs

// kw.get!T with D defaults; compact fingerprint of what was seen
string kw_pick(KwArgs kw)
{
    import std.conv : to;
    long n = kw.get!long("n", 0);
    string sep = kw.get!string("sep", "-");
    bool flag = kw.get!bool("flag", false);
    return "n=" ~ to!string(n) ~ " sep=" ~ sep ~ " flag=" ~ (flag ? "y" : "n");
}

// every key => value as flat "key=value" array (symbol AND string keys
// both surface; symbol keys are normalized via to_s inside KwArgs.to!).
// Values go through Ruby to_s (Object#to_s fallback) so any value type
// fingerprints — the D-side AA is V=string, and d_type!string of a
// non-String VALUE would raise.
Raw!VALUE kw_all(KwArgs kw)
{
    import std.conv : to;
    VALUE outv = rb_ary_new();
    // to!(Raw!VALUE, string): keys normalized to D strings (symbol->to_s
    // inside KwArgs.to!), values stay raw VALUEs. NB: plain VALUE as V
    // would route values through d_type!ulong — rudy_check_unsigned
    // probes via rb_num2dbl and a String value dies with "no implicit
    // conversion to float from string". Raw!VALUE is the raw escape.
    foreach (key, val; kw.to!(Raw!VALUE, string))
    {
        VALUE vs = rb_funcallv(val.value, id_to_s(), 0, null);
        rb_ary_push(outv, to_ruby_value(key ~ "=" ~ d_type!string(vs)));
    }
    return Raw!VALUE(outv);
}

// kwargs given vs not: block-less style contract
string kw_given_p(KwArgs kw)
{
    return kw.given ? "given" : "none";
}

// ------------------------------------------------------------------ self

// class name of the receiver — module_function self is the module itself
string self_class(Self self)
{
    return d_type!string(rb_funcallv(
        rb_funcallv(self.value, rb_intern("class"), 0, null),
        rb_intern("to_s"), 0, null));
}

// identity: receiver == the TARGET constant object? (def_singleton_on)
bool self_is_const(Self self, Raw!VALUE c)
{
    return self.value == c.value;
}

// ------------------------------------------------------------------ visibility

private long hidden_times_two(long n) { return n * 2; }
private long shielded_times_three(long n) { return n * 3; }

// ------------------------------------------------------------------ combined layouts

// optional args + block: block only when given
string opt_block(long a, long b = 10, RubyBlock blk)
{
    import std.conv : to;
    if (!blk.given)
        return "plain:" ~ to!string(a + b);
    VALUE[1] av = [rb_ll2inum(a + b)];
    return d_type!string(blk.call(av[0]));
}

// rest + block: block adds a bonus to the rest total
long rest_block(long first, Rest rest, RubyBlock blk)
{
    long total = first;
    foreach (v; rest)
        total += d_type!long(v);
    if (blk.given)
    {
        VALUE[1] av = [rb_ll2inum(total)];
        total += d_type!long(blk.call(av[0]));
    }
    return total;
}

// raw positional + block
Raw!VALUE raw_block(Raw!VALUE v, long n, RubyBlock blk)
{
    if (!blk.given)
        return v;
    VALUE[1] av = [rb_ll2inum(n)];
    return Raw!VALUE(blk.callv(1, av.ptr));    // block transforms the value
}

// ------------------------------------------------------------------ singletons

long klass_factory(long x) { return x * 7; }

__gshared long counter_state = 0;
long counter_bump(long by) { counter_state += by; return counter_state; }

// ------------------------------------------------------------------ registration

pragma(mangle, "Init_exp_defargs")
extern (C) void Init_exp_defargs()
{
    VALUE m = rb_define_module("DDefArgs");

    // constants BEFORE the singleton_on registrations: rb_const_get at
    // def! time needs the target objects to exist already
    rb_define_const(m, "TARGET", rb_str_new("target-obj", 10));
    rb_define_const(m, "COUNTER", rb_str_new("counter-obj", 11));

    def!("DDefArgs", each_twice);
    def!("DDefArgs", map_twice);
    def!("DDefArgs", block_optional);
    def!("DDefArgs", raise_walk);
    def!("DDefArgs", raise_walk_last);
    def!("DDefArgs", block_arity);

    def!("DDefArgs", rest_sum);
    def!("DDefArgs", rest_join);
    def!("DDefArgs", rest_first);
    def!("DDefArgs", rest_count);

    def!("DDefArgs", kw_pick);
    def!("DDefArgs", kw_all);
    def!("DDefArgs", kw_given_p);

    def!("DDefArgs", self_class);              // module_function: self == module
    def_singleton_on!("DDefArgs::TARGET", self_is_const);

    def_private!("DDefArgs", hidden_times_two);
    def_protected!("DDefArgs", shielded_times_three);

    def!("DDefArgs", opt_block);
    def!("DDefArgs", rest_block);
    def!("DDefArgs", raw_block);

    def_singleton!("DDefArgs", klass_factory); // class-level on the module object
    def_singleton_on!("DDefArgs::COUNTER", counter_bump, "bump");
}
