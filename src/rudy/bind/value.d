/// Hand-written binding to the Ruby C API (Ruby 3.x / 4.x).
///
/// Design notes:
/// - `VALUE` is `uintptr_t` on modern 64-bit CRuby. We never touch RBasic
///   or any R* struct layout: all access goes through exported functions
///   (rb_float_value, rb_ary_entry, rb_string_value_ptr, ...), the way the
///   Ruby project intends binary extensions to work post-1.9.
/// - Global variables (rb_cObject, rb_eArgError, ...) are BSS data symbols;
///   bound with `extern(C) extern __gshared`.
/// - `C_long` aliases mirror the old RuDy/PyD trick so the same templates
///   work on 32/64-bit.

module rudy.bind.value;

extern (C):

// ---------------------------------------------------------------- core types

alias ulong VALUE;                  /// Ruby object reference (uintptr_t, tagged)
alias long  SIGNED_VALUE;           /// intptr_t

// special constants (values are tag bits, identical on all modern rubies)
enum VALUE Qnil_    = cast(VALUE)0x04;   // RUBY_Qnil
enum VALUE Qtrue_    = cast(VALUE)0x14;   // RUBY_Qtrue
enum VALUE Qfalse_   = cast(VALUE)0x00;  // RUBY_Qfalse
enum VALUE Qundef_   = cast(VALUE)0x24;   // RUBY_Qundef (internal)

// Fixed-arity method callback shapes. For a fixed arity N, Ruby calls the
// C function as `VALUE f(VALUE self, VALUE a1, .., VALUE aN)`; the
// variadic (argc/argv) style is only used when the registered arity is < 0.
// rudy's def! always registers fixed arity, so trampolines below use these.
alias VALUE function(VALUE self) AnyMethod_0;
alias VALUE function(VALUE self, VALUE a1) AnyMethod_1;
alias VALUE function(VALUE self, VALUE a1, VALUE a2) AnyMethod_2;
alias VALUE function(VALUE self, VALUE a1, VALUE a2, VALUE a3) AnyMethod_3;
alias void* AnyMethod;               // what rb_define_method actually takes

/// Callback shape for rb_protect: `VALUE (*protected)(VALUE data)`
alias VALUE function(VALUE) ProtectFn;

// ---------------------------------------------------------------- API fns

// ---- definitions ---------------------------------------------------------

VALUE rb_define_class(const(char)* name, VALUE superclass);
VALUE rb_define_module(const(char)* name);
VALUE rb_define_class_under(VALUE outer, const(char)* name, VALUE superclass);
VALUE rb_define_module_under(VALUE outer, const(char)* name);
void  rb_extend_object(VALUE mod);
void  rb_define_method(VALUE klass, const(char)* name, AnyMethod func, int argc);
void  rb_define_module_function(VALUE mod, const(char)* name, AnyMethod func, int argc);
void  rb_define_global_function(const(char)* name, AnyMethod func, int argc);
void  rb_define_alloc_func(VALUE klass, VALUE function(VALUE) alloc);
void  rb_define_alias(VALUE klass, const(char)* alt, const(char)* old);
void  rb_include_module(VALUE klass, VALUE mod);
void  rb_define_attr(VALUE klass, const(char)* name, int read, int write);
void  rb_define_const(VALUE klass, const(char)* name, VALUE value);
void  rb_define_class_variable(VALUE klass, const(char)* name, VALUE value);

ID    rb_intern(const(char)* name);
alias long ID;

// ---- calling / conversions ------------------------------------------------

VALUE rb_funcall(VALUE recv, ID mid, int argc, ...);
VALUE rb_funcallv(VALUE recv, ID mid, int argc, const(VALUE)* argv);
VALUE rb_funcallv_public(VALUE recv, ID mid, int argc, const(VALUE)* argv);
// call mid with argv and a Proc/block (use for methods taking a block:
// sort, each, map...) — NOT passable as a positional arg via rb_funcallv
VALUE rb_funcall_with_block(VALUE recv, ID mid, int argc, const(VALUE)* argv, VALUE proc);
VALUE rb_obj_call_init(VALUE obj, int argc, const(VALUE)* argv);
VALUE rb_eval_string(const(char)* str);
VALUE rb_obj_alloc(VALUE klass);

