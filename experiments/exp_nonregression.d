/// EXPERIMENT 11 — Documented non-goals (backlog item 9).
///
/// This experiment exists to put *evidence* behind the three documented
/// non-goals rather than silence:
///
///   1. Fiber switching across D frames — a Ruby Fiber may switch stacks
///      while D frames sit below on the fiber's stack. Simple value
///      round-trips work (D frames are plain C frames and survive the
///      switch), but D's GC registers the *thread* stack, not Ruby's
///      separate fiber stacks — so a D heap object reachable only from a
///      fiber-stack local has no root. NOT SUPPORTED as a guarantee; the
///      probes below show what does work and mark what is not.
///   2. Ractor-shareability — a D-wrapped object is an opaque non-Ruby
///      object with a D-runtime-owned payload; it is not shareable and
///      cannot be moved to another Ractor safely. D runtime TLS also has
///      to initialise on the Ractor's foreign thread. NOT SUPPORTED.
///   3. Interruptibility of a long GVL-held D call — while D holds the
///      GVL, Ruby cannot run its signal/interrupt checks, so Ctrl-C
///      during `fib(40)` is delivered only after the D call returns.
///      Inherent to holding the GVL, not a rudy bug (the GVL-released
///      variant IS interruptible — that is the whole point of
///      `rb_thread_call_without_gvl`).
///
/// Probe surface (module `DNonReg`):
///   DNonReg.fib(n)            — pure-D tree recursion (the "fib(40)" case)
///   DNonReg.sleep_gvl(ms)     — busy-wait holding the GVL (uninterruptible)
///   DNonReg.nap_nogvl(ms)     — busy-wait with the GVL released (interruptible)
///   DNonReg.helper_check()    — new/delete a D object whose ctor takes a
///                               live Ruby VALUE (per-thread D runtime probe)
///   DNonRegBox.new(x, y)      — a D-wrapped (protocol'd) object to ferry
///   DNonRegBox#[] / #[]=      — read / frozen-guarded write
///   DNonRegBox#roundtrip { }  — read, Ruby-yield, read again (Fiber probe)
///
/// The interruptibility probe lives in the Ruby suite (it forks a
/// subprocess and signals it); everything else is in-process.

module exp_nonregression;

import rudy.bind.value;
import rudy.convert;
import rudy.typeddata;
import rudy.objproto;
import rudy.defs;

import core.runtime : rt_init;
import core.time : MonoTime, msecs;
import std.string : format;

private:

// ------------------------------------------------------------------ fib
// The fresh-stack case from the backlog: a long, pure-D, GVL-held call.
long nr_fib(long n)
{
    return n < 2 ? n : nr_fib(n - 1) + nr_fib(n - 2);
}

// ---------------------------------------------------- GVL / no-GVL waits
// Busy-wait holding the GVL: Ruby's signal checks cannot run until we
// return. This is the "Ctrl-C during fib(40) is late" case, made
// deterministic with a wall-clock bound instead of a CPU-bound fib.
long nr_sleep_gvl(long ms)
{
    auto t0 = MonoTime.currTime;
    while ((MonoTime.currTime - t0) < msecs(ms))
    { /* spin with the GVL held */ }
    return ms;
}

private __gshared long g_nogvl_ms = 0;
// Set by the unblock function when Ruby asks the blocking region to stop
// (e.g. SIGINT while the GVL is released). A COOPERATING body checks it;
// with a no-op ubf the wait would still run to completion.
private __gshared bool g_nogvl_abort = false;

extern (C) void* nr_nap_body(void* data)
{
    auto t0 = MonoTime.currTime;
    while (!g_nogvl_abort && (MonoTime.currTime - t0) < msecs(g_nogvl_ms))
    { /* spin with the GVL released — no Ruby API touched */ }
    return null;
}

extern (C) void nr_nap_ubf(void* data)
{
    g_nogvl_abort = true;   // the cancellation hook
}

