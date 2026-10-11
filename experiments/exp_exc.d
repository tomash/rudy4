/// EXPERIMENT 6 — D <-> Ruby exception ping-pong torture.
///
/// Torture elements:
/// - rb_rescue / rb_ensure / rb_protect nested inside each other, with
///   bodies that call BACK into Ruby (rb_funcall) and raise from both sides
///   of the boundary in every combination.
/// - Mutual recursion Ruby -> D -> Ruby -> D ... 50 levels deep, unwinding
///   through raises at the deepest level: longjmp must cleanly skip D
///   frames without corrupting D state.
/// - State checks after each unwind: module vars survive, D-GC memory
///   allocated before the raise is still reachable (no collection of live
///   objects due to the longjmp), and the Ruby exception object surfacing
///   in Ruby is the SAME object raised inside the D call (identity check).
/// - rb_protect with nested rb_protect: inner raise caught by inner
///   protect, outer protect sees state == 0.
/// - rb_ensure: the ensure callback runs even when the body raises through
///   two nested rescues.
///
/// Layout:
///   DExc.echo_or_raise(n)   -> calls Ruby method (n times recursively via
///                              Ruby-level recursion into this function)
///   DExc.rescue_case        -> rb_rescue around a raising body
///   DExc.ensure_case        -> rb_ensure: body raises, ensure counts
///   DExc.protect_case       -> rb_protect with nested protect inside
///   DExc.deep_ping_pong     -> the recursion torture (see test)
///   DExc.state              -> survival checks after unwinds
///   DExc.identical_exc      -> raise inside rb_protect, re-raise SAME VALUE

module exp_exc;

import rudy.bind.value;
import rudy.convert;

import core.stdc.stdlib : malloc, free;

private:

// All module state __gshared: D module vars are thread-local by default
// (torture finding #1) — Ruby threads are OS pthreads.
__gshared:
long calls_made;         // every entry into a D function
long ensures_run;        // every rb_ensure ensure callback
long rescues_run;        // every rb_rescue rescue callback
long protects_caught;    // every rb_protect that observed state != 0
long max_depth_seen;     // deepest recursion observed (mutual D<->Ruby)
VALUE exc_kept;          // exception VALUE held across a longjmp
VALUE exc_reseen;        // exception VALUE re-observed after re-raise
int  ping_pong_failed;   // set when deep recursion returns wrong value

// ---------------------------------------------------------- helpers

extern (C) VALUE keep_exc(VALUE exc)
{
    // Store the pending VALUE (from rb_errinfo after a protect catch).
    exc_kept = exc;
    return Qnil_;
}

extern (C) void note_exception(VALUE exc) { exc_kept = exc; }

// ---------------------------------------------------------- echo_or_raise
// Ruby test calls: DExc.echo_or_raise(depth)
//   - if depth > 0: call Ruby-side DExc.ping_pong(depth - 1) — Ruby method
//     defined in the test file calls DExc.echo_or_raise back. Mutual
//     recursion through the boundary.
//   - if depth == 0: raise Ruby RuntimeError (longjmp from D code).
//   - if depth < 0: return a string; no raise (clean path).

extern (C) VALUE echo_or_raise(VALUE self, VALUE depth)
{
    calls_made += 1;
    long d = d_type!long(depth);
    if (d > 0)
    {
        // record depth for the max-depth assertion
        if (d > max_depth_seen) max_depth_seen = d;
        // Mutual recursion: D -> Ruby method -> D again.
        return rb_funcall(rb_mKernel, rb_intern("DExc_ping_pong"), 1, rb_int2inum(d - 1));
    }
    else if (d == 0)
    {
        // raise from D: longjmp straight out of this D frame (never returns)
        rb_raise(rb_eRuntimeError, "bottom of recursion");
        assert(0);
    }
    else
    {
        return rb_str_new_cstr("clean");
    }
    assert(0);   // rb_raise is noreturn; silence D's no-return analysis
}

