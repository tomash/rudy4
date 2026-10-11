/// EXPERIMENT 3 — Performance & GC torture.
///
/// Torture elements:
/// - tight loops crossing the boundary with def!-converted args
/// - Ruby-side GC running while D holds wrapped pointers
/// - fibonacci recursion through the boundary each level (worst case)
/// - big arrays/hashes converted wholesale

module exp_perf;

import rudy.bind.value;
import rudy.convert;
import rudy.defs;
import std.string : toStringz;

private:

// classic def! — NB: param must NOT be ulong: VALUE is aliased to ulong,
// so a ulong param hits the raw-passthrough branch in the trampoline
// and arrives TAGGED (n -> 2n+1). Use long so d_type decodes it.
ulong perf_fib(long n_)
{
    ulong n = cast(ulong) n_;
    ulong fib(ulong k) { return k < 2 ? k : fib(k - 1) + fib(k - 2); }
    // recursion stays in D — this measures D-side speed
    return fib(n);
}

// boundary-crossing fib: each level goes back out to Ruby and returns
extern (C) VALUE perf_fib_boundary(VALUE self, VALUE n)
{
    ulong k = d_type!ulong(n);
    if (k < 2) return to_ruby_value(k);
    VALUE[1] av1 = [to_ruby_value(k - 1)];
    VALUE[1] av2 = [to_ruby_value(k - 2)];
    VALUE mod = rb_const_get(rb_cObject, rb_intern("ExpPerf"));
    ulong a = d_type!ulong(rb_funcallv(mod, rb_intern("fib_boundary"), 1, av1.ptr));
    ulong b = d_type!ulong(rb_funcallv(mod, rb_intern("fib_boundary"), 1, av2.ptr));
    return to_ruby_value(a + b);
}

// build a 100k-element Array of Floats in D, sum in D
extern (C) VALUE perf_build(VALUE self, VALUE n)
{
    long len = d_type!long(n);
    VALUE ary = rb_ary_new_capa(len);
    double total = 0.0; // uninit double is NaN in D
    foreach (i; 0 .. len)
    {
        double v = i * 0.5;
        total += v;
        rb_ary_push(ary, to_ruby_value(v));
    }
    // return [array, sum]
    VALUE res = rb_ary_new_capa(2);
    rb_ary_push(res, ary);
    rb_ary_push(res, to_ruby_value(total));
    return res;
}

// stress to_ruby_value on AAs (Hash) — 10k keys
extern (C) VALUE perf_hash(VALUE self, VALUE n)
{
    long len = d_type!long(n);
    int[int] aa;
    foreach (int i; 0 .. cast(int) len)
        aa[i] = i * i;
    return to_ruby_value(aa);
}

public:

pragma(mangle, "Init_exp_perf")
extern (C) void Init_exp_perf()
{
    VALUE m = rb_define_module("ExpPerf");
    def!("ExpPerf", perf_fib, "fib");
    rb_define_module_function(m, "fib_boundary", cast(AnyMethod) &perf_fib_boundary, 1);
    rb_define_module_function(m, "build",        cast(AnyMethod) &perf_build, 1);
    rb_define_module_function(m, "hash",         cast(AnyMethod) &perf_hash, 1);
    rb_define_const(m, "PI", to_ruby_value(3.141592653589793));
    rb_define_const(m, "GREETING", to_ruby_value("hello from D"));
}