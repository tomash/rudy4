/// Typed-data wrapping for D structs as Ruby objects.
///
/// EXPERIMENT 1 (exp_wrap) discovered that `rb_data_object_get` is an inline
/// C macro (`RDATA(obj)->data`), not an exported symbol — it cannot be called
/// from D. The workaround used a D-side registry keyed by rb_obj_id.
///
/// This module replaces that workaround with the modern TypedData API, all
/// of whose entry points ARE exported functions:
///
/// - `rb_data_typed_object_wrap` — wrap with a `rb_data_type_t` descriptor
/// - `rb_check_typeddata`        — unwrap with type checking
/// - `rb_data_typed_object_zalloc` — zero-allocated wrap (like alloc func)
///
/// Usage:
///
///     struct Matrix { ... }
///     // 1. define the data type descriptor (one per D struct type)
///     mixin RudyTypedData!(Matrix, "matrix");  // exposes: matrix_type
///                                             //           matrix_wrap
///                                             //           matrix_get
///     // 2. wrap
///     VALUE obj = matrix_wrap(m, klass);
///     // 3. unwrap (raises TypeError if not a Matrix wrapper)
///     Matrix* m = matrix_get(obj);
///
/// dfree is generated automatically: `GC-free-able` structs (allocated by
/// D's GC) are freed by the GC; C-malloc'd structs are freed with free().
/// Pass your own free callback to the mixin if you need custom cleanup.

module rudy.typeddata;

import rudy.bind.value;
import rudy.convert;

public:

// ---------------------------------------------------------------- layout

/// D mirror of ruby.h's rb_data_type_struct (layout-compatible subset).
///
/// Field name differences vs the C header (D keyword collisions / style):
///   C `function` sub-struct -> `function_`   (`function` is a D keyword)
/// D-side structs only mirror the C layout; Ruby never reads the names.
struct RbDataFunction
{
    RUBY_DATA_FUNC_MARK dmark;
    RUBY_DATA_FUNC_FREE dfree;
    extern (C) size_t function(const void*) dsize;
    RUBY_DATA_FUNC_MARK dcompact;
    void*[1] reserved;                    // must be zero
}

struct RbDataType
{
    const(char)* wrap_struct_name;
    RbDataFunction function_;
    const(RbDataType)* parent;
    void* data;
    VALUE flags;
}

// re-export the callback aliases so users don't need value.d here
alias RUBY_DATA_FUNC_MARK = rudy.bind.value.RUBY_DATA_FUNC_MARK;
alias RUBY_DATA_FUNC_FREE = rudy.bind.value.RUBY_DATA_FUNC_FREE;

// ---------------------------------------------------------------- default free

/// Default dfree for structs allocated with D's GC: let D's GC handle it —
/// nothing to do at Ruby-GC time (pointer stays valid for D's collector).
extern (C) void rudy_typed_nofree(void* p) {}

/// Default dfree for structs allocated with malloc/calloc: free() them.
extern (C) void rudy_typed_free(void* p)
{
    import core.stdc.stdlib : free;
    free(p);
}

// ---------------------------------------------------------------- mixin template

/// Generates a typed-data descriptor + wrap/unwrap pair for struct T.
///
///     mixin RudyTypedData!(Matrix, "matrix");
///     // provides: matrix_type (RbDataType),
///     //           matrix_wrap(VALUE klass, Matrix*),
///     //           matrix_get(VALUE obj)
///
/// Pass a custom free callback as the third parameter for exotic ownership
/// models (default: malloc'd → rudy_typed_free; use &rudy_typed_nofree for
/// D-GC-owned structs).
///
/// EXPERIMENT 7 (exp_compact) — finding #11: if the wrapped struct holds
/// live VALUEs and the descriptor has no dmark, the referents are
/// collectible while the wrapper is still alive: use-after-free (observed
/// as a garbage String read back from a freed-and-reused slot). If the
/// struct holds VALUEs, ALSO pass mark/compact callbacks:
///
///     extern (C) void mycell_mark(void* p)
///     { rb_gc_mark_movable((cast(MyCell*) p).embedded); }
///     extern (C) void mycell_compact(void* p)
///     { auto c = cast(MyCell*) p; c.embedded = rb_gc_location(c.embedded); }
///     mixin RudyTypedData!(MyCell, "mycell", &rudy_typed_free,
///                          &mycell_mark, &mycell_compact);
///
/// dmark uses rb_gc_mark_movable and dcompact rewrites the slot via
/// rb_gc_location — the movable-objects protocol required by GC.compact.
///
/// NB: the generated identifiers need string mixins — D template parameters
/// do NOT become identifier names in a plain mixin template body.
template RudyTypedData(T, string name,
                      RUBY_DATA_FUNC_FREE freeFunc = &rudy_typed_free,
                      RUBY_DATA_FUNC_MARK markFunc = null,
                      RUBY_DATA_FUNC_MARK compactFunc = null)
{
    private enum cname = name ~ "\0";     // NUL-terminated, static storage

    mixin(
        "private extern (C) size_t " ~ name ~ "_dsize(const void* p)" ~
        "{" ~
        "    return T.sizeof;" ~
        "}" ~

        // The descriptor. Must outlive every wrapped object.
        "__gshared RbDataType " ~ name ~ "_type = RbDataType(" ~
        "    cname.ptr," ~
        "    RbDataFunction(markFunc, freeFunc, &" ~ name ~ "_dsize, compactFunc, [null])," ~
        "    null," ~                      // parent
        "    null," ~                      // data
        "    0);" ~                        // flags — zero is safest

        /// Wrap a T* in a Ruby object of class `klass`.
        "VALUE " ~ name ~ "_wrap(VALUE klass, T* ptr)" ~
        "{" ~
        "    return rb_data_typed_object_wrap(klass, ptr, &" ~ name ~ "_type);" ~
        "}" ~

        /// Unwrap — raises TypeError on any non-matching wrapper.
        "T* " ~ name ~ "_get(VALUE obj)" ~
        "{" ~
        "    return cast(T*) rb_check_typeddata(obj, &" ~ name ~ "_type);" ~
        "}"
    );
}