/// EXPERIMENT 5 — TypedData allocation/free storm under GC pressure.
///
/// Torture elements:
/// - Ruby threads hammer DExpStorm.make(n) -> n malloc'd TypedData wrappers,
///   dropped immediately (Ruby GC churns them), each dfree bumps an ATOMIC
///   D-side counter: allocation/free must balance exactly at the end.
/// - While the Ruby storm runs, a D-side native thread churns D-GC memory
///   (large struct arrays) and forces GC.collect()s — exercising the D
///   collector while Ruby's collector runs in other OS threads.
/// - Cross-thread free counting proves dfree callbacks are actually invoked
///   (freed == allocated) and that typed-data free is thread-safe w.r.t.
///   a concurrently-running D GC.
///
/// Layout:
///   DExpStorm.make(n)        -> allocate n wrappers, return the last one
///   DExpStorm.alloc_count    -> total wrappers allocated (monotonic)
///   DExpStorm.free_count     -> total dfree callbacks run
///   DExpStorm.start_churn / stop_churn -> D background GC churn on/off
///   DExpStorm.churn_cycles   -> how many churn cycles completed
///   DExpStorm.balance        -> alloc_count - free_count (== live wrappers)
///
/// What can go wrong (the point of the torture):
/// - dfree never called (leak) -> free_count stalls below alloc_count
/// - dfree called twice -> free_count > alloc_count (corruption)
/// - race on the counters between Ruby threads + D thread -> torn reads
///   (counters must be shared, atomic ops via core.atomic)

module exp_gcstorm;

import rudy.bind.value;
import rudy.convert;
import rudy.typeddata;

import core.atomic : atomicOp, atomicLoad;
import core.thread : Thread;
import core.time : msecs;
import core.memory : GC;
import core.runtime : rt_init;
import core.stdc.stdlib : malloc, free;
import std.conv : to;

private:

// A struct with real payload so malloc'd memory is actually used
struct StormCell
{
    double[16] payload;
    ulong serial;
}

// dfree for this experiment: count the free, then release the malloc'd
// cell. The free runs on Ruby's GC thread — a DIFFERENT OS thread than
// make() — which is exactly the cross-thread race the storm tests.
extern (C) void stormcell_free(void* p)
{
    atomicOp!"+="(free_count, 1);
    free(p);
}

// The mixin wires our counting dfree into the descriptor directly (third
// template param) — no need for a hand-built second descriptor, which the
// first version of this experiment did (and which was silently unused:
// stormcell_wrap always wrapped with the ORIGINAL descriptor, so free_count
// stayed 0 — torture finding #6: the mixin's wrap function hard-codes
// `&name_type`, so overriding .dfree on a copied descriptor does nothing).
mixin RudyTypedData!(StormCell, "stormcell", &stormcell_free);

shared long alloc_count;     // bumped by make() under GVL (no race with dfree)
shared long free_count;     // bumped by dfree from Ruby GC threads
shared long churn_cycles;   // bumped by the D background thread

// ---------------------------------------------------------- Ruby API

extern (C) VALUE make(VALUE self, VALUE n)
{
    long count = d_type!long(n);
    VALUE last = Qnil_;
    foreach (i; 0 .. count)
    {
        auto cell = cast(StormCell*) malloc(StormCell.sizeof);
        cell.serial = cast(ulong) atomicOp!"+="(alloc_count, 1);
        cell.payload[] = 1.5;             // touch the memory
        last = stormcell_wrap(rb_cObject, cell);
        // immediately drop `last` from Ruby's perspective: not stored
        // anywhere, next iteration overwrites the reference.
    }
    return last;
}

extern (C) VALUE get_alloc_count(VALUE self) { return rb_int2inum(atomicLoad(alloc_count)); }
extern (C) VALUE get_free_count(VALUE self)  { return rb_int2inum(atomicLoad(free_count)); }
extern (C) VALUE get_balance(VALUE self)
{
    return rb_int2inum(atomicLoad(alloc_count) - atomicLoad(free_count));
}

// ---------------------------------------------------------- D churn thread

shared bool churning;             // D keyword-safe flag read by the thread
__gshared Thread churn_thread;

// Plain D function (NOT extern (C)): core.thread.Thread's ctor wants
// `void function()` and an extern (C) function has a different D type even
// though the machine code is identical.
void churn_loop()
{
    while (atomicLoad(churning))
    {
        // churn: allocate and drop D-GC memory, forcing collections
        auto junk = new StormCell[10_000];
        foreach (ref c; junk) c.serial = 42;
        atomicOp!"+="(churn_cycles, 1);
        // D GC runs while Ruby GC frees wrappers in other threads
        if (atomicLoad(churning))
            GC.collect();
        Thread.getThis.sleep(10.msecs);
    }
}

extern (C) VALUE start_churn(VALUE self)
{
    if (churn_thread !is null) return Qfalse_;
    churning = true;
    churn_thread = new Thread(&churn_loop);
    churn_thread.isDaemon = true;
    churn_thread.start();
    return Qtrue_;
}

extern (C) VALUE stop_churn(VALUE self)
{
    churning = false;
    if (churn_thread !is null)
    {
        churn_thread.join();
        churn_thread = null;
    }
    return Qnil_;
}

extern (C) VALUE get_churn_cycles(VALUE self) { return rb_int2inum(atomicLoad(churn_cycles)); }

// ---------------------------------------------------------- init

pragma(mangle, "Init_exp_gcstorm")
extern (C) void Init_exp_gcstorm()
{
    // TORTURE FINDING #5: a GDC-compiled .so dlopened by Ruby NEVER runs
    // rt_init(). The D GC lazy-initializes on first `new`, but core.time's
    // _ticksPerSecond is filled only by _d_initMonoTime() from rt_init().
    // Calling MonoTime/Thread.sleep from a D thread then hard-aborts with
    // "MonoTimeImpl failed to get the frequency of the system's monotonic
    // clock." (druntime core/time.d abort) — seen as a process-wide SIGABRT
    // racing the Ruby VM. Any D extension that spawns threads, sleeps, or
    // uses GC.collect() must call rt_init() itself in its Init hook.
    rt_init();

    // descriptor is generated by the mixin with the counting free func
    // wired in via template parameter — nothing to patch here.

    VALUE m = rb_define_module("DExpStorm");
    rb_define_module_function(m, "make", cast(AnyMethod) &make, 1);
    rb_define_module_function(m, "alloc_count", cast(AnyMethod) &get_alloc_count, 0);
    rb_define_module_function(m, "free_count", cast(AnyMethod) &get_free_count, 0);
    rb_define_module_function(m, "balance", cast(AnyMethod) &get_balance, 0);
    rb_define_module_function(m, "start_churn", cast(AnyMethod) &start_churn, 0);
    rb_define_module_function(m, "stop_churn", cast(AnyMethod) &stop_churn, 0);
    rb_define_module_function(m, "churn_cycles", cast(AnyMethod) &get_churn_cycles, 0);
}
