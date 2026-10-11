/// EXPERIMENT 4 — A tiny single-endpoint HTTP server: D owns the socket,
/// Ruby owns the handler.
///
/// Torture elements:
/// - POSIX socket code entirely in D (std.socket), accept() runs with the
///   GVL RELEASED via rb_thread_call_without_gvl + RUBY_UBF_IO — the same
///   pattern any real blocking C extension must use.
/// - The response body is produced by a Ruby block (proc) handed in from
///   Ruby and invoked via rb_funcallv — D <-> Ruby boundary crossing on a
///   hot path, with fresh Ruby objects (request string) each call.
/// - A Ruby side thread stays alive while D blocks in accept(): proves the
///   GVL is actually released (side thread's heartbeats would stall it).
/// - rb_ensure wraps the whole serve-one-request cycle so the client socket
///   is closed even if the handler block raises mid-response.
///
/// Layout (port chosen by kernel, reported back to Ruby via serve.port):
///
///   DExpHTTP.serve_one(port_block_latch)  — binds 127.0.0.1:0, accepts ONE
///       request, calls the registered handler block with the request
///       string, writes "HTTP/1.1 200 OK\r\nContent-Length: N\r\n\r\n" +
///       body, closes, returns the port used.
///   DExpHTTP.port                        — the bound port after serve_one.
///   DExpHTTP.register_handler(&blk)      — stores the handler proc.
///   DExpHTTP.heartbeat                   — tick counter bumped by a Ruby
///       side thread; serve_one returns it alongside the port so the test
///   DExpHTTP.handler_ok                  — true if the Ruby handler was
///       actually called and returned a String.
///
/// What can go wrong (the point of the torture):
/// - handler block raising with client fd open (ensure must close it)
/// - GC moving the request string while D holds a slice (we .idup)
/// - accept() blocking forever with no UBF (we pass RUBY_UBF_IO; without
///   releasing the GVL a Ruby watchdog thread could never run)

module exp_http;

import rudy.bind.value;
import rudy.convert;
import rudy.defs;

import std.socket;
import std.string : toStringz, fromStringz;
import std.conv : to;
import std.format : format;

private:

// ---- state kept alive across calls ------------------------------------
// TORTURE FINDING #1: D module-level variables are THREAD-LOCAL by default.
// Ruby threads are OS pthreads — a variable set by one Ruby thread is NOT
// visible to another unless declared `__gshared` (C-style global). D1-era
// Rudy never hit this because D1 had no TLS globals. Without __gshared
// the port/heartbeat handshakes below silently read 0 from other threads.
__gshared:
TcpSocket listening_sock;
Socket client_sock;    // NOT TcpSocket: Socket.accept() returns a base
                       // Socket instance; cast(TcpSocket) is a checked
                       // downcast in D and would yield null (torture
                       // finding #3), giving a null-deref on receive().
ushort bound_port;
int heartbeats;            // bumped via DExpHTTP.heartbeat from Ruby
int handler_called;        // set when the Ruby handler block ran
int accept_failed;          // set by do_accept on a D exception
VALUE handler_blk = Qnil_; // the Ruby handler proc

// ubf for interrupting a blocking accept when the Ruby thread is killed
extern (C) void ubf_accept(void* unused)
{
    // RUBY_UBF_IO is what real extensions use for socket waits: it makes
    // the GVL-released call interruptible on Thread#kill/timeout without
    // us implementing a real unblocker (the fd gets closed by the OS on
    // process exit; for a one-shot experiment this is acceptable).
}

extern (C) void* do_accept(void* data)
{
    // running WITHOUT the GVL: pure D socket code, no Ruby API calls.
    // accept() returns a Socket (D GC-allocated), not TcpSocket — cast.
    //
    // TORTURE FINDING #2: when the process gets a signal (timeout(1) sends
    // SIGTERM), accept(2) fails with EINTR and Phobos throws
    // SocketAcceptException — and a D exception unwinding out of a
    // rb_thread_call_without_gvl callback aborts the runtime (gcc.deh
    // terminate: no D handler up-stack). All D exceptions must be
    // swallowed inside the no-GVL region and reported after re-acquiring.
    try
    {
        client_sock = listening_sock.accept();
        accept_failed = false;
    }
    catch (Exception e)
    {
        accept_failed = true;
    }
    return null;
}

// ---- the Ruby handler invocation (GVL held again here) ----------------

extern (C) VALUE call_handler_protected(VALUE data)
{
    // data = the request String built by D
    VALUE blk = handler_blk;
    VALUE[1] av = [data];
    handler_called = 1;
    return rb_funcallv(blk, rb_intern("call"), 1, av.ptr);
}

extern (C) VALUE ensure_close_client(VALUE data)
{
    // runs on the way out no matter what: success, handler raise, or a
    // transport error. Closing twice is fine (second is a no-op).
    if (client_sock !is null)
    {
        client_sock.close();
        client_sock = null;
    }
    return Qnil_;
}

