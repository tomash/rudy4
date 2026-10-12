# Loads the freshly built dextest.so with the *ruby 4.0.7* interpreter that
# also provided libruby at link time (extension .so must match ABI).
require "pathname"
EXT = Pathname.new(__dir__).parent + ENV.fetch("RUDY_BUILD_DIR", ".build") + "dextest.so"
raise "extension not built: run `make` first" unless EXT.exist?
require EXT.to_s
