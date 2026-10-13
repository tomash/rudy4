/// hello_gem_ext — the native half of the `hello_gem` gem (a shippable
/// D-backed Ruby extension).
///
/// Demonstrates the whole rudy4 surface in one installable gem:
///   * `def!` for global functions and instance methods, with automatic
///     D<->Ruby conversion,
///   * `RudyTypedData` + `RudyObjectProtocol` to expose a real D struct
///     (a `Vec2`) as a first-class Ruby object (allocate/dup/clone/==/hash/
///     inspect/freeze),
///   * raw `extern(C)` C-API bodies for the methods that need them.
///
/// Build with the gem's extconf.rb (see ../extconf.rb), which drives gdc.

module hello_gem;

import rudy.bind.value;
import rudy.convert;
import rudy.typeddata;
import rudy.objproto;
import rudy.defs;

import core.runtime : rt_init;
import std.string : format;

// ---------------------------------------------------------------------
// def!'d plain functions — conversion is automatic.
// ---------------------------------------------------------------------

string greet(string name) { return "hello, " ~ name ~ "!"; }

long add(long a, long b) { return a + b; }

bool is_even(long n) { return (n % 2) == 0; }

string describe(string what, int count)
{
    import std.conv : to;
    return what ~ " x" ~ count.to!string;
}

// ---------------------------------------------------------------------
// A wrapped D struct: Vec2 as a Ruby object.
// ---------------------------------------------------------------------

struct Vec2
{
    double x, y;
}

mixin RudyTypedData!(Vec2, "hello_vec2");

private string vec2_inspect(ref const Vec2 v)
{
    return format("x=%g y=%g", v.x, v.y);
}

// Companion protocol: allocate / dup / clone / == / eql? / hash / inspect.
mixin RudyObjectProtocol!(Vec2, "hello_vec2",
                          null, null, null,
                          vec2_inspect);

extern (C) VALUE vec2_initialize(VALUE self, VALUE x, VALUE y)
{
    Vec2* p = hello_vec2_get(self);
    p.x = d_type!double(x);
    p.y = d_type!double(y);
    return self;
}

extern (C) VALUE vec2_get_component(VALUE self, VALUE i)
{
    Vec2* p = hello_vec2_get(self);
    final switch (d_type!long(i)) {
        case 0: return to_ruby_value(p.x);
        case 1: return to_ruby_value(p.y);
    }
}

extern (C) VALUE vec2_set_component(VALUE self, VALUE i, VALUE v)
{
    rb_check_frozen(self);          // honour Ruby's freeze contract
    Vec2* p = hello_vec2_get(self);
    switch (d_type!long(i)) {
        case 0: p.x = d_type!double(v); break;
        default: p.y = d_type!double(v); break;
    }
    return v;
}

extern (C) VALUE vec2_norm2(VALUE self)
{
    Vec2* p = hello_vec2_get(self);
    return to_ruby_value(p.x * p.x + p.y * p.y);
}

// ---------------------------------------------------------------------
// Entry point — Ruby calls this once when the extension is required.
// ---------------------------------------------------------------------

pragma(mangle, "Init_hello_gem_ext")
extern (C) void Init_hello_gem_ext()
{
    rt_init();

    // global functions (on Object)
    def!(greet);
    def!(add);
    def!(is_even);
    def!(describe);

    // a namespaced module function
    VALUE HelloGem = rb_define_module("HelloGem");
    def!("HelloGem", greet, "module_greet");

    // the wrapped struct as a top-level class
    VALUE c = rb_define_class("HelloVec2", rb_cObject);
    hello_vec2_proto_install(c);
    rb_define_method(c, "initialize", cast(AnyMethod) &vec2_initialize, 2);
    rb_define_method(c, "[]", cast(AnyMethod) &vec2_get_component, 1);
    rb_define_method(c, "[]=", cast(AnyMethod) &vec2_set_component, 2);
    rb_define_method(c, "norm2", cast(AnyMethod) &vec2_norm2, 0);
}
