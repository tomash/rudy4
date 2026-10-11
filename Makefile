# RuDy — Ruby native extensions in D (2026 revival)
#
# Toolchain: gdc-14 (GCC 14.2), Ruby 4.0 via asdf on this machine.
# Override on the command line if your setup differs:
#   make RUBY=~/.asdf/installs/ruby/4.0.7/bin/ruby GDC=gdc

RUBY  ?= $(HOME)/.asdf/installs/ruby/4.0.7/bin/ruby
GDC   ?= gdc-14

RUBYHDR     := $(shell $(RUBY) -e 'print RbConfig::CONFIG["rubyhdrdir"]')
RUBYARCHHDR := $(shell $(RUBY) -e 'print RbConfig::CONFIG["rubyarchhdrdir"]')
LIBRUBYARG  := $(shell $(RUBY) -e 'print RbConfig::CONFIG["LIBRUBYARG_SHARED"]')
LIBRUBY_DIR := $(shell $(RUBY) -e 'print RbConfig::CONFIG["libdir"]')

DFLAGS := -fPIC -Isrc -I$(RUBYHDR) -I$(RUBYARCHHDR) \
          -fpreview=dip1008 \
          -Wno-deprecated

DC_SRCS := $(wildcard src/rudy/*.d src/rudy/bind/*.d)

EXP_SRCS := exp_wrap exp_cross exp_perf exp_http exp_gcstorm exp_exc exp_compact

.PHONY: all clean test check typed-test exp exp-test

all: .build/dextest.so .build/dexitest.so .build/dtypetest.so

# One shared object: the rudy library modules + the extension entry point.
.build/dextest.so: $(DC_SRCS) src/dextest.d | .build
	$(GDC) -shared -o $@ $(DFLAGS) $(DC_SRCS) src/dextest.d \
	  -L$(LIBRUBY_DIR) $(LIBRUBYARG) -lm

# Missing-API bindings extension: yield/rescue/ensure/singleton/scan_args/
# GVL bindings + variadic def! (D default args -> Ruby optional args).
.build/dexitest.so: $(DC_SRCS) src/dexitest.d | .build
	$(GDC) -shared -o $@ $(DFLAGS) $(DC_SRCS) src/dexitest.d \
	  -L$(LIBRUBY_DIR) $(LIBRUBYARG) -lm

# TypedData extension: rudy library + typeddata helper + dtypetest entry point.
.build/dtypetest.so: $(DC_SRCS) src/dtypetest.d | .build
	$(GDC) -shared -o $@ $(DFLAGS) $(DC_SRCS) src/dtypetest.d \
	  -L$(LIBRUBY_DIR) $(LIBRUBYARG) -lm

.build:
	mkdir -p .build

# Experiments: each experiment .d becomes its own .so
.build/exp_%.so: experiments/exp_%.d $(DC_SRCS) | .build
	$(GDC) -shared -o $@ $(DFLAGS) $(DC_SRCS) $< \
	  -L$(LIBRUBY_DIR) $(LIBRUBYARG) -lm

exp: $(addprefix .build/,$(EXP_SRCS:=.so))

exp-test: exp
	$(RUBY) experiments/test_exp_wrap.rb
	$(RUBY) experiments/test_exp_cross.rb
	$(RUBY) experiments/test_exp_perf.rb
	$(RUBY) experiments/test_exp_http.rb
	$(RUBY) experiments/test_exp_gcstorm.rb
	$(RUBY) experiments/test_exp_exc.rb
	$(RUBY) experiments/test_exp_compact.rb

# Ruby-side acceptance suite (dexter revival + missing-API bindings)
test: all
	$(RUBY) test/run.rb
	$(RUBY) test/exitest.rb
	$(RUBY) test/typedtest.rb

check: test

clean:
	rm -rf .build
