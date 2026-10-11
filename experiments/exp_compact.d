/// EXPERIMENT 7 — GC compaction vs wrapped structs and registered globals.
///
/// Torture elements:
/// - BoxCell is a wrapped D struct that HOLDS live Ruby VALUEs (a String
///   and an Array). The RudyTypedData mixin currently has NO dmark slot
///   exposed — so if Ruby's GC can't see the referents through the box,
///   they can be collected while the box survives => dangling VALUE inside
///   a live Ruby object. Then GC.compact moves survivors; stale VALUEs in
///   registered globals (and inside boxes without dcompact) point into
///   unmoved memory.
/// - globals: raw VALUEs registered via rb_gc_register_address. After
///   GC.compact, Ruby says "update your references" (rb_gc_location).
///   A D extension that ignores that keeps pre-compaction VALUEs.
///
///   Ruby API:
///     DExpCompact.make_box(str, arr)   -> DBox instance (TypedData wrap)
///     DExpCompact.read_box(obj)        -> [str, arr] back out of the box
///     DExpCompact.stash(str)           -> store in registered global, returns id
///     DExpCompact.peek_stashed(id)     -> read back (may be stale VALUE)
///     DExpCompact.refresh(id)          -> rb_gc_location refresh, returns new id
///
/// What can go wrong (the point):
/// - box holds VALUEs, nothing marks them -> collected while box alive
///   (RUBY_T_NONE garbage / segfault on read_box)
/// - GC.compact moves referents -> box's stored VALUEs / registered
///   globals go stale; rb_gc_location is required to fix them

module exp_compact;

import rudy.bind.value;
import rudy.convert;
import rudy.typeddata;

import core.runtime : rt_init;
import core.stdc.stdlib : malloc, free;

private:

// A wrapped struct that holds LIVE Ruby VALUEs — the dangerous case.
struct BoxCell
{
    VALUE str;     // a live Ruby String
    VALUE arr;     // a live Ruby Array
    ulong serial;
}

// Two descriptors for the same struct: one WITHOUT mark/compact (the old
// library behavior — kept deliberately as the negative control) and one
// WITH (finding #11 fix). The Ruby test creates both and shows that the
// unguarded box corrupts while the guarded one survives.
mixin RudyTypedData!(BoxCell, "boxcell");                       // no mark (control)

extern (C) void boxcell_mark(void* p)
{
    auto c = cast(BoxCell*) p;
    rb_gc_mark_movable(c.str);
    rb_gc_mark_movable(c.arr);
}

extern (C) void boxcell_compact(void* p)
{
    auto c = cast(BoxCell*) p;
    c.str = rb_gc_location(c.str);
    c.arr = rb_gc_location(c.arr);
}

mixin RudyTypedData!(BoxCell, "gboxcell", &rudy_typed_free,
                    &boxcell_mark, &boxcell_compact);           // guarded

__gshared VALUE boxcell_klass;
__gshared VALUE gboxcell_klass;

// ------------------------------------------------- registered globals

// stash slots for the rb_gc_register_address part of the torture.
// We keep a fixed pool so ids are stable and Ruby side can request refresh.
enum STASH_SIZE = 16;
__gshared VALUE[STASH_SIZE] stash;
__gshared bool[STASH_SIZE] stash_used;

extern (C) void stash_mark_all() {}   // placeholder (unused)

// ---------------------------------------------------------- Ruby API

extern (C) VALUE make_box(VALUE self, VALUE str, VALUE arr)
{
    auto cell = cast(BoxCell*) malloc(BoxCell.sizeof);
    cell.str = str;
    cell.arr = arr;
    cell.serial = 0;
    return boxcell_wrap(boxcell_klass, cell);
}

extern (C) VALUE make_gbox(VALUE self, VALUE str, VALUE arr)
{
    auto cell = cast(BoxCell*) malloc(BoxCell.sizeof);
    cell.str = str;
    cell.arr = arr;
    cell.serial = 0;
    return gboxcell_wrap(gboxcell_klass, cell);
}

extern (C) VALUE read_box(VALUE self, VALUE obj)
{
    // both classes share the struct layout and the same wrap_struct_name
    // would collide — gboxcell has its own name so rb_check_typeddata
    // distinguishes. We branch on the class of obj.
    BoxCell* c;
    if (obj_class_matches(obj, gboxcell_klass))
        c = gboxcell_get(obj);
    else
        c = boxcell_get(obj);
    VALUE[2] pair;
    pair[0] = c.str;
    pair[1] = c.arr;
    return rb_ary_new_from_values(2, pair.ptr);
}

private bool obj_class_matches(VALUE obj, VALUE klass)
{
    return rb_obj_class(obj) == klass;
}

extern (C) VALUE stash_value(VALUE self, VALUE str)
{
    int id = -1;
    foreach (i; 0 .. STASH_SIZE)
        if (!stash_used[i]) { id = cast(int) i; break; }
    if (id < 0) rb_raise(rb_eRuntimeError, "no free stash slot\0".ptr);
    stash[id] = str;
    stash_used[id] = true;
    return to_ruby_value!int(id);
}

extern (C) VALUE peek_stashed(VALUE self, VALUE id_v)
{
    int id = d_type!int(id_v);
    if (id < 0 || id >= STASH_SIZE || !stash_used[id])
        return Qnil_;
    return stash[id];
}

extern (C) VALUE refresh(VALUE self, VALUE id_v)
{
    int id = d_type!int(id_v);
    if (id < 0 || id >= STASH_SIZE || !stash_used[id])
        return Qnil_;
    VALUE refreshed = rb_gc_location(stash[id]);
    stash[id] = refreshed;
    return refreshed;
}

// ---------------------------------------------------------- init

pragma(mangle, "Init_exp_compact")
extern (C) void Init_exp_compact()
{
    rt_init();   // torture finding #5 (exp_gcstorm): dlopened D .so needs it

    // register the stash array with Ruby's GC — Ruby now knows these
    // slots hold VALUEs (it roots and updates-eligibles them at compaction
    // time via rb_gc_location — which WE must call to fetch new values).
    foreach (i; 0 .. STASH_SIZE)
        rb_gc_register_address(&stash[i]);

    VALUE c = rb_define_class("DBox", rb_cObject);
    boxcell_klass = c;
    VALUE gc_ = rb_define_class("DGuardedBox", rb_cObject);
    gboxcell_klass = gc_;

    VALUE m = rb_define_module("DExpCompact");
    rb_define_module_function(m, "make_box", cast(AnyMethod) &make_box, 2);
    rb_define_module_function(m, "make_gbox", cast(AnyMethod) &make_gbox, 2);
    rb_define_module_function(m, "read_box", cast(AnyMethod) &read_box, 1);
    rb_define_module_function(m, "stash", cast(AnyMethod) &stash_value, 1);
    rb_define_module_function(m, "peek_stashed", cast(AnyMethod) &peek_stashed, 1);
    rb_define_module_function(m, "refresh", cast(AnyMethod) &refresh, 1);
}
