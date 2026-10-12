/// exp_convert — torture the D↔Ruby conversion layer (rudy/convert.d).
///
/// Round-trip property: for every supported type, D→Ruby→D must be
/// lossless even under adversarial values: long.min, NaN/±0.0/inf,
/// empty/NUL/binary strings (EUC-JP, non-UTF-8 bytes), frozen strings,
/// truthiness edge cases, and GC pressure mid-conversion.
/// Each extern(C) function is registered by test_exp_convert.rb and
/// driven from Ruby with hostile inputs.

module exp_convert;

import rudy.bind.value;
import rudy.convert;
import core.runtime : rt_init;
import core.memory : GC;

private:

// ---------------------------------------------------------------- round-trip identities
// Registered directly via rb_define_method: Ruby->D via d_type!T,
// return D->Ruby via to_ruby_value. Exactly the path def! uses.

extern (C) VALUE conv_long(VALUE self, VALUE v)   { return to_ruby_value(d_type!long(v)); }
extern (C) VALUE conv_ulong(VALUE self, VALUE v)  { return to_ruby_value(d_type!ulong(v)); }
extern (C) VALUE conv_int(VALUE self, VALUE v)    { return to_ruby_value(d_type!int(v)); }
extern (C) VALUE conv_uint(VALUE self, VALUE v)   { return to_ruby_value(d_type!uint(v)); }
extern (C) VALUE conv_double(VALUE self, VALUE v) { return to_ruby_value(d_type!double(v)); }
extern (C) VALUE conv_string(VALUE self, VALUE v) { return to_ruby_value(d_type!string(v)); }
extern (C) VALUE conv_bool(VALUE self, VALUE v)   { return to_ruby_value(d_type!bool(v)); }

// ---------------------------------------------------------------- strings: byte-length probe
// d_type!string must decode ANY String — empty, NUL-laden, binary,
// non-UTF-8 — without throwing D-side, and preserve the byte count
// exactly (finding #12: rb_str_strlen chars-vs-bytes truncation).
// Non-String inputs raise Ruby-side (rb_str_to_str TypeError).

extern (C) VALUE conv_string_bytesize(VALUE self, VALUE v)
{
    auto s = d_type!string(v);        // binary-safe: copies raw bytes
    return to_ruby_value(s.length);   // byte length of the D copy
}

// Same probe with a GC.collect() parked between decode and re-encode:
// the D-side copy must not be the only thing keeping Ruby-side state
// sane, and the Ruby input String must not be resurrectable-but-stale.
extern (C) VALUE conv_string_stress(VALUE self, VALUE v)
{
    auto s = d_type!string(v);
    GC.collect();
    return to_ruby_value(s);
}

// ---------------------------------------------------------------- symbols: reject, not corrupt
// There is no symbol branch in d_type!string — it is a compile-time
// static assert in the library. What must hold at runtime: passing a
// Symbol raises Ruby-side (rb_str_to_str: TypeError), and Ruby's own
// symbol<->string traffic through D stays byte-perfect.

extern (C) VALUE conv_sym_to_s(VALUE self, VALUE sym)
{
    // rb_sym2str is exported but not bound; ask Ruby instead
    return rb_funcallv_public(sym, rb_intern("to_s"), 0, null);
}

extern (C) VALUE conv_sym_roundtrip(VALUE self, VALUE str)
{
    // String -> Symbol -> String, all via rb_funcallv_public
    VALUE sym = rb_funcallv_public(str, rb_intern("to_sym"), 0, null);
    return rb_funcallv_public(sym, rb_intern("to_s"), 0, null);
}

// ---------------------------------------------------------------- Init

public:

pragma(mangle, "Init_exp_convert")
extern (C) void Init_exp_convert()
{
    rt_init();   // dlopen'd .so: D runtime init is our job (finding #9)

    VALUE m = rb_define_module("ConvertProbe");
    rb_define_module_function(m, "long",   cast(AnyMethod) &conv_long,   1);
    rb_define_module_function(m, "ulong",  cast(AnyMethod) &conv_ulong,  1);
    rb_define_module_function(m, "int",    cast(AnyMethod) &conv_int,    1);
    rb_define_module_function(m, "uint",   cast(AnyMethod) &conv_uint,   1);
    rb_define_module_function(m, "double", cast(AnyMethod) &conv_double, 1);
    rb_define_module_function(m, "string", cast(AnyMethod) &conv_string, 1);
    rb_define_module_function(m, "bool",   cast(AnyMethod) &conv_bool,   1);
    rb_define_module_function(m, "string_bytesize", cast(AnyMethod) &conv_string_bytesize, 1);
    rb_define_module_function(m, "string_stress",   cast(AnyMethod) &conv_string_stress,   1);
    rb_define_module_function(m, "sym_to_s",        cast(AnyMethod) &conv_sym_to_s,        1);
    rb_define_module_function(m, "sym_roundtrip",   cast(AnyMethod) &conv_sym_roundtrip,   1);
}