// numbers
long  rb_num2long(VALUE);
long  rb_num2ll(VALUE);
double rb_num2dbl(VALUE);
VALUE rb_ull2inum(C_ulonglong);
VALUE rb_uint2inum(C_ulong);
ulong rb_num2ulong(VALUE);
VALUE rb_ll2inum(long);
int   rb_num2int(VALUE);    // raises RangeError outside int range
uint  rb_num2uint(VALUE);    // raises RangeError outside uint range
VALUE rb_int2inum(C_long);   // C ABI: intptr_t — was misbound as int (torture
                              // finding #4: wrong width silently truncates on
                              // SysV x86-64 because of register reuse)
VALUE rb_float_new(double);
double rb_float_value(VALUE);
VALUE rb_obj_is_instance_of(VALUE, VALUE);   // exported; rb_type is macro-only
VALUE rb_Integer(VALUE);

// strings
VALUE rb_str_new(const(char)* ptr, long len);
VALUE rb_str_new_cstr(const(char)* ptr);
VALUE rb_str_dup(VALUE);
void  rb_str_modify(VALUE);
VALUE rb_str_cat(VALUE str, const(char)* ptr, long len);
VALUE rb_str_buf_cat(VALUE str, const(char)* ptr, long len);
VALUE rb_string_value(VALUE* value);
/// Correct signature: takes a pointer to the slot (may replace its
/// contents, hence volatile). See rstring.h:289.
char* rb_string_value_ptr(VALUE* ptr);
const(char)* rb_string_value_cstr(VALUE str);
long  rb_str_strlen(VALUE);
VALUE rb_str_to_str(VALUE str);
VALUE rb_obj_as_string(VALUE obj);
VALUE rb_any_to_s(VALUE obj);

// arrays
VALUE rb_ary_new();
VALUE rb_ary_new_capa(C_long capa);
VALUE rb_ary_new_from_values(C_long n, const(VALUE)* vals);
VALUE rb_ary_push(VALUE ary, VALUE item);
VALUE rb_ary_entry(VALUE ary, long offset);
VALUE rb_ary_store(VALUE ary, long idx, VALUE item);
VALUE rb_ary_join(VALUE ary, VALUE sep);
VALUE rb_ary_to_s(VALUE ary);
VALUE rb_obj_class(VALUE obj);

// hashes
VALUE rb_hash_new();
VALUE rb_hash_lookup2(VALUE hash, VALUE key, VALUE def);  // no Hash#default raise
VALUE rb_hash_aset(VALUE hash, VALUE key, VALUE val);
VALUE rb_hash_aref(VALUE hash, VALUE key);
size_t rb_hash_size(VALUE hash);

// ivars / constants
VALUE rb_iv_get(VALUE obj, const(char)* name);
VALUE rb_iv_set(VALUE obj, const(char)* name, VALUE value);
VALUE rb_const_get(VALUE klass, ID name);
void  rb_const_set(VALUE klass, ID name, VALUE value);

// equality / inspection
VALUE rb_equal(VALUE a, VALUE b);
VALUE rb_obj_id(VALUE obj);
VALUE rb_inspect(VALUE obj);
VALUE rb_id2sym(ID);
VALUE rb_sym2str(VALUE sym);
const(char)* rb_id2name(ID);
VALUE rb_obj_frozen_p(VALUE obj);

