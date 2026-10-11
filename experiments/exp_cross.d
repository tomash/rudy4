/// EXPERIMENT 2 — Two-way boundary crossing in a single call.
///
/// Torture elements:
/// - D calls *back into Ruby* (rb_funcallv) mid-computation (sort block,
///   custom to_s)
/// - rb_protect around Ruby callbacks that raise
/// - nested data structures built in D, consumed in Ruby
/// - variadic-shape method (argc/argv) via a variadic D function passed
///   to rb_define_method with arity -1 — uses raw C varargs shim
///
/// We have to hand-roll the varargs trampoline (D variadic != C varargs),
/// so this also tests how far we can get without library support for
/// variable arity.

module exp_cross;

import rudy.bind.value;
import rudy.convert;
import rudy.defs;
import std.string : toStringz;

private:

// ---- D calls a Ruby block for comparison ------------------------------
// (block invocation happens via rb_funcallv on a registered Proc in
// cross_sort_protected; kept for reference)

alias VALUE function(VALUE, VALUE) BlockFn;

extern (C) VALUE cross_sort_protected(VALUE data)
{
    // data is the ExpCross module; @ary and @blk are set from Ruby
    VALUE ary = rb_iv_get(data, "@ary");
    VALUE blk = rb_iv_get(data, "@blk");
    // sort takes a BLOCK, not a positional arg: rb_funcallv(sort, 1, blk)
    // raises ArgumentError. rb_funcall_with_block passes blk as the block.
    return rb_funcall_with_block(ary, rb_intern("sort"), 0, null, blk);
}

extern (C) VALUE cross_sort(VALUE self)
{
    VALUE mod = rb_const_get(rb_cObject, rb_intern("ExpCross"));
    int state;
    VALUE res = rb_protect(&cross_sort_protected, mod, &state);
    if (state)
    {
        rudy_raise(rb_eRuntimeError, "Ruby block raised inside D sort");
        return Qnil_;
    }
    return res;
}

// register_block(holder) — remember block holder for later cross_sort
extern (C) VALUE cross_register(VALUE self, VALUE blk)
{
    VALUE mod = rb_const_get(rb_cObject, rb_intern("ExpCross"));
    rb_iv_set(mod, "@blk", blk);
    return blk;
}

// register_ary(ary) — the array cross_sort will sort
extern (C) VALUE cross_register_ary(VALUE self, VALUE ary)
{
    VALUE mod = rb_const_get(rb_cObject, rb_intern("ExpCross"));
    rb_iv_set(mod, "@ary", ary);
    return ary;
}

// ---- nested structure built in D, deep-equal from Ruby -----------------

struct Point { double x, y; }

Point[] polygon = [ Point(0, 0), Point(1, 0), Point(1, 1), Point(0, 1) ];

// Sum via a Ruby-supplied callable (Proc): fold(map)
extern (C) VALUE cross_polygon_area(VALUE self)
{
    // call Ruby: points.inject(0) { |acc, (x, y)| acc + x*y } — do it via
    // eval'd literal from D to prove full eval round-trip works
    VALUE mod = rb_const_get(rb_cObject, rb_intern("ExpCross"));
    VALUE pts = rb_iv_get(mod, "@pts");
    if (pts == Qnil_)
    {
        // build [[x, y], ...] in D
        pts = rb_ary_new_capa(cast(C_long) polygon.length);
        foreach (ref p; polygon)
        {
            VALUE pair = rb_ary_new_capa(2);
            rb_ary_push(pair, to_ruby_value(p.x));
            rb_ary_push(pair, to_ruby_value(p.y));
            rb_ary_push(pts, pair);
        }
        rb_iv_set(mod, "@pts", pts);
    }
    // eval inside module context so the bare `pts` local resolves — use a
    // funcall on the module instead (eval with binding is not bound here)
    VALUE[1] av = [pts];
    VALUE code = rb_funcallv(mod, rb_intern("shoelace"), 1, av.ptr);
    return code;
}

// ---- variable arity: sum any number of arguments ----------------------
// D can't receive C varargs directly; use a fixed max and forward.

extern (C) VALUE cross_sum(VALUE self, VALUE a1, VALUE a2, VALUE a3)
{
    // registered with fixed arity 3; Ruby fills unsupplied slots with
    // Qnil_ only when arity is negative. With fixed arity this method
    // requires exactly 3 args — see experiments/NOTES.md: variable arity
    // needs an argc/argv trampoline that rudy does not yet generate.
    VALUE[3] av = [a1, a2, a3];
    double total = 0.0; // bare `double total;` is NaN in D!
    foreach (v; av)
        total += d_type!double(v);
    return to_ruby_value(total);
}

// ---- raise from deep inside D recursion -------------------------------

extern (C) VALUE cross_raise(VALUE self, VALUE depth)
{
    return to_ruby_value(cross_raise_rec(d_type!long(depth)));
}

long cross_raise_rec(long d)
{
    if (d == 0)
        rudy_raise(rb_eRangeError, "bottom reached, D unwinds");
    return cross_raise_rec(d - 1) + 1;
}

public:

pragma(mangle, "Init_exp_cross")
extern (C) void Init_exp_cross()
{
    VALUE m = rb_define_module("ExpCross");
    rb_define_module_function(m, "sort_with_block!", cast(AnyMethod) &cross_sort, 0);
    rb_define_module_function(m, "register_block",  cast(AnyMethod) &cross_register, 1);
    rb_define_module_function(m, "register_ary",   cast(AnyMethod) &cross_register_ary, 1);
    rb_define_module_function(m, "polygon_area",   cast(AnyMethod) &cross_polygon_area, 0);
    rb_define_module_function(m, "sum3",           cast(AnyMethod) &cross_sum, 3);
    rb_define_module_function(m, "raise_from_deep", cast(AnyMethod) &cross_raise, 1);
}