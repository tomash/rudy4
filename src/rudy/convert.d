/// Two-way conversions between native D values and Ruby VALUEs.
/// D2 rewrite of the original RuDy make_object.d (2010), now calling only
/// exported Ruby functions — no struct peeking.

module rudy.convert;

import rudy.bind.value;
import std.traits;
import std.string : toStringz;
import std.exception : enforce;


// ---------------------------------------------------------------- helpers

/// Opt-in raw-VALUE passthrough for def!'d function parameters.
///
///     VALUE identity(VALUE v) ...  -> DECODED as ulong (VALUE is aliased
///     to ulong, and d_type now decodes it instead of passing the raw
///     tagged pointer through).
///
///     Raw!VALUE identity(Raw!VALUE v) ... -> raw, untouched VALUE.
///
/// Rationale: VALUE is `alias ulong VALUE`, so "parameter is VALUE" can't
/// be detected as a distinct type — and a plain `ulong` param used to hit
/// the old raw-passthrough branch, receiving the TAGGED value (Ruby 5
/// arrived as 11). Passthrough is now explicit: wrap in Raw!(...) to say
/// "give me the bits untouched".
struct Raw(T)
{
    T value;
}

/// Compile-time check: is T the Raw!(...) passthrough wrapper?
template isRaw(T)
{
    static if (is(T == Raw!R, R))
        enum isRaw = true;
    else
        enum isRaw = false;
}

/// Type traits the old rudy/ replaced its meta/ directory for.
template isDynamicArrayType(T)  { enum bool isDynamicArrayType = isDynamicArray!T; }
template isStaticArrayType(T)   { enum bool isStaticArrayType = isStaticArray!T; }
template isAssocArrayType(T)    { enum bool isAssocArrayType = is(T == V[K], V, K); }

/// Byte length of a Ruby String, the exported-API way. History: the old
/// code sliced rb_str_strlen (a CHARACTER count) as a byte count —
/// truncating every multibyte string (finding #12) — and the natural fix
/// target rb_str_bytes_len turned out to be inline-macro-only, NOT
/// exported (caught locally by a symbol-lookup crash; the ABI audit would
/// have caught it in CI). Ruby's own String#bytesize is the exact answer;
/// rb_intern lazily, idempotently (VM is alive inside any method call).
private __gshared ID rudy_id_bytesize;

private long rudy_bytesize(VALUE str)
{
    if (!rudy_id_bytesize)
        rudy_id_bytesize = rb_intern("bytesize");
    return cast(long) rb_num2ll(rb_funcallv(str, rudy_id_bytesize, 0, null));
}

/// Reject negative values where the D target type is unsigned: the
/// numeric family (rb_num2ulong / rb_num2uint) would otherwise wrap
/// them 2's-complement style (-1 arrived as 2^64-1, finding #13 family).
private void rudy_check_unsigned(VALUE val)
{
    // Sign via double: rb_num2long would itself raise on values above
    // LONG_MAX (2^64-1 is a legitimate ulong). Sign survives the cast;
    // NaN/inf fail the comparison and get caught by num2ulong below.
    if (rb_num2dbl(val) < 0)
        rb_raise(rb_eRangeError, "negative value not convertible to unsigned D type");
}

/// Require a Ruby feature (e.g. "complex") before using it from D.
private void rb_require_c(string name)
{
    VALUE req = rb_str_new(name.ptr, cast(C_long) name.length);
    VALUE[1] av = [req];
    rb_funcallv(rb_cObject, rb_intern("require"), 1, av.ptr);
}

// ---------------------------------------------------------------- to_ruby_value

