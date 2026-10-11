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

.PHONY: all clean test check

all: .build/dextest.so

# One shared object: the rudy library modules + the extension entry point.
.build/dextest.so: $(DC_SRCS) src/dextest.d | .build
	$(GDC) -shared -o $@ $(DFLAGS) $(DC_SRCS) src/dextest.d \
	  -L$(LIBRUBY_DIR) $(LIBRUBYARG) -lm

.build:
	mkdir -p .build

# Ruby-side acceptance suite (dexter revival)
test: all
	$(RUBY) test/run.rb

check: test

clean:
	rm -rf .build