// Same wait, but with the GVL released via rb_thread_call_without_gvl:
// Ruby keeps running on other threads and CAN deliver an interrupt — the
// ubf flips g_nogvl_abort and the body bails out early.
long nr_nap_nogvl(long ms)
{
    g_nogvl_ms = ms;
    g_nogvl_abort = false;
    rb_thread_call_without_gvl(&nr_nap_body, null, &nr_nap_ubf, null);
    return ms;
}

// ---------------------------------------------------- D runtime probe
// A D object whose constructor takes a live Ruby VALUE (so the
// constructor touches the D GC/runtime, not just the stack). Created and
// deleted entirely inside the call: from a Ractor this exercises
// druntime initialisation on a foreign thread.
class DHelper
{
    VALUE tag_ = Qnil_;
    long n_ = 0;

    this(VALUE tag, long n)
    {
        tag_ = tag;
        n_ = n;
    }

    long compute() const
    {
        return n_ * 2;
    }

    ~this() {}
}

long nr_helper_check()
{
    auto h = new DHelper(rb_str_new("probe", 5), 21);
    scope (exit) destroy(h);
    return h.compute();
}

// ---------------------------------------------------- wrapped box
struct Box
{
    double x, y;
}

mixin RudyTypedData!(Box, "box");

private string box_inspect(ref const Box p)
{
    return format("x=%g y=%g", p.x, p.y);
}

mixin RudyObjectProtocol!(Box, "box", null, null, null, box_inspect);

// `box_proto_install` (generated) installs the allocator + initialize_copy
// + ==/eql?/hash/inspect. `box_get` (generated by RudyTypedData) reads the
// wrapped struct back out.

extern (C) VALUE box_init(VALUE self, VALUE x, VALUE y)
{
    Box* p = box_get(self);
    p.x = d_type!double(x);
    p.y = d_type!double(y);
    return self;
}

extern (C) VALUE box_nth(VALUE self, VALUE k)
{
    Box* p = box_get(self);
    return d_type!long(k) == 0 ? to_ruby_value(p.x) : to_ruby_value(p.y);
}

extern (C) VALUE box_set(VALUE self, VALUE k, VALUE v)
{
    rb_check_frozen(self);
    Box* p = box_get(self);
    if (d_type!long(k) == 0) p.x = d_type!double(v);
    else p.y = d_type!double(v);
    return v;
}

// read -> yield to Ruby -> read again: the D frame and the wrapped struct
// must both survive a Fiber switch performed inside the block. The block
// is captured via the C API (rb_block_given_p + rb_block_proc) because
// this is a hand-written method; a def!'d function would take RubyBlock.
extern (C) VALUE box_roundtrip(VALUE self, VALUE)
{
    Box* p = box_get(self);
    double before = p.x;
    if (rb_block_given_p() != 0)
    {
        VALUE proc = rb_block_proc();
        rb_funcallv(proc, rb_intern("call"), 0, null);
    }
    double after = p.x;
    return to_ruby_value(before == after ? before : -1.0);
}

public:

pragma(mangle, "Init_exp_nonregression")
extern (C) void Init_exp_nonregression()
{
    rt_init();

    VALUE m = rb_define_module("DNonReg");
    def!("DNonReg", nr_fib, "fib");
    def!("DNonReg", nr_sleep_gvl, "sleep_gvl");
    def!("DNonReg", nr_nap_nogvl, "nap_nogvl");
    def!("DNonReg", nr_helper_check, "helper_check");

    VALUE c = rb_define_class("DNonRegBox", rb_cObject);
    box_proto_install(c);
    rb_define_method(c, "initialize", cast(AnyMethod) &box_init, 2);
    rb_define_method(c, "[]", cast(AnyMethod) &box_nth, 1);
    rb_define_method(c, "[]=", cast(AnyMethod) &box_set, 2);
    rb_define_method(c, "roundtrip", cast(AnyMethod) &box_roundtrip, 0);
}
