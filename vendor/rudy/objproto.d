/// Object-protocol boilerplate for RudyTypedData-wrapped structs.
///
/// A bare RudyTypedData!() wrapper gives Ruby a pointer-holding T_DATA
/// object and nothing else:
///   - `dup`/`clone` shallow-copy the WRAPPER — both handles end up
///     pointing at the same struct (finding #19),
///   - `inspect` shows the useless default `#<Class:0x...>`,
///   - two wrappers holding byte-identical structs are never `==`,
///   - `Object#hash` is identity-based, so == wrappers don't hash equal
///     and can't be Hash keys,
///   - `freeze` sets the flag but nothing enforces it: a mutator writes
///     straight through into the "frozen" struct (finding #20).
///
/// This mixin generates the missing pieces, C-API style:
///
///     struct Vec2 { double x, y; }
///     mixin RudyTypedData!(Vec2, "vec2");
///     mixin RudyObjectProtocol!(Vec2, "vec2",
///                               null, null, null,
///                               vec2_inspect);       // hooks optional
///     // in Init_*:
///     vec2_proto_install(klass);
///
/// `name` must be the SAME name passed to RudyTypedData — the generated
/// code references `<name>_get`, `<name>_type` and the class name.
///
/// What install() defines on the class:
///   allocate          rb_data_typed_object_zalloc — a zeroed T in Ruby's
///                     GC heap; dfree still runs at collection.
///   initialize_copy   struct-assignment in place (PRIVATE, like Ruby's
///                     own). Ruby implements dup AND clone through this
///                     one hook: dup = alloc + initialize_copy, clone =
///                     alloc + initialize_copy + frozen-state propagation.
///                     Optional copyHook runs after the struct copy
///                     (deep-copy malloc'd fields; see struct-copy rules).
///   == / eql?         default: memcmp over T.sizeof. Non-wrapper other
///                     -> Qfalse_ (== must not raise). eql? aliases ==.
///   hash              default: FNV-1a over T.sizeof bytes — memcmp-equal
///                     structs hash equal, keeping the ==/hash contract.
///   inspect           "#<ClassName inner>" via inspectHook; with no hook
///                     install() skips inspect entirely (Ruby's default
///                     stays).
///
/// Custom hooks (all optional, pass null to take the default). Hooks
/// are ALIAS parameters — pass the symbol BARE (no `&`): GDC 14 rejects
/// `&fn` as a template value argument entirely (finding #22). Pointer
/// and ref call conventions both work per hook:
///   copyHook    (T* dst, const(T*) src)  or  (ref T, ref const(T))
///   equalsHook  (const(T*) a, const(T*) b)  or  (ref const(T), ref const(T))
///   hashHook    (const(T*) p)  or  (ref const(T))
///   inspectHook (const(T*) p)  or  (ref const(T))
///
/// Hook users own the ==/hash contract: if equalsHook says two structs
/// are equal, hashHook must return the same value for both.
///
/// Struct-copy rules for initialize_copy (NB):
///   - pointers embedded in T are copied by VALUE (shallow). Use copyHook
///     to deep-copy malloc'd fields — free the old buffer first or the
///     allocate() zeroing leaks it on the fresh wrapper.
///   - D-GC pointers inside T do NOT survive the copy by D-GC rules: the
///     struct bytes live in Ruby's GC heap where D's collector cannot
///     see them, so a new wrapper's struct may point at memory D's GC
///     considers unreachable. Root such pointers D-side (GC.addRange /
///     a module-scope anchor) — malloc-owned fields (freed in a custom
///     dfree) are the safe pattern.

module rudy.objproto;

import rudy.bind.value;
import rudy.convert;
import rudy.typeddata;

import core.stdc.string : memcmp;
import std.string : toStringz;

public:

// Symbols the generated string-mixins reference. String-mixin bodies
// resolve names at the mixin SITE (the user's module), not here — so
// every module that instantiates RudyObjectProtocol must be able to see
// them. `public import` re-exports from any module that imports
// rudy.objproto.
public import rudy.bind.value : VALUE, Qfalse_, rb_data_typed_object_zalloc,
    rb_define_alloc_func, rb_define_private_method, rb_define_method,
    rb_define_alias, rb_obj_class, rb_class2name, rb_str_new_cstr, rb_str_cat,
    AnyMethod;
