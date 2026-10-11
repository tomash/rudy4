/// dextest — revival of RuDy's old "dexter" playground, now the acceptance
/// test for rudy-d. Exercises def!, to_ruby_value and d_type with real
/// type conversions, plus a couple of raw C API calls.

module dextest;

import rudy.bind.value;
import rudy.convert;
import rudy.defs;

// ---------------------------------------------------------------------
// Raw C API class — dexter-style, no conversion sugar.
// ---------------------------------------------------------------------

extern(C) VALUE dextest_return_ten(VALUE self)
{
    return rb_int2inum(10);
}

extern(C) VALUE dextest_initialize(VALUE self)
{
    rb_iv_set(self, "@arr", rb_ary_new());
    return self;
}

extern(C) VALUE dextest_arr(VALUE self)
{
    return rb_iv_get(self, "@arr");
}

extern(C) VALUE dextest_add(VALUE self, VALUE obj)
{
    VALUE arr = rb_iv_get(self, "@arr");
    rb_ary_push(arr, obj);
    return arr;
}

extern(C) VALUE dextest_native_add(VALUE self, VALUE obj)
{
    VALUE arr = rb_iv_get(self, "@arr");
    VALUE val = rb_num2long(obj);
    rb_ary_push(arr, rb_ll2inum(val + 1));
    return arr;
}

extern(C) VALUE dextest_add_strings_first_letter(VALUE self, VALUE obj)
{
    VALUE str = rb_str_to_str(obj);
    VALUE letter = rb_str_new(rb_string_value_ptr(&str), 1);
    VALUE arr = rb_iv_get(self, "@arr");
    rb_ary_push(arr, letter);
    return letter;
}

// ---------------------------------------------------------------------
// def!'d functions — module scope so trampolines get real pointers.
// ---------------------------------------------------------------------

int the_new_fifteen()            { return 15; }

long convert_integer_two_ways(long n)    { return n; }
double convert_float_two_ways(double f)  { return f; }
string convert_string_two_ways(string s) { return s; }
bool convert_bool_two_ways(bool b)       { return b; }

long add_five(long n) { return n + 5; }

string greet(string name, int n)
{
    import std.conv;
    return "hi " ~ name ~ " " ~ n.to!string;
}

pragma(mangle, "Init_dextest")
extern(C) void Init_dextest()
{
    // ---- plain C API class ------------------------------------------

    VALUE DexterClass = rb_define_class("DexterClass", rb_cObject);

    rb_define_method(DexterClass, "return_ten",
                     cast(AnyMethod) &dextest_return_ten, 0);
    rb_define_method(DexterClass, "initialize",
                     cast(AnyMethod) &dextest_initialize, 0);
    rb_define_method(DexterClass, "arr",
                     cast(AnyMethod) &dextest_arr, 0);
    rb_define_method(DexterClass, "add",
                     cast(AnyMethod) &dextest_add, 1);
    rb_define_method(DexterClass, "native_add",
                     cast(AnyMethod) &dextest_native_add, 1);
    rb_define_method(DexterClass, "add_strings_first_letter",
                     cast(AnyMethod) &dextest_add_strings_first_letter, 1);

    // ---- def! with automatic conversions ----------------------------

    // global (Object level)
    def!(the_new_fifteen);
    def!(convert_integer_two_ways);
    def!(convert_float_two_ways);
    def!(convert_string_two_ways);
    def!(convert_bool_two_ways);
    def!(add_five);

    // module function
    VALUE DexterModule = rb_define_module("DexterModule");
    def!("DexterModule", greet);
}