// ---------------------------------------------------------- rescue_case
// rb_rescue around a Ruby-method body that raises. The rescue callback
// runs with the exception VALUE in hand — we store it and return a marker.

extern (C) VALUE raising_body(VALUE data) { return rb_funcall(rb_mKernel, rb_intern("DExc_raise"), 0); }
extern (C) VALUE rescue_body(VALUE data, VALUE exc)
{
    rescues_run += 1;
    note_exception(exc);
    return rb_str_new_cstr("rescued");
}

extern (C) VALUE rescue_case(VALUE self)
{
    calls_made += 1;
    return rb_rescue(&raising_body, Qnil_, &rescue_body, Qnil_);
}

// ---------------------------------------------------------- ensure_case
// rb_ensure: body raises; the ensure callback must still run (its counter
// is the assertion) and the exception must propagate to the Ruby caller.

extern (C) VALUE ensure_ensure(VALUE data)
{
    ensures_run += 1;
    return Qnil_;
}

extern (C) VALUE ensure_case(VALUE self)
{
    calls_made += 1;
    return rb_ensure(&raising_body, Qnil_, &ensure_ensure, Qnil_);
}

// ---------------------------------------------------------- protect_case
// Nested rb_protect: the inner protect catches an inner raise; the outer
// protect runs a clean body and must see state == 0. If the inner raise
// leaked outward, the whole VM would die (this actually happened with
// early def! trampolines — chunk-1 finding).

extern (C) VALUE inner_protect_body(VALUE data) { return rb_funcall(rb_mKernel, rb_intern("DExc_raise"), 0); }

extern (C) VALUE inner_protect(VALUE data)
{
    int state = 0;
    VALUE v = rb_protect(&inner_protect_body, Qnil_, &state);
    if (state != 0)
    {
        protects_caught += 1;
        // clear the pending exception: we HANDLED it (else the next Ruby
        // API call spuriously raises at an arbitrary point)
        rb_set_errinfo(Qnil_);
        return rb_str_new_cstr("inner caught");
    }
    return v;
}

extern (C) VALUE protect_body(VALUE data) { return rb_funcall(rb_mKernel, rb_intern("DExc_inner"), 0); }

// The Ruby-side stepper for the outer protect body calls THIS (registered
// as DExc.protect_inner): nested protect, raise contained at the inner.
extern (C) VALUE protect_inner(VALUE self)
{
    return inner_protect(Qnil_);
}

extern (C) VALUE protect_case(VALUE self)
{
    calls_made += 1;
    int state = 0;
    VALUE v = rb_protect(&protect_body, Qnil_, &state);
    if (state != 0)
    {
        protects_caught += 1;
        rb_set_errinfo(Qnil_);
        return rb_str_new_cstr("outer caught unexpectedly");
    }
    return v;
}

// ---------------------------------------------------------- deep ping-pong
// Called from Ruby with a big depth and a block: recurses D -> Ruby -> D
// with the block called at every level, then raises at the bottom. The
// Ruby rescue wraps the whole thing; we assert the unwind depth bookkeeping.

extern (C) VALUE deep_ping_pong(VALUE self, VALUE depth)
{
    calls_made += 1;
    long d = d_type!long(depth);
    if (d > max_depth_seen) max_depth_seen = d;
    if (d == 0)
    {
        rb_raise(rb_eRuntimeError, "deep bottom");
        assert(0);
    }
    // call the Ruby-side stepper (defined in the test file); a dedicated
    // name so the deep test does not route through echo_or_raise's stepper
    return rb_funcall(rb_mKernel, rb_intern("DExc_deep_ping_pong"), 1, rb_int2inum(d - 1));
}

// ---------------------------------------------------------- identical_exc
// Prove that the exception object raised inside a protected body is the
// SAME object that later appears in Ruby's rescue: identity via rb_obj_id.
// (also exercises rb_exc_raise: D re-raises the SAME exception VALUE after
// the protect catch — re-raising with rb_raise would build a new exc.)

