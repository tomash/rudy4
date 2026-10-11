#!/usr/bin/env ruby
# EXPERIMENT 4 — single-endpoint HTTP server: D sockets + GVL-released
# accept, Ruby handler block, Ruby side-thread liveness probe.
#
# Flow: register a handler block, start a heartbeat thread, spawn a client
# thread that connects once serve_one is listening, then serve_one blocks
# in accept (GVL released) until the client arrives.
#
# Assertions:
#   1. response status line + body produced by the Ruby handler block
#   2. D read the request line back (D side of the boundary)
#   3. side-thread heartbeats accumulated while D blocked in accept
#      (proves the GVL was really released — else the thread would starve)
#   4. handler raising -> client socket closed (rb_ensure ran), the Ruby
#      exception surfaces through D as RuntimeError, state intact for a
#      second round.

require "pathname"
EXT = Pathname.new(__dir__).parent + ".build" + "exp_http.so"
raise "exp_http not built: run `make exp` first" unless EXT.exist?
require EXT.to_s

require "socket"

$failures = 0
$count = 0

def assert(cond, msg)
  $count += 1
  if cond then puts "ok #{$count} - #{msg}"
  else $failures += 1; puts "FAIL #{$count} - #{msg}" end
end

def assert_equal(expected, actual, msg = nil)
  assert(expected == actual, "#{msg || 'equal'}: expected #{expected.inspect}, got #{actual.inspect}")
end

def assert_raises(exp)
  yield
  assert(false, "expected #{exp} to be raised")
  nil
rescue exp => e
  assert(true, "raised #{exp}")
  e
rescue => e
  assert(false, "expected #{exp}, got #{e.class}: #{e.message}")
  e
end

# ---------------------------------------------------------------- round 1
DExpHTTP.register_handler do |req|
  "served by handler: #{req.lines.first.strip}"
end

hb0 = DExpHTTP.heartbeats

# side thread: bumps the heartbeat counter while D blocks in accept()
t_hb = Thread.new do
  50.times do
    DExpHTTP.heartbeat
    sleep 0.001
  end
end

# client thread: waits for the port, sends one request, reads response
client_result = Queue.new
t_client = Thread.new do
  port = nil
  200.times do
    port = DExpHTTP.port
    break if port > 0
    sleep 0.01
  end
  raise "no port" unless port
  s = TCPSocket.new("127.0.0.1", port)
  s.print "GET /hello HTTP/1.1\r\nHost: x\r\n\r\n"
  s.flush
  resp = s.read
  s.close
  client_result << resp
end

res = # round 2's client thread must not see round 1's stale port: reset first
DExpHTTP.reset
res = DExpHTTP.serve_one            # blocks in accept until client arrives
port, first_line = res
t_client.join
t_hb.kill rescue nil

assert_equal("GET /hello HTTP/1.1", first_line.strip, "D read the request line back")

resp = client_result.pop
assert(resp.start_with?("HTTP/1.1 200 OK"), "client got 200 OK")
assert(resp.include?("Content-Length: "), "response has Content-Length")
assert(resp.include?("served by handler: GET /hello HTTP/1.1"),
       "body produced by Ruby handler block invoked from D")
assert(DExpHTTP.handler_ok, "Ruby handler block was invoked from D")
hb_delta = DExpHTTP.heartbeats - hb0
assert(hb_delta >= 1,
       "side thread ran while D blocked in accept (GVL released): +#{hb_delta}")
assert_equal(port, DExpHTTP.port, "port matches after round 1")

# ---------------------------------------------------------------- round 2
# handler raises mid-request: ensure closes the client socket, the Ruby
# exception surfaces through D, and a follow-up round still works.
DExpHTTP.register_handler do |req|
  raise "kaboom"
end

client_result2 = Queue.new
t_client2 = Thread.new do
  port = nil
  200.times do
    port = DExpHTTP.port
    break if port > 0
    sleep 0.01
  end
  raise "no port" unless port
  s = TCPSocket.new("127.0.0.1", port)
  s.print "GET /bomb HTTP/1.1\r\n\r\n"
  s.flush
  resp = s.read        # EOF: D closed the socket in the ensure path
  s.close
  client_result2 << resp
end

e = assert_raises(RuntimeError) { DExpHTTP.serve_one }  # after DExpHTTP.reset
t_client2.join
resp2 = client_result2.pop
assert(resp2.nil? || resp2.empty?, "client socket closed on handler raise (rb_ensure ran)")
assert(e.message.include?("kaboom") || e.message.include?("handler raised"),
       "original Ruby exception message survived the D longjmp: #{e.message.inspect}")

# ---------------------------------------------------------------- round 3
# state survived round 2's unwind: serve again with a good handler.
DExpHTTP.reset
DExpHTTP.register_handler do |req|
  "third round"
end

client_result3 = Queue.new
t_client3 = Thread.new do
  port = nil
  200.times do
    port = DExpHTTP.port
    break if port > 0
    sleep 0.01
  end
  raise "no port" unless port
  s = TCPSocket.new("127.0.0.1", port)
  s.print "GET /three HTTP/1.1\r\n\r\n"
  s.flush
  resp = s.read
  s.close
  client_result3 << resp
end

DExpHTTP.reset
DExpHTTP.serve_one
t_client3.join
resp3 = client_result3.pop
assert(resp3.include?("third round"), "state intact after handler-raise unwind")

if $failures == 0
  puts "\nEXP HTTP PASS: all #{$count} assertions green"
else
  puts "\nEXP HTTP FAIL: #{$failures}/#{$count} assertions failed"
  exit 1
end
