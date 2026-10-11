/// Two-way conversions between native D values and Ruby VALUEs.
/// D2 rewrite of the original RuDy make_object.d (2010), now calling only
/// exported Ruby functions — no struct peeking.

module rudy.convert;

import rudy.bind.value;
import std.traits;
import std.string : toStringz;
import std.exception : enforce;


// ---------------------------------------------------------------- helpers

/// Type traits the old rudy/ replaced its meta/ directory for.
template isDynamicArrayType(T)  { enum bool isDynamicArrayType = isDynamicArray!T; }
template isStaticArrayType(T)   { enum bool isStaticArrayType = isStaticArray!T; }
template isAssocArrayType(T)    { enum bool isAssocArrayType = is(T == V[K], V, K); }

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
    static if (is(T == bool))
        return t ? Qtrue_ : Qfalse_;

    else static if (is(T == char))
        return rb_int2inum(t);

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
T d_type(T)(VALUE val)
{
    static if (is(T == bool))            return val == Qtrue_;

    else static if (is(T == string))
    {
        VALUE str = rb_str_to_str(val);
        auto len = rb_str_strlen(str);
        auto ptr = rb_string_value_ptr(&str);   // may swap str in-place
        return ptr[0 .. len].idup;
    }

    else static if (is(T : C_longlong))  return cast(T) rb_num2ll(val);
    else static if (is(T : C_long))      return cast(T) rb_num2long(val);
    else static if (is(T : int))         return cast(T) rb_num2long(val);
    else static if (is(T : uint))        return cast(T) rb_num2ulong(val);

    else static if (is(T : double))
        return cast(T) rb_num2dbl(val);

    else static assert(0, "d_type: no conversion to " ~ T.stringof);
}


/// Raise a Ruby exception from D.
void rudy_raise(VALUE exc, string msg)
{
    rb_raise(exc, "%s", toStringz(msg));
}