/// Convert a native D value into a Ruby VALUE.
VALUE to_ruby_value(T)(T t)
{
    static if (isRaw!T)               // Raw!VALUE -> pass bits through
        return t.value;
    else static if (is(T == bool))
        return t ? Qtrue_ : Qfalse_;

    else static if (is(T == char))
        return rb_int2inum(t);

    else static if (is(T == ulong) || is(T == C_ulonglong))
        return rb_ull2inum(cast(C_ulonglong) t);   // unsigned encode path —
                                                   // the old signed
                                                   // rb_ll2inum(cast(long))
                                                   // turned 2^64-1 into -1
                                                   // (finding #15)

    else static if (is(T : C_longlong))
        return rb_ll2inum(cast(long) t);

    else static if (is(T : C_long))
        return rb_int2inum(cast(int) t);

    else static if (is(T : double))            // float, real promote
        return rb_float_new(cast(double) t);

    else static if (is(T == creal) || is(T == cdouble))
    {
        rb_require_c("complex");
        VALUE c = rb_const_get(rb_cObject, rb_intern("Complex"));
        VALUE[2] av = [to_ruby_value(t.re), to_ruby_value(t.im)];
        return rb_funcallv(c, rb_intern("new"), 2, av.ptr);
    }

    else static if (is(T == string))
        return rb_str_new(t.ptr, cast(C_long) t.length);

    else static if (isDynamicArrayType!T)
    {
        VALUE ary = rb_ary_new_capa(cast(C_long) t.length);
        foreach (ref e; t)
            rb_ary_push(ary, to_ruby_value(e));
        return ary;
    }

    else static if (isStaticArrayType!T)
    {
        VALUE ary = rb_ary_new_capa(cast(C_long) t.length);
        foreach (ref e; t)
            rb_ary_push(ary, to_ruby_value(e));
        return ary;
    }

    else static if (isAssocArrayType!T)
    {
        VALUE hash = rb_hash_new();
        foreach (k, ref v; t)
            rb_hash_aset(hash, to_ruby_value(k), to_ruby_value(v));
        return hash;
    }

    else static assert(0, "to_ruby_value: no conversion for " ~ T.stringof);
}


// ---------------------------------------------------------------- d_type

/// Convert a Ruby VALUE into a native D type T.
///
/// Numeric decode order matters: EXACT types must be tested before the
/// subtype branches they would otherwise fall into — is(T : C_longlong)
/// matches int too, and the old chain let `int` decode through the
/// unchecked-wide path. Each exact type now gets Ruby's own
/// range-checked converter: rb_num2int/rb_num2uint raise RangeError on
/// overflow (finding #13: silent wraparound before), fractional floats
/// truncate toward zero and NaN/inf raise FloatDomainError — exactly
/// NUM2INT/NUM2UINT/Integer() semantics (finding #14).
T d_type(T)(VALUE val)
{
    static if (is(T == bool))
    {
        // RUBY_TEST (RTEST) semantics: nil/false are false, everything
        // else — 0, 0.0, "" — is true, matching Ruby's own truthiness.
        // (The old `val == Qtrue_` made Ruby truthy 0 decode as D false.)
        return val != Qnil_ && val != Qfalse_;
    }
    else static if (is(T == string))
    {
        VALUE str = rb_str_to_str(val);
        auto ptr = rb_string_value_ptr(&str);   // may swap str in-place
        return ptr[0 .. rudy_bytesize(str)].idup;   // BYTE length, not chars
                                                    // (finding #12)
    }

    // exact unsigned machine words first (VALUE itself is a ulong alias)
    else static if (is(T == ulong) || is(T == C_ulonglong))
    {
        rudy_check_unsigned(val);          // -1 must raise, not wrap
        return cast(T) rb_num2ulong(val);
    }  // a ulong param still means
                                           // "Ruby Integer -> machine word",
                                           // NOT raw passthrough
    else static if (is(T == int))
        return cast(T) rb_num2int(val);    // range-checked (finding #13)
    else static if (is(T == uint))
    {
        rudy_check_unsigned(val);
        return cast(T) rb_num2uint(val);   // range-checked (finding #13)
    }

    // remaining signed subtypes (long, char, short...): wide is fine
    else static if (is(T : C_longlong))
        return cast(T) rb_num2ll(val);

    // remaining unsigned subtypes (ubyte, ushort...): range-checked
    else static if (is(T : uint))
    {
        rudy_check_unsigned(val);
        return cast(T) rb_num2uint(val);
    }

    else static if (is(T : double))
        return cast(T) rb_num2dbl(val);

    else static assert(0, "d_type: no conversion to " ~ T.stringof);
}

/// NB: D's uninitialized `double x;` is NaN (float.init), NOT 0.0 as in C.
/// Always explicitly initialize double accumulators: `double x = 0.0;` —
/// otherwise every sum silently becomes NaN (issue #3).

/// Raise a Ruby exception from D.
void rudy_raise(VALUE exc, string msg)
{
    rb_raise(exc, "%s", toStringz(msg));
}