// exceptions / control flow
// (rb_raise/rb_fatal never return; D has no `noreturn` attribute for extern(C))
void rb_raise(VALUE exc, const(char)* fmt, ...);
void rb_fatal(const(char)* fmt, ...);
void rb_throw(const(char)* tag, VALUE val);
void rb_throw_obj(VALUE tag, VALUE val);
void rb_exit(int status);
VALUE rb_protect(ProtectFn fn, VALUE data, int* state);
// Re-raise an existing exception object (the only way to re-raise the SAME
// exception VALUE from D — rb_raise formats a NEW exception). noreturn.
void  rb_exc_raise(VALUE exc);
// After a rb_protect state != 0 (or rb_rescue/rb_ensure rescue path), the
// pending exception is fetched via rb_errinfo. Without binding it D cannot
// inspect what Ruby raised while crossing the boundary.
VALUE rb_errinfo();
void  rb_set_errinfo(VALUE err);
// int rb_check_arity(int argc, int min, int max); -- inline-only in ruby/internal/intern/error.h, NOT exported; keep out of bindings

// GC
void  rb_gc_register_address(VALUE* address);
void  rb_gc_unregister_address(VALUE* address);
VALUE rb_gc_location(VALUE);   // remap a VALUE after GC.compact moved it
void  rb_gc_mark(VALUE);        // conservative mark (no compaction update)
void  rb_gc_mark_movable(VALUE); // mark + this slot is updated via rb_gc_location in dcompact
VALUE rb_gc_enable();
VALUE rb_gc_disable();

// introspection
int   rb_check_funcall(VALUE recv, ID mid, int argc, const(VALUE)* argv);
int   rb_respond_to(VALUE obj, ID mid);

// blocks / iteration (bound for PR#4 — issue #4)
// rb_block_call_func signature (ruby/internal/iterator.h):
//   VALUE f(VALUE yielded_arg, VALUE callback_arg, int argc,
//           const VALUE* argv, VALUE blockarg)
alias VALUE function(VALUE yielded_arg, VALUE callback_arg, int argc,
                      const(VALUE)* argv, VALUE blockarg) BlockCallFunc;
alias VALUE function(VALUE data) BodyFunc;              // rb_rescue/rb_ensure b_proc
alias VALUE function(VALUE data2, VALUE exc) RescueFunc; // rb_rescue r_proc
VALUE rb_yield(VALUE val);
VALUE rb_yield_values(int n, ...);
VALUE rb_yield_values2(int n, const(VALUE)* argv);
VALUE rb_yield_splat(VALUE ary);
VALUE rb_yield_block(VALUE yielded_arg, VALUE callback_arg, int argc,
                     const(VALUE)* argv, VALUE blockarg); // as rb_block_call_func
VALUE rb_block_call(VALUE obj, ID mid, int argc, const(VALUE)* argv,
                    BlockCallFunc proc, VALUE data2);
int   rb_block_given_p();
VALUE rb_block_proc();        // materialize the passed block as a Proc VALUE
VALUE rb_each(VALUE obj);

// structured exception handling from D (only rb_protect was bound before)
VALUE rb_rescue(BodyFunc b_proc, VALUE data1, RescueFunc r_proc, VALUE data2);
// rb_rescue2: variadic list of exception classes terminated by (VALUE)0.
// D has no C varargs forwarding — bind rb_vrescue2 (takes va_list) is not
// portable either; the common single-class case can use rb_rescue. For
// multiple classes call with the variadic ABI is NOT provided; use
// rb_protect + rb_respond_to rescue semantics at Ruby level instead.
// (Kept out deliberately: calling variadic C from D is not possible.)
VALUE rb_ensure(BodyFunc b_proc, VALUE data1, BodyFunc e_proc, VALUE data2);

// per-object methods
void  rb_define_singleton_method(VALUE obj, const(char)* mid, AnyMethod func, int arity);
void  rb_define_private_method(VALUE klass, const(char)* mid, AnyMethod func, int arity);
void  rb_define_protected_method(VALUE klass, const(char)* mid, AnyMethod func, int arity);

// GVL (Ruby threading interop)
alias void  function(void*) UnblockFunc;    // rb_unblock_function_t
alias void* function(void*) NoGvlFunc;     // func passed to *_without_gvl
void* rb_thread_call_without_gvl(NoGvlFunc func, void* data1,
                                 UnblockFunc ubf, void* data2);
void* rb_thread_call_without_gvl2(NoGvlFunc func, void* data1,
                                  UnblockFunc ubf, void* data2);