public import rudy.convert : to_ruby_value;
public import rudy.typeddata : RbDataType, RudyTypedData;

// ---------------------------------------------------------------- helpers

/// FNV-1a over n bytes — the default hash for memcmp-style ==.
size_t rudy_fnv1a(const void* p, size_t n) @nogc nothrow pure
{
    size_t h = 0xcbf29ce484222325UL;
    auto b = cast(const ubyte*) p;
    foreach (i; 0 .. n)
    {
        h ^= b[i];
        h *= 0x100000001b3UL;
    }
    return h;
}

// ---------------------------------------------------------------- mixin

// static-if for string-mixin bodies: pick one code snippet at CT.
// Lives inside the template below (per-instance) — multiple
// RudyObjectProtocol instantiations in one module cannot collide.
// Ruby's Hash#hash values are signed; mask off the sign bit so the
// unsigned machine word decodes as a non-negative Integer everywhere.
// Public so generated mixin code (resolved at the mixin site) can use it.
public enum size_t rudy_hash_mask = 0x7fff_ffff_ffff_ffffUL;

/// memcmp-style byte equality over n bytes — the default == for
/// memcmp-able structs. Public for the same reason as rudy_hash_mask.
public bool rudy_bytes_eq(const void* a, const void* b, size_t n)
{
    return memcmp(a, b, n) == 0;
}

