/// Parameter wrappers for `def!` (rudy/defs.d) that reach past the
/// plain positional-argument model. The 2010 RuDy had none of these;
/// a `def!`'d function could neither receive the caller's block nor
/// take rest/keyword arguments.
///
///     void with_block(RubyBlock blk)   { blk.call(42); }  // receives the
///                                                         // caller's block
///     long rest_sum(long first, Rest rest) { ... }        // 1 + *rest
///     D str_kw(KwArgs kw) { kw.get!string("sep", "-") }   // **kwargs
///
/// All wrappers are VALUE-sized (passable as fixed-arity C args); the
/// interesting VALUE lives inside (block proc, rest array, kwargs
/// hash). See defs.d for how the trampolines populate them.

module rudy.args;

import rudy.bind.value;
import rudy.convert;
import std.string : toStringz;

// lazily-interned method names (rb_intern on every call is a symbol-table
// hash probe; the VM is alive inside any method call, so lazy init is safe)
private __gshared ID rudy_id_call;
private __gshared ID rudy_id_arity;
private __gshared ID rudy_id_length;
private __gshared ID rudy_id_to_a;
private __gshared ID rudy_id_to_s;

private ID id_call()   { if (!rudy_id_call)   rudy_id_call   = rb_intern("call");   return rudy_id_call;   }
private ID id_arity()  { if (!rudy_id_arity)  rudy_id_arity  = rb_intern("arity");  return rudy_id_arity;  }
private ID id_length() { if (!rudy_id_length) rudy_id_length = rb_intern("length"); return rudy_id_length; }
private ID id_to_a()   { if (!rudy_id_to_a)   rudy_id_to_a   = rb_intern("to_a");   return rudy_id_to_a;   }
private ID id_to_s()   { if (!rudy_id_to_s)   rudy_id_to_s   = rb_intern("to_s");   return rudy_id_to_s;   }

// ---------------------------------------------------------------- RubyBlock

/// A caller's block, materialized as a Proc. `def!` fills it in via
/// rb_scan_args' "&" slot inside the trampoline (Qnil when no block was
/// passed), before the D function runs.
///
///   blk.call(args...)   — invoke the block
///   blk.arity           — the Proc's arity
///   blk.given           — was a block actually passed?
///
/// A block-less method raises LocalJumpError from Ruby the moment
/// call() runs — same failure mode as bare `yield` in Ruby. Check
/// `given` first when that must not happen.
struct RubyBlock
{
    VALUE proc = Qnil_;

    /// Was a block actually passed to this method?
    bool given() const @safe pure nothrow @nogc { return proc != Qnil_; }

    /// The wrapped Proc, as raw VALUE (for API-passing scenarios).
    Raw!VALUE raw() const @safe pure nothrow @nogc { return Raw!VALUE(proc); }

    /// Number of arguments the block expects (Proc#arity).
    long arity() { return d_type!long(rb_funcallv(proc, id_arity(), 0, null)); }

    /// Call the block with args; returns whatever the block returned.
    /// LocalJumpError (from Ruby) if called with no block given; any
    /// exception the block raises propagates straight through the D frame.
    VALUE call() { return lje_or_call(proc, 0, null); }

    VALUE call(VALUE a1)
    {
        VALUE[1] av = [a1];
        return lje_or_call(proc, 1, av.ptr);
    }

    VALUE call(VALUE a1, VALUE a2)
    {
        VALUE[2] av = [a1, a2];
        return lje_or_call(proc, 2, av.ptr);
    }

    VALUE call(VALUE a1, VALUE a2, VALUE a3)
    {
        VALUE[3] av = [a1, a2, a3];
        return lje_or_call(proc, 3, av.ptr);
    }

    /// Call with a pre-built argv (n args).
    VALUE callv(int n, const(VALUE)* argv)
    {
        return lje_or_call(proc, n, cast(VALUE*) argv);
    }
}

/// RubyBlock#call contract helper: a block-less call is the same error
/// a bare `yield` with no block would give (rb_funcallv on Qnil would
/// give a misleading NoMethodError instead).
private VALUE lje_or_call(VALUE proc, int n, VALUE* argv)
{
    if (proc == Qnil_)
        rb_raise(rb_eLocalJumpError, "no block given (yield)");
    return rb_funcallv(proc, id_call(), n, argv);
}

// ---------------------------------------------------------------- Self

/// The method's receiver (self), passed through raw. First-parameter
/// convention; lets def!'d functions inspect the object they were
/// called on (class, ivars, singleton-ness) without dropping to a
/// hand-written trampoline.
///
///   long klass_name(Self self) { ... rb_obj_class(self.v) ... }
struct Self
{
    VALUE v = Qnil_;

    /// The receiver as raw VALUE.
    Raw!VALUE raw() const @safe pure nothrow @nogc { return Raw!VALUE(v); }