void* rb_thread_call_with_gvl(NoGvlFunc func, void* data1);
enum void* RUBY_UBF_IO = cast(void*) -1;    // special UBF for blocking IO

// argument scanning (the C variadic stores into VALUE* slots)
int   rb_scan_args(int argc, const(VALUE)* argv, const(char)* fmt, ...);

// struct wrapping (minimal; not used by core rudy)
alias void function(void* ptr) RUBY_DATA_FUNC_MARK;
alias void function(void* ptr) RUBY_DATA_FUNC_FREE;
VALUE rb_data_object_wrap(VALUE klass, void* ptr,
                          RUBY_DATA_FUNC_MARK mark, RUBY_DATA_FUNC_FREE free);
// void* rb_data_object_get(VALUE obj); -- inline-only in ruby/internal/core/rdata.h, NOT exported (use typeddata helper)

// typed-data (rb_data_object_get is an inline macro; these are real
// exported functions — see rudy/typeddata.d for a D-friendly helper)
// NOTE: RbDataType (rb_data_type_t) is defined in rudy/typeddata.d to keep
// this raw binding free of struct definitions; cast accordingly.
alias size_t function(const void*) RUBY_DATA_FUNC_DSIZE;
VALUE rb_data_typed_object_wrap(VALUE klass, void* ptr, in void* data_type);
void* rb_check_typeddata(VALUE obj, in void* data_type);
void* rb_data_typed_object_zalloc(VALUE klass, in void* data_type);

// ---------------------------------------------------------------- globals

extern __gshared VALUE rb_cObject;
extern __gshared VALUE rb_cInteger;
extern __gshared VALUE rb_cFloat;
extern __gshared VALUE rb_cString;
extern __gshared VALUE rb_cArray;
extern __gshared VALUE rb_cHash;
extern __gshared VALUE rb_mKernel;

extern __gshared VALUE rb_eException;
extern __gshared VALUE rb_eStandardError;
extern __gshared VALUE rb_eRuntimeError;
extern __gshared VALUE rb_eTypeError;
extern __gshared VALUE rb_eArgError;
extern __gshared VALUE rb_eRangeError;
extern __gshared VALUE rb_eNameError;
extern __gshared VALUE rb_eNoMethodError;
extern __gshared VALUE rb_eNotImpError;
extern __gshared VALUE rb_eStopIteration;
extern __gshared VALUE rb_eKeyError;
extern __gshared VALUE rb_eIndexError;
extern __gshared VALUE rb_eLoadError;
extern __gshared VALUE rb_eSystemExit;
extern __gshared VALUE rb_eSysStackError;    // Ruby 4 exports rb_eSysStackError (rb_eSystemStackError never existed)
extern __gshared VALUE rb_eZeroDivError;
extern __gshared VALUE rb_eLocalJumpError;   // yield with no block / blk.call when none given

// type tags (ruby_value_type) — subset rudy needs
enum int RUBY_T_NONE    = 0x00;
enum int RUBY_T_OBJECT  = 0x01;
enum int RUBY_T_CLASS   = 0x02;
enum int RUBY_T_MODULE  = 0x03;
enum int RUBY_T_FLOAT   = 0x0b;
enum int RUBY_T_STRING  = 0x0d;
enum int RUBY_T_SYMBOL  = 0x0f;
enum int RUBY_T_ARRAY   = 0x11;
enum int RUBY_T_HASH    = 0x13;
enum int RUBY_T_TRUE    = 0x20;
enum int RUBY_T_FALSE   = 0x21;
enum int RUBY_T_NIL     = 0x22;
enum int RUBY_T_DATA    = 0x26;
enum int RUBY_T_COMPLEX = 0x2a;

// C `long` on this platform (LP64 = 64 bits). Keeps to_ruby_value/d_type
// templates portable to 32-bit builds.
version (X86_64) {
    alias long C_long;
    alias ulong C_ulong;
} else version (X86) {
    alias int C_long;
    alias uint C_ulong;
} else {
    alias long C_long;
    alias ulong C_ulong;
}
alias long C_longlong;
alias ulong C_ulonglong;


