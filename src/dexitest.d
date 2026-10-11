/// dexitest — acceptance-test extension for the PR#4 missing-API bindings:
/// rb_yield/rb_yield_values2/rb_yield_splat, rb_block_call, rb_block_given_p,
/// rb_rescue, rb_ensure, rb_define_singleton_method, rb_scan_args,
/// rb_thread_call_without_gvl, and the variadic (argc/argv) def! trampoline
/// for D functions with default arguments.
///
/// Also exercises def_singleton! and friends added to rudy.defs.

module dexitest;

import rudy.bind.value;
import rudy.convert;
import rudy.defs;


private:

// ------------------------------------------------------------------
// 1. rb_yield — yield to the caller's block from a def!'d method
// ------------------------------------------------------------------

long sum_to(long n)
{
    long total = 0;
    foreach (i; 1 .. n + 1)
    {
        VALUE[1] av = [rb_ll2inum(i)];
        total += d_type!long(rb_yield(av[0]));   // yield i
    }
    return total;
}

// ------------------------------------------------------------------
// 2. rb_block_given_p + rb_yield_values2 (multiple yield args)
// ------------------------------------------------------------------

long pair_sums(long n)
{
    if (rb_block_given_p() == 0)
        return -1;                              // no block: -1
    long total = 0;
    foreach (i; 1 .. n + 1)
    {
        VALUE[2] av = [rb_ll2inum(i), rb_ll2inum(i * 10)];
        total += d_type!long(rb_yield_values2(2, av.ptr)); // |a, b| a + b
    }
    return total;
}

// ------------------------------------------------------------------
// 3. rb_block_call — call obj.each with a C-implemented block
//    (collects entries into a Ruby Array, D-side accumulation)
// ------------------------------------------------------------------

__gshared VALUE block_call_sink;                 // rooted Ruby Array

extern (C) VALUE collect_entry(VALUE yielded, VALUE cb, int argc,
                               const(VALUE)* argv, VALUE blockarg)
{
    rb_ary_push(block_call_sink, yielded);
    return yielded;
}

// returns Array of elements of the array argument, collected via each
private VALUE dexitest_block_collect(VALUE self, VALUE ary)
{
    block_call_sink = rb_ary_new();
    rb_block_call(ary, rb_intern("each"), 0, null, &collect_entry, Qnil_);
    return block_call_sink;
}

// ------------------------------------------------------------------
// 4. rb_rescue — structured exception handling across the boundary
// ------------------------------------------------------------------

extern (C) VALUE risky_body(VALUE data)          // raises ZeroDivisionError
{
    VALUE[0] av;
    return rb_funcallv(rb_int2inum(1), rb_intern("/"), 1,
                       [rb_int2inum(0)].ptr);
}

extern (C) VALUE rescue_handler(VALUE data2, VALUE exc)
{
    return rb_str_new_cstr("rescued");
}

private VALUE dexitest_div_rescue(VALUE self, VALUE a, VALUE b)
{
    // single-class rescue via rb_rescue (StandardError family)
    return rb_rescue(&risky_body, Qnil_, &rescue_handler, Qnil_);
}

// body that succeeds — rb_rescue returns b_proc's value untouched
extern (C) VALUE safe_body(VALUE data) { return rb_int2inum(42); }

private VALUE dexitest_safe_rescue(VALUE self)
{
    return rb_rescue(&safe_body, Qnil_, &rescue_handler, Qnil_);
}

// ------------------------------------------------------------------
// 5. rb_ensure — ensure runs after both success and raise paths
// ------------------------------------------------------------------

__gshared int ensure_ran = 0;

extern (C) VALUE ensure_proc(VALUE data)
{
    ensure_ran = 1;
    return Qnil_;
}

extern (C) VALUE raising_body(VALUE data)
{
    rb_raise(rb_eRuntimeError, "boom");
    return Qnil_;                                // unreachable
}

private VALUE dexitest_ensure_success(VALUE self)
{
    ensure_ran = 0;
    VALUE r = rb_ensure(&safe_body, Qnil_, &ensure_proc, Qnil_);
    return to_ruby_value(r == rb_int2inum(42) && ensure_ran == 1);
}

private VALUE dexitest_ensure_raise(VALUE self)
{
    ensure_ran = 0;
    VALUE r = rb_ensure(&raising_body, Qnil_, &ensure_proc, Qnil_);
    return to_ruby_value(false);                 // never reached
}

// does the ensure run even when the body raises? (call from Ruby rescue)
private VALUE dexitest_ensure_raised_flag(VALUE self)
{
    return to_ruby_value(ensure_ran);
}

// ------------------------------------------------------------------
// 6. rb_define_singleton_method — per-object method
// ------------------------------------------------------------------

private VALUE singleton_hi(VALUE self)
{
    return rb_str_new_cstr("hi from singleton");
}

private VALUE dexitest_make_singleton(VALUE self, VALUE obj)
{
    rb_define_singleton_method(obj, "dexitest_greet",
                                cast(AnyMethod) &singleton_hi, 0);
    return obj;
}