    /// implicit conversion so `self.v` and passing Self around stays terse
    VALUE value() const @safe pure nothrow @nogc { return v; }
}

// ---------------------------------------------------------------- Rest

/// Captured `*rest` arguments, as a Ruby Array. The trampoline owns the
/// VALUE (GC-rooted for the call's duration); the D function sees this
/// slice-style wrapper.
struct Rest
{
    VALUE ary = Qnil_;

    /// Number of captured rest arguments (0 for an unused slot).
    @property size_t length() const
    {
        if (ary == Qnil_)
            return 0;
        return cast(size_t) d_type!long(rb_funcallv(ary, id_length(), 0, null));
    }

    /// True when nothing was captured. NB: rb_scan_args' "*" slot fills
    /// an EMPTY ARRAY (not Qnil) when the caller passes zero rest args —
    /// this must agree with Ruby-side `rest.empty?`, so it checks the
    /// length, not just the slot's Qnil-ness.
    bool empty() { return length == 0; }

    /// i-th captured argument (0-based).
    VALUE opIndex(size_t i)
    {
        return rb_ary_entry(ary, cast(long) i);
    }

    /// Iterate the captured arguments (foreach over a Rest works).
    int opApply(scope int delegate(ref VALUE) dg)
    {
        long n = cast(long) length;
        foreach (i; 0 .. n)
        {
            VALUE v = rb_ary_entry(ary, i);
            int r = dg(v);
            if (r)
                return r;
        }
        return 0;
    }

    /// The raw Ruby Array, as raw VALUE.
    Raw!VALUE raw() const @safe pure nothrow @nogc { return Raw!VALUE(ary); }

    /// Convert every captured arg to D type T (allocates a D array).
    T[] to(T)()
    {
        long n = cast(long) length;
        T[] outv;
        outv.length = cast(size_t) n;
        foreach (i; 0 .. n)
            outv[cast(size_t) i] = d_type!T(rb_ary_entry(ary, i));
        return outv;
    }
}

// ---------------------------------------------------------------- KwArgs

/// Captured keyword arguments, as a Ruby Hash. `def!` fills it via
/// rb_scan_args' `:` slot (Qnil_ when no keywords were passed — see
/// `given`).
///
///   kw.get!long("sep", 1)     — decoded with a D default when absent
///   kw["sep"]                 — raw VALUE (Qnil_ when absent)
///   kw.to!(long, string)()    — whole hash as a D AA
struct KwArgs
{
    VALUE hash = Qnil_;

    /// Were any keywords passed?
    bool given() const @safe pure nothrow @nogc { return hash != Qnil_; }

    /// Raw value of keyword `key` (Qnil_ when absent). Ruby keyword keys
    /// are Symbols (`m(sep: x)`), but string keys are legal too
    /// (`m("sep": x)` / string-keyed **hash) — probe both.
    VALUE opIndex(string key)
    {
        if (!given)
            return Qnil_;
        ID id = rb_intern(toStringz(key));
        VALUE v = rb_hash_lookup2(hash, rb_id2sym(id), Qnil_);
        if (v != Qnil_)
            return v;
        VALUE[1] av = [rb_str_new(key.ptr, cast(C_long) key.length)];
        return rb_hash_lookup2(hash, av[0], Qnil_);
    }

    /// Keyword decoded to D type T; `dflt` when the keyword was absent.
    T get(T)(string key, T dflt)
    {
        VALUE v = opIndex(key);
        if (v == Qnil_ || v == Qundef_)
            return dflt;
        return d_type!T(v);
    }

    /// All keywords as a D associative array (empty when none passed).
    V[K] to(V, K)()
    {
        V[K] outv;
        if (!given)
            return outv;
        // Hash#to_a -> [[k, v], ...]: plain exported-API walking, no
        // callbacks (rb_block_call's return value can't accumulate).
        VALUE pairs = rb_funcallv(hash, id_to_a(), 0, null);
        long n = d_type!long(rb_funcallv(pairs, id_length(), 0, null));
        foreach (i; 0 .. n)
        {
            VALUE pair = rb_ary_entry(pairs, i);
            VALUE k = rb_ary_entry(pair, 0);
            static if (is(K == string))
            {
                // kwargs keys are normally Symbols; d_type!string of a
                // Symbol raises TypeError. Normalize through to_s
                // (Symbol#to_s -> name String, String#to_s -> self) so
                // string-keyed D AAs see every key. Non-string K keys
                // go through d_type directly.
                k = rb_funcallv(k, id_to_s(), 0, null);
            }
            static if (is(V == Raw!VALUE))
            {
                // raw VALUE escape hatch: bits unchanged, no decode
                outv[d_type!K(k)] = Raw!VALUE(rb_ary_entry(pair, 1));
            }
            else
            {
                outv[d_type!K(k)] = d_type!V(rb_ary_entry(pair, 1));
            }
        }
        return outv;
    }
}
