/// EXPERIMENT 1 — Wrap a real D struct as a Ruby object.
///
/// Torture elements:
/// - heap-allocated D state (Matrix) owned by a Ruby object via
///   rb_data_object_wrap with mark/free callbacks
/// - recursive algorithm (determinant by Laplace) crossing the D/Ruby
///   boundary on every level
/// - mutation from Ruby (set) vs read (get)
/// - GC pressure: allocate/discard many wrappers in a loop
///
/// Uses VALUE passthrough args (trampoline-supported) for self.

module exp_wrap;

import rudy.bind.value;
import rudy.convert;
import rudy.defs;
import core.memory : GC;


private static class RudyWrapError : Error { this(string m) { super(m); } }

private:

struct Matrix
{
    size_t rows, cols;
    double* data;   // malloc'd, freed by the wrap free func

    ref double at(size_t r, size_t c) { return data[r * cols + c]; }
}

// FINDING: rb_data_object_get is an inline C macro (RDATA(obj)->data),
// NOT exported by libruby. Since rudy avoids struct access, we keep a
// D-side registry: wrapper VALUE (via rb_obj_id) -> Matrix*, cleaned up
// in the free callback via a reverse map.
private Matrix*[ulong] registry;        // key: rb_obj_id(wrapper)
private ulong[void*] reverse_registry;  // key: Matrix* -> rb_obj_id
private VALUE dmatrix_class;            // set in Init, used by stress
private VALUE expwrap_keep;              // Ruby Array that pins the latest wrapper

extern (C) void matrix_free(void* p)
{
    import core.stdc.stdlib : free;
    auto m = cast(Matrix*) p;
    if (auto pid = p in reverse_registry)
    {
        registry.remove(*pid);
        reverse_registry.remove(p);
    }
    if (m && m.data) free(m.data);
    if (m) free(m);
}

private Matrix* get_matrix(VALUE self)
{
    auto pid = rb_obj_id(self);
    auto pm = pid in registry;
    if (pm is null)
        rudy_raise(rb_eRuntimeError, "unregistered DMatrix (internal error)");
    return *pm;
}

// Matrix allocated by `alloc` — the RUBY_DATA_FUNC shape for alloc funcs
extern (C) VALUE dmat_alloc(VALUE klass)
{
    import core.stdc.stdlib : calloc;
    auto m = cast(Matrix*) calloc(1, Matrix.sizeof);
    VALUE obj = rb_data_object_wrap(klass, cast(void*) m, null, &matrix_free);
    // store registry entries keyed by object identity
    auto id = rb_obj_id(obj);
    registry[id] = m;
    reverse_registry[m] = id;
    return obj;
}

extern (C) VALUE dmat_initialize(VALUE self, VALUE r, VALUE c)
{
    auto m = get_matrix(self);
    m.rows = cast(size_t) d_type!long(r);
    m.cols = cast(size_t) d_type!long(c);
    import core.stdc.stdlib : calloc;
    m.data = cast(double*) calloc(Matrix.sizeof, m.rows * m.cols);
    return self;
}

extern (C) VALUE dmat_set(VALUE self, VALUE r, VALUE c, VALUE v)
{
    auto m = get_matrix(self);
    m.at(d_type!long(r), d_type!long(c)) = d_type!double(v);
    return v;
}

extern (C) VALUE dmat_get(VALUE self, VALUE r, VALUE c)
{
    auto m = get_matrix(self);
    return to_ruby_value(m.at(d_type!long(r), d_type!long(c)));
}

double matrix_det(Matrix* m)
{
    if (m.rows == 1) return m.at(0, 0);
    if (m.rows == 2) return m.at(0, 0) * m.at(1, 1) - m.at(0, 1) * m.at(1, 0);
    double det = 0.0;   // NB: bare `double det;` is NaN in D!
    foreach (j; 0 .. m.cols)
    {
        Matrix minor;
        minor.rows = m.rows - 1;
        minor.cols = m.cols - 1;
        import core.stdc.stdlib : malloc;
        minor.data = cast(double*) malloc(double.sizeof * minor.rows * minor.cols);
        scope (exit) { import core.stdc.stdlib : free; free(minor.data); }
        foreach (ri; 0 .. minor.rows)
            foreach (ci; 0 .. minor.cols)
                minor.at(ri, ci) =
                    m.at(ri + 1, ci < j ? ci : ci + 1);
        double sign = (j % 2) ? -1.0 : 1.0;
        det += sign * m.at(0, j) * matrix_det(&minor);
    }
    return det;
}

extern (C) VALUE dmat_det(VALUE self)
{
    auto m = get_matrix(self);
    return to_ruby_value(matrix_det(m));
}

extern (C) VALUE dmat_to_a(VALUE self)
{
    auto m = get_matrix(self);
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

// stress: allocate & drop 100_000 wrappers; if free callbacks never fire,
// we leak ~100k * (Matrix + data) — watch RSS
extern (C) VALUE dmat_stress(VALUE self, VALUE n)
{
    foreach (i; 0 .. d_type!long(n))
    {
        import core.stdc.stdlib : calloc, malloc;
        auto m = cast(Matrix*) calloc(1, Matrix.sizeof);
        m.rows = m.cols = 4;
        m.data = cast(double*) malloc(double.sizeof * 16);
        VALUE obj = rb_data_object_wrap(dmatrix_class, cast(void*) m, null, &matrix_free);
        auto id = rb_obj_id(obj);
        registry[id] = m;
        reverse_registry[m] = id;
        rb_ary_store(expwrap_keep, 0, obj); // keep only last; free func cleans registry
    }
    GC.collect;
    // ask Ruby to GC too
    VALUE mod = rb_const_get(rb_cObject, rb_intern("GC"));
    rb_funcallv(mod, rb_intern("start"), 0, null);
    return Qnil_;
}

public:

pragma(mangle, "Init_exp_wrap")
extern (C) void Init_exp_wrap()
{
    VALUE cDMatrix = rb_define_class("DMatrix", rb_cObject);
    rb_define_alloc_func(cDMatrix, &dmat_alloc);
    rb_define_method(cDMatrix, "initialize", cast(AnyMethod) &dmat_initialize, 2);
    rb_define_method(cDMatrix, "[]",        cast(AnyMethod) &dmat_get, 2);
    rb_define_method(cDMatrix, "[]=",        cast(AnyMethod) &dmat_set, 3);
    rb_define_method(cDMatrix, "det",        cast(AnyMethod) &dmat_det, 0);
    rb_define_method(cDMatrix, "to_a",       cast(AnyMethod) &dmat_to_a, 0);
    rb_define_method(cDMatrix, "stress",     cast(AnyMethod) &dmat_stress, 1);
    VALUE dext = rb_define_module("ExpWrap");
    dmatrix_class = cDMatrix;
    expwrap_keep = rb_ary_new();
    rb_iv_set(dext, "@keep", expwrap_keep);
    // root the keep-array so GC never collects it (it's reachable from the
    // module, but belt & braces since we hold a raw D reference)
    rb_gc_register_address(&expwrap_keep);
}