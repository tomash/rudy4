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

BUILD ?= .build
# ASan variant: `make ASAN=1 ...` or `make memcheck` builds into .build.asan
# with -fsanitize=address. Note (experiments/NOTES.md #23): druntime rt_init
# SEGVs under gdc-14 ASan, so only the rt_init-free experiments
# (wrap/cross/perf/exc/defargs/http) are meaningful this way.
ifeq ($(ASAN),1)
  BUILD := .build.asan
  DFLAGS += -fsanitize=address
endif

DFLAGS := -fPIC -Isrc -I$(RUBYHDR) -I$(RUBYARCHHDR) \
          -fpreview=dip1008 \
          -Wno-deprecated

DC_SRCS := $(wildcard src/rudy/*.d src/rudy/bind/*.d)

EXP_SRCS := exp_wrap exp_cross exp_perf exp_http exp_gcstorm exp_exc exp_compact exp_convert exp_defargs exp_objproto exp_nonregression

# rt_init-free subset that works under ASan (NOTES.md #23/#24).
ASAN_EXP_SRCS := exp_wrap exp_cross exp_perf exp_exc exp_defargs exp_http

.PHONY: all clean test check typed-test exp exp-test exp-asan exp-asan-test memcheck vendor vendor-check gem-test gem-test-full gem-build

all: $(BUILD)/dextest.so $(BUILD)/dexitest.so $(BUILD)/dtypetest.so

# One shared object: the rudy library modules + the extension entry point.
$(BUILD)/dextest.so: $(DC_SRCS) src/dextest.d | $(BUILD)
	$(GDC) -shared -o $@ $(DFLAGS) $(DC_SRCS) src/dextest.d \
	  -L$(LIBRUBY_DIR) $(LIBRUBYARG) -lm

# Missing-API bindings extension: yield/rescue/ensure/singleton/scan_args/
# GVL bindings + variadic def! (D default args -> Ruby optional args).
$(BUILD)/dexitest.so: $(DC_SRCS) src/dexitest.d | $(BUILD)
	$(GDC) -shared -o $@ $(DFLAGS) $(DC_SRCS) src/dexitest.d \
	  -L$(LIBRUBY_DIR) $(LIBRUBYARG) -lm

# TypedData extension: rudy library + typeddata helper + dtypetest entry point.
$(BUILD)/dtypetest.so: $(DC_SRCS) src/dtypetest.d | $(BUILD)
	$(GDC) -shared -o $@ $(DFLAGS) $(DC_SRCS) src/dtypetest.d \
	  -L$(LIBRUBY_DIR) $(LIBRUBYARG) -lm

$(BUILD):
	mkdir -p $(BUILD)

# Experiments: each experiment .d becomes its own .so
$(BUILD)/exp_%.so: experiments/exp_%.d $(DC_SRCS) | $(BUILD)
	$(GDC) -shared -o $@ $(DFLAGS) $(DC_SRCS) $< \
	  -L$(LIBRUBY_DIR) $(LIBRUBYARG) -lm

exp: $(addprefix $(BUILD)/,$(EXP_SRCS:=.so))

exp-test: exp
	$(RUBY) experiments/test_exp_wrap.rb
	$(RUBY) experiments/test_exp_cross.rb
	$(RUBY) experiments/test_exp_perf.rb
	$(RUBY) experiments/test_exp_http.rb
	$(RUBY) experiments/test_exp_gcstorm.rb
	$(RUBY) experiments/test_exp_exc.rb
	$(RUBY) experiments/test_exp_compact.rb
	$(RUBY) experiments/test_exp_convert.rb
	$(RUBY) experiments/test_exp_defargs.rb
	$(RUBY) experiments/test_exp_objproto.rb
	$(RUBY) experiments/test_exp_nonregression.rb

ASAN_PRELOAD := LD_PRELOAD=$(shell $(GDC) -print-file-name=libasan.so)
# detect_odr_violation=0: wrap/cross/perf .so's each embed a copy of the rudy
# library also present in dextest.so (loaded by the suite loader) — ASan would
# otherwise abort on the duplicate registered globals.
ASAN_OPTS := ASAN_OPTIONS=detect_leaks=0:halt_on_error=1:allocator_may_return_null=1:detect_odr_violation=0

# ASan subset of the experiment suites (NOTES.md #23/#24). Builds lib +
# dextest.so + the rt_init-free exp .so's into .build.asan, then runs the
# corresponding test files under ruby with LD_PRELOAD=libasan.so.
# http is built but NOT run (NOTES.md #24: munmap crash, under investigation).
exp-asan-test:
	$(MAKE) ASAN=1 --no-print-directory $(addprefix .build.asan/,$(ASAN_EXP_SRCS:=.so)) .build.asan/dextest.so
	$(ASAN_PRELOAD) $(ASAN_OPTS) RUDY_BUILD_DIR=.build.asan $(RUBY) experiments/test_exp_wrap.rb
	$(ASAN_PRELOAD) $(ASAN_OPTS) RUDY_BUILD_DIR=.build.asan $(RUBY) experiments/test_exp_cross.rb
	$(ASAN_PRELOAD) $(ASAN_OPTS) RUDY_BUILD_DIR=.build.asan $(RUBY) experiments/test_exp_perf.rb
	$(ASAN_PRELOAD) $(ASAN_OPTS) RUDY_BUILD_DIR=.build.asan $(RUBY) experiments/test_exp_exc.rb
	$(ASAN_PRELOAD) $(ASAN_OPTS) RUDY_BUILD_DIR=.build.asan $(RUBY) experiments/test_exp_defargs.rb

exp-asan: exp-asan-test

# Memory-safety torture runs (backlog item 7). Local: ASan subset above;
# valgrind not installed locally (CI-only). Excluded locally: http (NOTES.md
# #24 munmap crash, under investigation); gcstorm/compact/convert/objproto
# (NOTES.md #23 rt_init SEGV).
memcheck: exp-asan-test
	@echo "memcheck: ASan subset complete (see experiments/NOTES.md #23/#24)"

# Ruby-side acceptance suite (dexter revival + missing-API bindings)
test: all
	$(RUBY) test/run.rb
	$(RUBY) test/exitest.rb
	$(RUBY) test/typedtest.rb

check: test

# --- the rudy4 gem ----------------------------------------------------------
#
# vendor/rudy/ is a copy of src/rudy/ shipped inside the gem; `vendor-check`
# fails if the two have drifted (CI runs it), `gem-test` covers the CLI, and
# `gem-test-full` also scaffolds + compiles a project with GDC.
$(BUILD)/vendor-synced: $(DC_SRCS)
	@bash scripts/vendor_sync.sh

vendor: $(BUILD)/vendor-synced

vendor-check:
	@bash scripts/vendor_check.sh

gem-test:
	$(RUBY) -Ilib test/rudy4_test.rb

gem-test-full:
	RUDY4_FULL=1 $(RUBY) -Ilib test/rudy4_test.rb

gem-build: vendor-check
	gem build rudy4.gemspec

clean:
	rm -rf .build .build.asan