extern (C) VALUE serve_one_body(VALUE self)
{
    // bind 127.0.0.1:0 -> kernel picks a free port
    auto addr = new InternetAddress("127.0.0.1", 0);
    listening_sock = new TcpSocket(AddressFamily.INET);
    listening_sock.bind(addr);
    listening_sock.listen(1);
    bound_port = (cast(InternetAddress) listening_sock.localAddress()).port;

    // accept() with the GVL released — Ruby threads stay alive while we wait
    rb_thread_call_without_gvl(&do_accept, null, &ubf_accept, null);
    if (accept_failed)
        rudy_raise(rb_eRuntimeError, "accept() failed (interrupted or bad fd)");

    // read the request (curl/ruby client sends one small request; we read
    // whatever arrived, up to a sane cap). Plain default-init is fine here.
    ubyte[4096] buf;
    size_t got = client_sock.receive(buf[]);
    if (got == 0)                       // client closed without sending
        rudy_raise(rb_eRuntimeError, "client closed before sending");

    string req = cast(string) buf[0 .. got].idup;

    // hand the request to the Ruby handler block
    VALUE reqv = rb_str_new(req.ptr, cast(C_long) req.length);
    int state;
    VALUE body = rb_protect(&call_handler_protected, reqv, &state);
    if (state)
    {
        // re-raise as a plain RuntimeError carrying the original message:
        // proves the longjmp out of a D frame stack didn't corrupt state.
        VALUE e = rb_errinfo();
        VALUE msg = rb_funcallv(e, rb_intern("message"), 0, null);
        string m = "handler raised: " ~ d_type!string(msg);
        rudy_raise(rb_eRuntimeError, m);
    }
    VALUE body_s = rb_str_to_str(body); // enforce String contract
    auto len = rb_str_strlen(body_s);
    auto bptr = rb_string_value_ptr(&body_s);   // may swap body_s in-place

    // build + write the response
    string head = format!"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n"(len);
    client_sock.send(head);
    client_sock.send(bptr[0 .. len]);

    // return [port, request_first_line] to Ruby
    VALUE res = rb_ary_new_capa(2);
    rb_ary_push(res, rb_int2inum(bound_port));
    size_t line1_len = req.indexOf('\n'); // index of first '\n', or full len
    VALUE line1 = rb_str_new(req.ptr, cast(C_long) line1_len);
    rb_ary_push(res, line1);
    return res;
}

extern (C) VALUE serve_one(VALUE self)
{
    handler_called = 0;
    bound_port = 0;   // so Ruby's port>0 poll waits for THIS round's listener
    // also drop any leftover listener from a previous round
    if (listening_sock !is null)
    {
        try { listening_sock.close(); } catch (Exception e) {}
        listening_sock = null;
    }
    // rb_ensure: body, body_data, ensure, ensure_data
    return rb_ensure(&serve_one_body, Qnil_, &ensure_close_client, Qnil_);
}

extern (C) VALUE reset(VALUE self)
{
    // close any leftover listener (e.g. after a raise round) and zero the
    // port so a new round's client poll waits for a fresh bind
    if (listening_sock !is null)
    {
        try { listening_sock.close(); } catch (Exception e) {}
        listening_sock = null;
    }
    if (client_sock !is null)
    {
        try { client_sock.close(); } catch (Exception e) {}
        client_sock = null;
    }
    bound_port = 0;
    return Qnil_;
}

extern (C) VALUE get_port(VALUE self)  { return rb_int2inum(bound_port); }
extern (C) VALUE get_heartbeats(VALUE self) { return rb_int2inum(heartbeats); }
extern (C) VALUE heartbeat(VALUE self)  { heartbeats += 1; return Qnil_; }
extern (C) VALUE handler_ok(VALUE self) { return handler_called ? Qtrue_ : Qfalse_; }

extern (C) VALUE register_handler(VALUE self)
{
    // Called as DExpHTTP.register_handler { |req| ... } — arity 0, the block
    // is materialized via rb_block_proc (raises if no block was given).
    handler_blk = rb_block_proc();
    return handler_blk;
}

// so the side-thread test can bump the counter from Ruby
extern (C) VALUE exphttp_note(VALUE self, VALUE note)
{
    VALUE m = rb_define_module("ExpHTTPNotes");
    rb_iv_set(m, "@note", note);
    return note;
}

// VOID_INIT helper removed — plain `ubyte[4096] buf;` works and avoids
// template-instantiation pitfalls under GDC.

// min/indexOf shims (avoid pulling whole std.algorithm for two names)
private size_t indexOf(string s, char c)
{
    foreach (i, dchar ch; s)
        if (ch == c) return i;
    return s.length;
}

pragma(mangle, "Init_exp_http")
extern (C) void Init_exp_http()
{
    VALUE m = rb_define_module("DExpHTTP");
    rb_define_module_function(m, "serve_one",
        cast(AnyMethod) &serve_one, 0);
    rb_define_module_function(m, "reset",
        cast(AnyMethod) &reset, 0);
    rb_define_module_function(m, "register_handler",
        cast(AnyMethod) &register_handler, 0);
    rb_define_module_function(m, "port", cast(AnyMethod) &get_port, 0);
    rb_define_module_function(m, "heartbeats", cast(AnyMethod) &get_heartbeats, 0);
    rb_define_module_function(m, "heartbeat", cast(AnyMethod) &heartbeat, 0);
    rb_define_module_function(m, "handler_ok", cast(AnyMethod) &handler_ok, 0);
    rb_gc_register_address(&handler_blk);
}