extern (C) VALUE bomb_body(VALUE data) { return rb_funcall(rb_mKernel, rb_intern("DExc_raise"), 0); }

extern (C) VALUE identical_exc(VALUE self)
{
    calls_made += 1;
    int state = 0;
    VALUE v = rb_protect(&bomb_body, Qnil_, &state);
    if (state != 0)
    {
        protects_caught += 1;
        exc_reseen = rb_errinfo();
        rb_set_errinfo(Qnil_);
        // return the exception itself; the Ruby test compares object ids
        // after catching a re-raise of this same VALUE via rb_exc_raise
        return exc_reseen;
    }
    return v;
}

extern (C) VALUE reraise(VALUE self, VALUE exc)
{
    calls_made += 1;
    exc_reseen = exc;
    rb_exc_raise(exc);   // never returns
    assert(0);
}

// ---------------------------------------------------------- state

extern (C) VALUE get_calls(VALUE self)      { return rb_int2inum(calls_made); }
extern (C) VALUE get_ensures(VALUE self)    { return rb_int2inum(ensures_run); }
extern (C) VALUE get_rescues(VALUE self)    { return rb_int2inum(rescues_run); }
extern (C) VALUE get_protects(VALUE self)   { return rb_int2inum(protects_caught); }
extern (C) VALUE get_max_depth(VALUE self)  { return rb_int2inum(max_depth_seen); }
extern (C) VALUE get_ping_fail(VALUE self)   { return ping_pong_failed ? Qtrue_ : Qfalse_; }
extern (C) VALUE get_exc_kept(VALUE self)    { return exc_kept; }
extern (C) VALUE get_exc_reseen(VALUE self)  { return exc_reseen; }

// ---------------------------------------------------------- init

pragma(mangle, "Init_exp_exc")
extern (C) void Init_exp_exc()
{
    // The two __gshared VALUE slots hold exceptions across D calls; Ruby's
    // GC would otherwise be free to collect them mid-experiment (a VALUE
    // stored only in a D global is invisible to the collector).
    rb_gc_register_address(&exc_kept);
    rb_gc_register_address(&exc_reseen);

    VALUE m = rb_define_module("DExc");
    rb_define_module_function(m, "echo_or_raise", cast(AnyMethod) &echo_or_raise, 1);
    rb_define_module_function(m, "rescue_case", cast(AnyMethod) &rescue_case, 0);
    rb_define_module_function(m, "ensure_case", cast(AnyMethod) &ensure_case, 0);
    rb_define_module_function(m, "protect_case", cast(AnyMethod) &protect_case, 0);
    rb_define_module_function(m, "protect_inner", cast(AnyMethod) &protect_inner, 0);
    rb_define_module_function(m, "deep_ping_pong", cast(AnyMethod) &deep_ping_pong, 1);
    rb_define_module_function(m, "identical_exc", cast(AnyMethod) &identical_exc, 0);
    rb_define_module_function(m, "reraise", cast(AnyMethod) &reraise, 1);
    rb_define_module_function(m, "calls", cast(AnyMethod) &get_calls, 0);
    rb_define_module_function(m, "ensures", cast(AnyMethod) &get_ensures, 0);
    rb_define_module_function(m, "rescues", cast(AnyMethod) &get_rescues, 0);
    rb_define_module_function(m, "protects", cast(AnyMethod) &get_protects, 0);
    rb_define_module_function(m, "max_depth", cast(AnyMethod) &get_max_depth, 0);
    rb_define_module_function(m, "ping_pong_failed", cast(AnyMethod) &get_ping_fail, 0);
    rb_define_module_function(m, "exc_kept", cast(AnyMethod) &get_exc_kept, 0);
    rb_define_module_function(m, "exc_reseen", cast(AnyMethod) &get_exc_reseen, 0);
}
