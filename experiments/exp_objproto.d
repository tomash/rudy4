/// EXPERIMENT 10 — Object protocol for wrapped structs.
///
/// A RudyTypedData wrapper without object-protocol methods is a
/// second-class Ruby citizen:
///   - dup/clone shallow-copy the WRAPPER: two handles, one struct —
///     mutating the copy mutates the "original" (finding #19)
///   - == never fires (Object#== is identity), Hash keys collide on
///     identity hash (finding #20),
///   - freeze() sets a flag nothing enforces: mutators write straight
///     through into the "frozen" struct (finding #20),
///   - inspect shows #<Class:0x...> (finding #21),
///   - allocate()/initialize_copy don't exist — Ruby-level dup/clone
///     crash with "allocator undefined" (finding #22).
///
/// The RudyObjectProtocol mixin generates the C-API-standard fix:
///   allocate   = rb_data_typed_object_zalloc (zeroed T in Ruby's heap)
///   initialize_copy = in-place struct copy (dup AND clone route
///                through this one hook; clone propagates frozen state)
///   == / eql?  = memcmp over T.sizeof (custom equalsHook allowed)
///   hash       = FNV-1a over T.sizeof (==/hash contract holds)
///   inspect    = "#<Name inner>" via hook
/// And mutators guard themselves with rb_check_frozen — the exported
/// C-API freeze enforcement, wired at def! registration sites.
///
/// Torture surface (Vec2, malloc'd in Init-set variants):
///   DVec2.new/[]  — construct via protocol'd class
///   dup/clone     — independence, frozen-state propagation
///   ==/hash       — Hash keying, Dictionary-style lookups
///   inspect       — human-readable output
///   freeze        — FrozenError from guarded mutators, read methods OK
///   GC storm      — dup'd wrappers + Ruby GC.collect + D GC.collect

module exp_objproto;

import rudy.bind.value;
import rudy.convert;
import rudy.typeddata;
import rudy.objproto;
import rudy.defs;

import core.runtime : rt_init;
import core.stdc.stdlib : malloc, free;
import core.memory : GC;
import std.string : format;

private:

struct Vec2
{
    double x, y;
    double extra;   // padding makes byte-compare non-trivial
}

mixin RudyTypedData!(Vec2, "vec2");

private string vec2_inspect(ref const Vec2 p)
{
    return format("x=%g y=%g", p.x, p.y);
}

mixin RudyObjectProtocol!(Vec2, "vec2",
                          null, null, null,
                          vec2_inspect);

__gshared VALUE vec2_klass;

// ---- mutators: rb_check_frozen wired by hand (the C-API guard) ----

extern (C) VALUE vec2_set(VALUE self, VALUE k, VALUE v)
{
    rb_check_frozen(self);
    Vec2* p = vec2_get(self);
    switch (d_type!long(k)) {
        case 0: p.x = d_type!double(v); break;
        case 1: p.y = d_type!double(v); break;
        default: p.extra = d_type!double(v); break;
    }
    return v;
}

extern (C) VALUE vec2_nth(VALUE self, VALUE k)
{
    Vec2* p = vec2_get(self);
    final switch (d_type!long(k)) {
        case 0: return to_ruby_value(p.x);
        case 1: return to_ruby_value(p.y);
        case 2: return to_ruby_value(p.extra);
    }
}

// ---- init ---------------------------------------------------------

pragma(mangle, "Init_exp_objproto")
extern (C) void Init_exp_objproto()
{
    rt_init();

    VALUE c = rb_define_class("DRudyVec", rb_cObject);
    vec2_klass = c;

    // the object protocol (allocate/initialize_copy/==/eql?/hash/inspect)
    vec2_proto_install(c);

    // simple 2-arg initialize (zalloc'd struct, then set)
    rb_define_method(c, "initialize", cast(AnyMethod) &vec2_init, 2);
    rb_define_method(c, "[]", cast(AnyMethod) &vec2_nth, 1);
    rb_define_method(c, "[]=", cast(AnyMethod) &vec2_set, 2);
    rb_define_method(c, "norm2", cast(AnyMethod) &vec2_norm2, 0);
}

extern (C) VALUE vec2_init(VALUE self, VALUE x, VALUE y)
{
    Vec2* p = vec2_get(self);
    p.x = d_type!double(x);
    p.y = d_type!double(y);
    return self;
}

extern (C) VALUE vec2_norm2(VALUE self)
{
    Vec2* p = vec2_get(self);
    return to_ruby_value(p.x * p.x + p.y * p.y);
}