// ------------------------------------------------------------------
// 7. rb_scan_args — the C-style argument scanner, argc/argv style
// ------------------------------------------------------------------

private VALUE dexitest_scan(int argc, const(VALUE)* argv, VALUE self)
{
    VALUE a = Qnil_, b = Qnil_, rest = Qnil_;
    // "11*": one mandatory, one optional, splat the rest
    int n = rb_scan_args(argc, argv, "11*", &a, &b, &rest);
    VALUE res = rb_ary_new_capa(4);
    rb_ary_push(res, rb_ll2inum(n));
    rb_ary_push(res, a);
    rb_ary_push(res, b);
    rb_ary_push(res, rest);
    return res;
}

// ------------------------------------------------------------------
// 8. rb_thread_call_without_gvl — release the GVL for a pure-D nap
//    (other Ruby threads keep running; result comes back through)
// ------------------------------------------------------------------

extern (C) void* nap(void* data)
{
    // busy-wait ~30ms without touching Ruby APIs
    long spins = 30_000_000;
    long acc = 0;
    foreach (i; 0 .. spins)
        acc += i % 7;
    return cast(void*) acc;
}

extern (C) void ubf_abort(void* data) {}         // no cancellation support

private VALUE dexitest_nogvl(VALUE self)
{
    void* r = rb_thread_call_without_gvl(&nap, null, &ubf_abort, null);
    return rb_ll2inum(cast(long) r);
}

// same, but prove another Ruby thread ran *while* the GVL was released
__gshared int tick_ran = 0;

private VALUE dexitest_tick(VALUE self) { tick_ran = 1; return Qnil_; }

private VALUE dexitest_nogvl_parallel(VALUE self)
{
    tick_ran = 0;
    // Ruby-side caller spawns a thread that calls dexitest_tick; D naps
    // without the GVL; then we check the flag. See test/exitest.rb.
    void* r = rb_thread_call_without_gvl(&nap, null, &ubf_abort, null);
    return to_ruby_value(tick_ran);
}

// ------------------------------------------------------------------
// 9. variadic def! — D default arguments become Ruby optional args
// ------------------------------------------------------------------

long var_sum(long a, long b = 2, long c = 30)
{
    return a + b + c;
}

string var_greet(string name, string greeting = "hello", string punct = "!")
{
    return greeting ~ ", " ~ name ~ punct;
}

// mixed required/optional with raw VALUE passthrough (identity on the
// VALUE, plus an optional second argument that defaults to 5)
private VALUE var_raw(VALUE v, long n = 5)
{
    if (n == 5)
        return v;                                // default path: identity
    VALUE[1] av = [rb_ll2inum(n)];
    return rb_funcallv(v, rb_intern("*"), 1, av.ptr);
}

public:

pragma(mangle, "Init_dexitest")
extern (C) void Init_dexitest()
{
    VALUE mDExitTest = rb_define_module("DExitTest");

    // def!'d, conversion-handled
    def!("DExitTest", sum_to);
    def!("DExitTest", pair_sums);

    // raw extern(C) bodies registered directly (argc/argv or VALUE style)
    rb_define_module_function(mDExitTest, "block_collect",
                              cast(AnyMethod) &dexitest_block_collect, 1);
    rb_define_module_function(mDExitTest, "div_rescue",
                              cast(AnyMethod) &dexitest_div_rescue, 2);
    rb_define_module_function(mDExitTest, "safe_rescue",
                              cast(AnyMethod) &dexitest_safe_rescue, 0);
    rb_define_module_function(mDExitTest, "ensure_success",
                              cast(AnyMethod) &dexitest_ensure_success, 0);
    rb_define_module_function(mDExitTest, "ensure_raises",
                              cast(AnyMethod) &dexitest_ensure_raise, 0);
    rb_define_module_function(mDExitTest, "ensure_raised_flag",
                              cast(AnyMethod) &dexitest_ensure_raised_flag, 0);
    rb_define_module_function(mDExitTest, "make_singleton",
                              cast(AnyMethod) &dexitest_make_singleton, 1);
    rb_define_module_function(mDExitTest, "scan",
                              cast(AnyMethod) &dexitest_scan, -1);
    rb_define_module_function(mDExitTest, "nogvl",
                              cast(AnyMethod) &dexitest_nogvl, 0);
    rb_define_module_function(mDExitTest, "nogvl_parallel",
                              cast(AnyMethod) &dexitest_nogvl_parallel, 0);
    rb_define_module_function(mDExitTest, "tick",
                              cast(AnyMethod) &dexitest_tick, 0);

    // variadic def! — optional args via D default values
    def!("DExitTest", var_sum);
    def!("DExitTest", var_greet);
    def!("DExitTest", var_raw);

    // root the block_call sink
    block_call_sink = rb_ary_new();
    rb_gc_register_address(&block_call_sink);
}
