/// dtypetest — acceptance-test extension for rudy.typeddata.
///
/// Same Matrix as exp_wrap, but wrapped with the TypedData API instead of
/// rb_data_object_wrap + D-side registry: rb_data_typed_object_wrap provides
/// the descriptor, rb_check_typeddata does the unwrap with type checking.
/// Exercises: alloc func, initialize, get/set, det, to_a, GC stress,
/// TypeError on wrong-type unwrap.

module dtypetest;

import rudy.bind.value;
import rudy.convert;
import rudy.typeddata;
import core.stdc.stdlib : calloc, malloc, free;
import core.memory : GC;

private:

struct Matrix
{
    size_t rows, cols;
    double* data;   // malloc'd; freed by dfree (rudy_typed_free frees the
                    // struct itself; data is freed here by matrix_dfree)

    ref double at(size_t r, size_t c) { return data[r * cols + c]; }
}

// dfree must free data first, then the struct — custom free callback.
extern (C) void matrix_dfree(void* p)
{
    auto m = cast(Matrix*) p;
    if (m)
    {
        if (m.data) free(m.data);
        free(m);
    }
}

mixin RudyTypedData!(Matrix, "matrix");

// ---------------------------------------------------------------- methods

extern (C) VALUE dtypetest_alloc(VALUE klass)
{
    auto m = cast(Matrix*) calloc(1, Matrix.sizeof);
    return matrix_wrap(klass, m);
}

extern (C) VALUE dtm_initialize(VALUE self, VALUE r, VALUE c)
{
    Matrix* m = matrix_get(self);
    m.rows = cast(size_t) d_type!long(r);
    m.cols = cast(size_t) d_type!long(c);
    m.data = cast(double*) calloc(Matrix.sizeof, m.rows * m.cols);
    return self;
}

extern (C) VALUE dtm_get(VALUE self, VALUE r, VALUE c)
{
    Matrix* m = matrix_get(self);
    return to_ruby_value(m.at(d_type!long(r), d_type!long(c)));
}

extern (C) VALUE dtm_set(VALUE self, VALUE r, VALUE c, VALUE v)
{
    Matrix* m = matrix_get(self);
    m.at(d_type!long(r), d_type!long(c)) = d_type!double(v);
    return v;
}

double det_rec(Matrix* m)
{
    if (m.rows == 1) return m.at(0, 0);
    if (m.rows == 2)
        return m.at(0, 0) * m.at(1, 1) - m.at(0, 1) * m.at(1, 0);
    double det = 0.0;   // NB: bare `double det;` is NaN in D!
    foreach (j; 0 .. m.cols)
    {
        Matrix minor;
        minor.rows = m.rows - 1;
        minor.cols = m.cols - 1;
        minor.data = cast(double*) malloc(double.sizeof * minor.rows * minor.cols);
        scope (exit) free(minor.data);
        foreach (ri; 0 .. minor.rows)
            foreach (ci; 0 .. minor.cols)
                minor.at(ri, ci) = m.at(ri + 1, ci < j ? ci : ci + 1);
        double sign = (j % 2) ? -1.0 : 1.0;
        det += sign * m.at(0, j) * det_rec(&minor);
    }
    return det;
}

extern (C) VALUE dtm_det(VALUE self)
{
    Matrix* m = matrix_get(self);
    return to_ruby_value(det_rec(m));
}

extern (C) VALUE dtm_to_a(VALUE self)
{
    Matrix* m = matrix_get(self);
    VALUE outer = rb_ary_new_capa(cast(C_long) m.rows);
    foreach (r; 0 .. m.rows)
    {
        VALUE row = rb_ary_new_capa(cast(C_long) m.cols);
        foreach (c; 0 .. m.cols)
            rb_ary_push(row, to_ruby_value(m.at(r, c)));
        rb_ary_push(outer, row);
    }
    return outer;
}

// stress: allocate & drop 100_000 typed wrappers; matrix_dfree must run
extern (C) VALUE dtm_stress(VALUE self, VALUE n)
{
    foreach (i; 0 .. d_type!long(n))
    {
        auto m = cast(Matrix*) calloc(1, Matrix.sizeof);
        m.rows = m.cols = 4;
        m.data = cast(double*) malloc(double.sizeof * 16);
        VALUE obj = matrix_wrap(dmatrix_klass, m);
        rb_ary_store(dtypetest_keep, 0, obj); // keep only last
    }
    GC.collect;
    VALUE mod = rb_const_get(rb_cObject, rb_intern("GC"));
    rb_funcallv(mod, rb_intern("start"), 0, null);
    return Qnil_;
}

// class-level helper: unwrap another object (used to test TypeError)
extern (C) VALUE dtm_unwrap_other(VALUE self, VALUE obj)
{
    Matrix* m = matrix_get(obj);   // raises TypeError if obj isn't ours
    return to_ruby_value(cast(long) (m.rows * m.cols));
}

private __gshared VALUE dmatrix_klass;
private __gshared VALUE dtypetest_keep;

public:

pragma(mangle, "Init_dtypetest")
extern (C) void Init_dtypetest()
{
    VALUE cDTypeMatrix = rb_define_class("DTypeMatrix", rb_cObject);
    rb_define_alloc_func(cDTypeMatrix, &dtypetest_alloc);
    rb_define_method(cDTypeMatrix, "initialize", cast(AnyMethod) &dtm_initialize, 2);
    rb_define_method(cDTypeMatrix, "[]",         cast(AnyMethod) &dtm_get, 2);
    rb_define_method(cDTypeMatrix, "[]=",         cast(AnyMethod) &dtm_set, 3);
    rb_define_method(cDTypeMatrix, "det",         cast(AnyMethod) &dtm_det, 0);
    rb_define_method(cDTypeMatrix, "to_a",        cast(AnyMethod) &dtm_to_a, 0);
    rb_define_method(cDTypeMatrix, "stress",     cast(AnyMethod) &dtm_stress, 1);
    rb_define_method(cDTypeMatrix, "unwrap_other",cast(AnyMethod) &dtm_unwrap_other, 1);
    dmatrix_klass = cDTypeMatrix;
    dtypetest_keep = rb_ary_new();
    rb_gc_register_address(&dtypetest_keep);
    VALUE m = rb_define_module("DTypeTest");
    rb_define_const(m, "SIZEOF", to_ruby_value(Matrix.sizeof));
}