/// Hooks are ALIAS template parameters — GDC 14 rejects `&fn` as a
/// template value argument for typed fp params (finding #22: even
/// extern(C)-linkage; only default values like typeddata's
/// `= &rudy_typed_free` parse, because defaults are normal expressions,
/// not template arguments). Pass hook symbols BARE:
///
///   mixin RudyObjectProtocol!(Vec2, "vec2", null, null, null, vec2_inspect);
///
/// Hook presence is probed with __traits(compiles, hook(args...)) —
/// no `!is null` checks (an alias may not support that). Wrong-arity
/// or non-callable aliases safely take the default path. Both call
/// conventions are accepted per hook:
///   size_t hashHook(const(T*) p)          — pointer style
///   size_t hashHook(ref const(T) p)       — ref style
/// (the mixin probes ptr-call first, then deref-call, at compile time).
template RudyObjectProtocol(T,
                            string name,
                            alias copyHook = null,
                            alias equalsHook = null,
                            alias hashHook = null,
                            alias inspectHook = null)
{
    // staticIf lives INSIDE the template: instantiated per-param, never
    // collides across multiple instantiations in one module.
    private template staticIf(bool cond, string yes, string no)
    {
        static if (cond)
            enum string staticIf = yes;
        else
            enum string staticIf = no;
    }

    // Presence probes — compile-time, per hook. Try pointer-style call
    // first, then ref-style (deref) call.
    private enum string copyCall =
        staticIf!(__traits(compiles, copyHook(cast(T*) null, cast(T*) null)),
            "    copyHook(d, s);",
        staticIf!(__traits(compiles, copyHook(*cast(T*) null, *cast(T*) null)),
            "    copyHook(*d, *s);",
            ""));

    private enum string eqCall =
        staticIf!(__traits(compiles, equalsHook(cast(const(T)*) null, cast(const(T)*) null)),
            "    return to_ruby_value(equalsHook(a, b));",
        staticIf!(__traits(compiles, equalsHook(*cast(const(T)*) null, *cast(const(T)*) null)),
            "    return to_ruby_value(equalsHook(*a, *b));",
            ""));

    private enum string hashCall =
        staticIf!(__traits(compiles, hashHook(cast(const(T)*) null)),
            "    return to_ruby_value(hashHook(p) & rudy_hash_mask);",
        staticIf!(__traits(compiles, hashHook(*cast(const(T)*) null)),
            "    return to_ruby_value(hashHook(*p) & rudy_hash_mask);",
            ""));

    private enum string inspCall =
        staticIf!(__traits(compiles, inspectHook(cast(const(T)*) null)),
            "    string inner = inspectHook(p);",
        staticIf!(__traits(compiles, inspectHook(*cast(const(T)*) null)),
            "    string inner = inspectHook(*p);",
            ""));

    private enum bool hasEquals = eqCall.length > 0;
    private enum bool hasHash = hashCall.length > 0;
    private enum bool hasInspect = inspCall.length > 0;

    // ---- generate the extern(C) methods via a string mixin ----------

    private enum string eqBody =
        "    T* a = " ~ name ~ "_get(self);" ~
        "    if (!rb_typeddata_is_kind_of(other, &" ~ name ~ "_type))" ~
        "        return Qfalse_;" ~
        "    T* b = " ~ name ~ "_get(other);" ~
        staticIf!(hasEquals,
            eqCall,
            "    return to_ruby_value(rudy_bytes_eq(a, b, T.sizeof));");

    private enum string hashBody =
        "    T* p = " ~ name ~ "_get(self);" ~
        staticIf!(hasHash,
            hashCall,
            "    return to_ruby_value(rudy_fnv1a(p, T.sizeof) & rudy_hash_mask);");

    // inspect: generated ONLY with a hook (else Ruby's default stands).
    private static if (hasInspect)
        private enum string inspectFn =
            "extern (C) VALUE " ~ name ~ "_proto_inspect(VALUE self)" ~
            "{" ~
            "    T* p = " ~ name ~ "_get(self);" ~
            inspCall ~
            "    VALUE out_ = rb_str_new_cstr(\"#<\");" ~
            "    VALUE klass = rb_obj_class(self);" ~
            "    const(char)* cn = rb_class2name(klass);" ~
            "    size_t cnlen = 0; while (cn[cnlen]) cnlen++;" ~
            "    rb_str_cat(out_, cn, cast(long) cnlen);" ~
            "    rb_str_cat(out_, \": \", 2);" ~
            "    rb_str_cat(out_, inner.ptr, cast(long) inner.length);" ~
            "    rb_str_cat(out_, \">\", 1);" ~
            "    return out_;" ~
            "}";
    else
        private enum string inspectFn = "";

    private static if (hasInspect)
        private enum string inspectDef =
            "    rb_define_method(klass, \"inspect\", cast(AnyMethod) &" ~
                    name ~ "_proto_inspect, 0);";
    else
        private enum string inspectDef = "";

    // ---- install(): defines everything on the class ------------------
    //
    // allocate: zalloc zeroes T INSIDE Ruby's GC heap (prototype
    // confirmed against the 4.0.7 headers: (klass, size_t size, type)).
    // The 2010-era binding dropped the size argument and silently worked
    // through register reuse on x86-64 (finding #21) — T.sizeof is now
    // passed correctly.

    mixin(
        "extern (C) VALUE " ~ name ~ "_proto_alloc(VALUE klass)" ~
        "{" ~
        "    return cast(VALUE) rb_data_typed_object_zalloc(klass, T.sizeof, &" ~
                name ~ "_type);" ~
        "}" ~

        "extern (C) VALUE " ~ name ~ "_proto_icopy(VALUE self, VALUE orig)" ~
        "{" ~
        "    T* d = " ~ name ~ "_get(self);" ~
        "    T* s = " ~ name ~ "_get(orig);" ~
        "    *d = *s;" ~
        copyCall ~
        "    return self;" ~
        "}" ~

        "extern (C) VALUE " ~ name ~ "_proto_eq(VALUE self, VALUE other)" ~
        "{" ~
        eqBody ~
        "}" ~

        "extern (C) VALUE " ~ name ~ "_proto_hash(VALUE self)" ~
        "{" ~
        hashBody ~
        "}" ~

        inspectFn ~

        "public void " ~ name ~ "_proto_install(VALUE klass)" ~
        "{" ~
        "    rb_define_alloc_func(klass, cast(VALUE function(VALUE)) &" ~
                name ~ "_proto_alloc);" ~
        "    rb_define_private_method(klass, \"initialize_copy\"," ~
                " cast(AnyMethod) &" ~ name ~ "_proto_icopy, 1);" ~
        "    rb_define_method(klass, \"==\", cast(AnyMethod) &" ~
                name ~ "_proto_eq, 1);" ~
        "    rb_define_alias(klass, \"eql?\", \"==\");" ~
        "    rb_define_method(klass, \"hash\", cast(AnyMethod) &" ~
                name ~ "_proto_hash, 0);" ~
        inspectDef ~
        "}"
    );
}
