// A tiny "wish"-style SSH app server.
//
// The idea, same as Charm's wish: an SSH server is just a program that accepts
// connections, answers the client's "give me a pty" request with "sure", and
// then treats the channel as a terminal — bytes in are keystrokes, bytes out
// are ANSI escape sequences. No pty is ever allocated on this side, and no
// shell is ever forked. The remote terminal *is* the display.
package ssh

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import ls "../libssh"

// --- input path --------------------------------------------------------------
//
// Keystrokes take exactly one path: libssh parses each CHANNEL_DATA packet
// into the channel's internal buffer, and `read` (below) is the only consumer,
// draining that buffer with ssh_channel_read_nonblocking. No
// channel_data_function is registered, on purpose.
//
// It used to take two paths, and that was a session-killing defect. A
// channel_data_function copied bytes into a fixed per-session ring and
// returned less than offered when the ring was full, on the belief that
// libssh re-offers the remainder by itself. It does not: the callback runs
// only from libssh's channel_rcv_data, i.e. when the *next* CHANNEL_DATA
// packet arrives. A large paste is a burst followed by silence, so the tail
// of it sat in the channel buffer with nothing to release it and the session
// was deaf for the rest of the connection (measured: 1 MiB pasted, ~550 KB
// stranded, the quit key never seen in 60 s). Draining the leftover from
// `read` while keeping the callback is not sound either:
// ssh_channel_read_nonblocking pumps the packet machinery internally, which
// can fire the callback mid-drain and reorder or drop what it grabs
// (measured: 42 KB of a 1 MiB paste silently lost that way). One buffer, one
// consumer. See docs/architecture.md, "Input flow".
//
// Flow control and memory stay bounded without any code here: libssh only
// extends the client's transport window as this side consumes (grow_window in
// libssh's channels.c, called from ssh_channel_read_timeout), and it refuses
// to let the client get more than WINDOW_DEFAULT — 2 MiB — ahead of what has
// been consumed. A flood therefore parks at most ~2 MiB in libssh's buffer
// and then throttles to the app's own read rate.

// Handler runs on its own thread, one per connection, and owns the session for
// as long as it runs. When it returns the connection is torn down.
Handler :: #type proc(s: ^Session)

// The SSH authentication methods this server understands.
Auth_Method :: enum u8 {
	None,
	Password,
	Publickey,
}
// A set of `Auth_Method`. Note that offering `.None` means an OpenSSH client
// authenticates before ever offering a key, leaving `Session.id` empty.
Auth_Methods :: distinct bit_set[Auth_Method;u8]

// Every method. The default when `Config.methods` is left zero.
ALL_AUTH :: Auth_Methods{.None, .Password, .Publickey}

// What an `Authenticator` is told. For `.Publickey`, the key's signature has
// already been verified — unverified probes never reach application code.
Auth_Request :: struct {
	user:        string,
	method:      Auth_Method,
	// .Password only. Unlike every other field here, this borrows libssh's own
	// buffer, which is zeroed and freed as soon as the callback returns — copy it
	// if you need it beyond the call.
	password:    string,
	fingerprint: string, // .Publickey only, e.g. "SHA256:0Cn7…" — signature verified
	key_type:    string, // .Publickey only, e.g. "ssh-ed25519"
	id:          string, // pseudonymous account id, when an identity secret is set
	remote_addr: string, // numeric peer address
}

// Return true to let the client in. A nil Authenticator accepts everyone.
//
// READ THIS BEFORE USING IT. Rejecting a public key here does not just deny
// access — it makes the client offer its *next* key, and the next, so a
// rejecting server learns every public key in the user's agent. That is a real
// fingerprinting vector and it is why this server accepts by default.
//
// If you want a members-only app, do not reject here. Accept the key, take the
// `id` from Info, and show non-members a "you are not on the list" screen
// inside the app. They are equally excluded and you learn exactly one key.
// See examples/members.
Authenticator :: #type proc(req: Auth_Request) -> bool

// Server-wide state, shared by every connection. Internal; reach it through
// `Session.server` only if you know what you are doing.
Server :: struct {
	bind:         ls.Bind,
	handler:      Handler,
	authenticate: Authenticator,
	methods:      Auth_Methods,
	secret:       Identity_Secret,
	limiter:      Limiter,
	audit:        Audit_Sink,
	user_data:    rawptr,
	// The allocator per-connection state is created and destroyed with.
	//
	// Deliberately NOT context.allocator. A Session is allocated by the accept
	// loop and freed by its own thread, so it crosses threads — and the caller's
	// allocator may be an arena or a tracking allocator that is neither
	// thread-safe nor able to free individual objects. Using it here turns one
	// unauthenticated TCP connection into a SIGABRT for anyone following the
	// ordinary Odin idiom of setting context.allocator.
	//
	// The heap allocator is thread-safe and supports free, so Sessions come from
	// there regardless of what the caller has configured.
	allocator:    mem.Allocator,
	host:         string,
	port:         int,
	// Cleared to stop the accept loop; read atomically by it.
	running:      bool,
	// Set once shutdown begins. Every session's `read` returns "connection
	// gone" while this is set, which is what walks an app's own loop back out
	// through its Handler so the connection tears down through the ordinary
	// path instead of being severed. Read atomically from every session thread.
	draining:     bool,
	warned_enum:  bool, // one-shot enumeration warning; touched atomically
}

// Upper bounds on client-supplied terminal geometry, matching tui's own limits.
// pty-req and window-change both carry uint32 dimensions chosen by the client;
// unclamped they are an allocation-size overflow and a remote crash.
MAX_PTY_COLS :: 1000
MAX_PTY_ROWS :: 300

// The terminal geometry the client asked for. No pseudo-terminal is actually
// allocated — this is just what the client told us about its own.
Pty :: struct {
	term:    string, // borrowed from Session.term_buf
	cols:    int,
	rows:    int,
	px:      int,
	py:      int,
	present: bool,
}

// One connection. Created and freed by the accept loop; your `Handler` owns it
// for the duration of the call. All its string accessors borrow memory that
// dies with the session.
Session :: struct {
	server:        ^Server,
	sess:          ls.Session,
	chan:          ls.Channel,
	event:         ls.Event,
	server_cb:     ls.Server_Callbacks,
	channel_cb:    ls.Channel_Callbacks,
	pty:           Pty,
	resized:       bool, // set by window-change, cleared by the reader
	authenticated: bool,
	shell:         bool,
	eof:           bool,
	auth_method:   string,
	// When the shell was granted, for the session_end audit duration. Written
	// by this connection's own session thread just before it calls the handler,
	// and read only by that same thread — it never crosses a thread boundary.
	started:       time.Time,

	// fixed storage so libssh callbacks never touch an allocator
	user_buf:      [64]u8,
	user_len:      int,
	term_buf:      [32]u8,
	term_len:      int,
	fp_buf:        [96]u8,
	fp_len:        int,
	kt_buf:        [64]u8,
	kt_len:        int,
	id_buf:        [ID_SIZE]u8,
	id_len:        int,
	addr_buf:      [64]u8,
	addr_len:      int,
	auth_failures: int,
	user_data:     rawptr, // copied from Server.user_data for handler use
}

// --- public session API -----------------------------------------------------

// The username the client offered. Client-chosen and unverified — never use it
// as identity; use `id` instead.
user :: proc "contextless" (s: ^Session) -> string {
	return string(s.user_buf[:s.user_len])
}

// The client's `$TERM`, e.g. "xterm-256color". Empty if no pty was requested.
term :: proc "contextless" (s: ^Session) -> string {
	return string(s.term_buf[:s.term_len])
}

// SHA256 fingerprint of the key the client authenticated with, or "" if they
// did not use one. Stable across connections — use it as an account id.
fingerprint :: proc "contextless" (s: ^Session) -> string {
	return string(s.fp_buf[:s.fp_len])
}

// The verified key's algorithm, e.g. "ssh-ed25519". Empty unless public-key
// auth was used.
key_type :: proc "contextless" (s: ^Session) -> string {
	return string(s.kt_buf[:s.kt_len])
}

// Pseudonymous account id: HMAC(server secret, fingerprint). Empty unless an
// identity secret is configured and the client used a key. Store this, not the
// fingerprint. See identity.odin.
id :: proc "contextless" (s: ^Session) -> string {
	return string(s.id_buf[:s.id_len])
}

// Numeric peer address, no reverse DNS.
remote_addr :: proc "contextless" (s: ^Session) -> string {
	return string(s.addr_buf[:s.addr_len])
}

// Current terminal geometry in cells, falling back to 80x24 if the client never
// said.
size :: proc "contextless" (s: ^Session) -> (cols, rows: int) {
	cols, rows = s.pty.cols, s.pty.rows
	if cols <= 0 {cols = 80}
	if rows <= 0 {rows = 24}
	// The client chose these. Clamp on the way out as well as on the way in, so
	// no caller can be handed a hostile geometry even if it never reaches tui.
	return clamp(cols, 1, MAX_PTY_COLS), clamp(rows, 1, MAX_PTY_ROWS)
}

// Blocks for up to timeout_ms waiting for input. Returns ok=false once the
// connection is gone. n == 0 with ok == true just means "nothing typed".
//
// Note on the two-step wait: ssh_event_dopoll's timeout argument does not
// actually block for us — it returns immediately every time, which would spin
// a core per session. So libssh gets to do the parsing while we do the waiting,
// on the session socket directly.
read :: proc(s: ^Session, buf: []u8, timeout_ms: int) -> (n: int, ok: bool) {
	// A draining server reports every session as finished. An app's loop is
	// built to exit when its input dies, so this is what turns "stop the
	// server" into each app running its own teardown — restoring the client's
	// terminal, freeing its model — rather than having the socket yanked.
	if sync.atomic_load(&s.server.draining) {
		return 0, false
	}
	// Deliver anything libssh already holds for this channel — including the
	// tail of a paste that arrived long before this call. This must come
	// before the eof check: the client's final keystrokes and its EOF can be
	// parsed in the same poll, and the bytes are handed over first, leaving
	// the EOF for the next call.
	if n := take_input(s, buf); n > 0 {
		return n, true
	}
	if s.eof {
		return 0, false
	}

	// Pump the protocol once, then look again.
	if ls.event_dopoll(s.event, 0) == ls.ERROR {
		return 0, false
	}
	if n := take_input(s, buf); n > 0 {
		return n, true
	}
	if s.eof {
		return 0, false
	}

	fd := ls.get_fd(s.sess)
	if !ls.socket_valid(fd) {
		return 0, false
	}
	// wait_readable is the one platform split in this file; see net_posix.odin.
	readable, alive := wait_readable(fd, timeout_ms)
	if !alive {
		return 0, false
	}
	if !readable {
		return 0, true // timed out with nothing to read
	}
	if ls.event_dopoll(s.event, 0) == ls.ERROR {
		return 0, false
	}
	if n := take_input(s, buf); n > 0 {
		return n, true
	}
	return 0, !s.eof
}

// The single consumer of the channel's buffered input. Reads whatever libssh
// has parsed for the session's stdin, up to len(buf), without blocking.
//
// Consuming from here is also what reopens the client's transport window:
// grow_window runs inside libssh's channel read. Do not add a second consumer
// (a channel_data_function, or another reader thread) — see the input-path
// comment above for how two consumers of one buffer lost and reordered bytes.
@(private)
take_input :: proc(s: ^Session, buf: []u8) -> int {
	if s.chan == nil || len(buf) == 0 {
		return 0
	}
	n := ls.channel_read_nonblocking(s.chan, raw_data(buf), u32(len(buf)), 0)
	if n > 0 {
		return int(n)
	}
	// Negative n is EOF or an error; both are reported through s.eof and the
	// event loop rather than from here.
	//
	// A client can also send "stderr" extended data, which this server has no
	// use for. It lands in a separate buffer that shares the channel's flow-
	// control window, so it must be discarded, not ignored — left in place it
	// would pin the window shut. The data callback used to swallow it; now
	// this does. Only reached when stdin is quiet, which is exactly when a
	// stderr-flooding client needs its window credit back.
	junk: [1024]u8
	for ls.channel_read_nonblocking(s.chan, &junk[0], len(junk), 1) > 0 {}
	return 0
}

// Sends bytes to the client. Returns how many were written, 0 once the
// connection is gone.
write :: proc(s: ^Session, data: []u8) -> int {
	if len(data) == 0 || s.chan == nil || s.eof {
		return 0
	}
	rc := ls.channel_write(s.chan, raw_data(data), u32(len(data)))
	if rc == ls.ERROR {
		s.eof = true
		return 0
	}
	return int(rc)
}

// `write` for a string.
write_string :: proc(s: ^Session, str: string) -> int {
	return write(s, transmute([]u8)str)
}

// True exactly once after each window resize.
take_resize :: proc "contextless" (s: ^Session) -> bool {
	r := s.resized
	s.resized = false
	return r
}

// --- server -----------------------------------------------------------------

// How to run the server. Every field has a documented default, so the zero value
// is a working — if wide open — public server on port 2222.
Config :: struct {
	host:              string,
	port:              int,
	host_key_path:     string,
	handler:           Handler,
	user_data:         rawptr,
	// nil accepts every client. Read the Authenticator docs before setting it.
	authenticate:      Authenticator,
	// Which methods to offer. Zero value means ALL_AUTH.
	methods:           Auth_Methods,
	// Enables pseudonymous ids. When set, the secret is loaded from (or created
	// at) this path. Leave empty to disable — Session.id will be "".
	identity_secret:   string,
	// Per-field: 0 uses the default, negative disables that limit.
	limits:            Limits,
	// Where connection, authentication and session events go. nil — the zero
	// value — means no auditing at all, which is deliberate: every audit line
	// carries the client's numeric address, and keeping a record of who
	// connected and when is a privacy decision the operator must make on
	// purpose. `audit_stderr` is a ready-made sink; audit.odin documents the
	// line format it produces.
	audit:             Audit_Sink,
	// Algorithm allow-lists, in libssh's comma-separated format. Empty means
	// the hardened defaults below; set to "-" to accept libssh's own defaults,
	// which are broader and include things like RSA/SHA-1-era compatibility.
	key_exchange:      string,
	ciphers:           string,
	macs:              string,
	hostkey_algorithms: string,
	// Seconds `serve` waits for connected sessions to finish once shutdown
	// starts. 0 uses DEFAULT_SHUTDOWN_SECONDS; negative returns immediately
	// without waiting, which leaves clients' terminals in the alternate
	// screen and is only sensible when you are about to exec or _exit anyway.
	shutdown_seconds:  int,
	// By default `serve` handles SIGINT and SIGTERM so the process stops
	// without stranding anyone's terminal, restoring the previous handlers
	// before it returns. Set this if the surrounding program owns signal
	// handling itself; then use `shutdown` to stop the server.
	no_signal_handlers: bool,
}

// How long the accept loop waits in poll before re-checking whether it has
// been asked to stop. The upper bound on how long shutdown takes to begin.
@(private)
ACCEPT_POLL_MS :: 200

// Modern-only. Every one of these is an AEAD or an ETM MAC with a
// curve25519 exchange; nothing here depends on SHA-1, CBC, or NIST curves.
DEFAULT_KEX :: "curve25519-sha256,curve25519-sha256@libssh.org"
// AEAD ciphers only: no CBC, no stream ciphers with separate MACs.
DEFAULT_CIPHERS :: "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com"
// Encrypt-then-MAC only, SHA-2 only.
DEFAULT_MACS :: "hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com"
// Ed25519 only — matches the key `ensure_host_key` generates.
DEFAULT_HOSTKEYS :: "ssh-ed25519"

// Creates the host key if it does not exist yet — the SSH equivalent of a TLS
// certificate. Clients pin it in ~/.ssh/known_hosts, so it must be stable
// across restarts.
ensure_host_key :: proc(path: string, advertised := DEFAULT_HOSTKEYS) -> bool {
	if os.exists(path) {
		warn_if_world_readable(path)
		// An existing key of the wrong type is a silent, total outage: key
		// exchange fails for every client and nothing upstream logs a reason.
		// Check it here, where we can say something useful.
		cpath := strings.clone_to_cstring(path, context.temp_allocator)
		key: ls.Key
		if ls.pki_import_privkey_file(cpath, nil, nil, nil, &key) != ls.OK {
			fmt.eprintfln("otsh: cannot read the host key at %s", path)
			return false
		}
		defer ls.key_free(key)

		name := ls.key_type_to_char(ls.key_type(key))
		type_name := name == nil ? "unknown" : string(name)
		if advertised != "-" && !contains(advertised, type_name) {
			fmt.eprintfln(
				"otsh: the host key at %s is %s, but the advertised host key\n" +
				"      algorithms are %q. No client could complete key exchange.\n" +
				"      Either use an %s key, or set Config.hostkey_algorithms to\n" +
				"      include %s.",
				path, type_name, advertised, advertised, type_name,
			)
			return false
		}
		return true
	}
	key: ls.Key
	if ls.pki_generate(.Ed25519, 0, &key) != ls.OK {
		fmt.eprintln("otsh: failed to generate host key")
		return false
	}
	defer ls.key_free(key)

	cpath := strings.clone_to_cstring(path)
	defer delete(cpath)

	// libssh writes the key with fopen(path, "wb"), i.e. 0666 & ~umask. Under a
	// permissive umask that is a world-WRITABLE private key, and chmod-ing after
	// the fact does not help: another process only has to win the open(), not the
	// read — a descriptor obtained during the window survives the chmod, and a
	// writable window means the key can be replaced, not merely stolen.
	//
	// So create the file ourselves, empty, O_EXCL and 0600, before libssh opens
	// it. fopen("wb") on an existing file truncates but leaves the mode alone,
	// so the key is never visible at any wider permission.
	if f, err := os.open(path, {.Write, .Create, .Excl}, {.Read_User, .Write_User}); err == nil {
		os.close(f)
	} else {
		fmt.eprintfln("otsh: cannot create host key file %s: %v", path, err)
		return false
	}

	if ls.pki_export_privkey_file(key, nil, nil, nil, cpath) != ls.OK {
		fmt.eprintln("otsh: failed to write host key to", path)
		os.remove(path)
		return false
	}
	ensure_private_mode(path)
	fmt.println("otsh: generated new ed25519 host key at", path)
	return true
}

@(private)
contains :: proc(haystack, needle: string) -> bool {
	return strings.contains(haystack, needle)
}

// Returns false if any list was rejected by libssh.
//
// This return value matters more than it looks. libssh rejects a list whose
// entries are *all* unknown to it and silently keeps its own, broader default —
// which includes CTR ciphers and non-ETM MACs. Ignoring the result means a typo
// in Config, or a name this libssh build does not know, downgrades the
// negotiated crypto with no indication anywhere. Fail closed instead.
@(private)
set_algorithms :: proc(b: ls.Bind, cfg: Config) -> bool {
	ok := true
	// "-" opts out and leaves libssh's defaults alone.
	apply :: proc(b: ls.Bind, opt: ls.Bind_Option, value, fallback, what: string, ok: ^bool) {
		v := value == "" ? fallback : value
		if v == "-" {
			return
		}
		cv := strings.clone_to_cstring(v, context.temp_allocator)
		if ls.bind_options_set(b, opt, rawptr(cv)) != ls.OK {
			fmt.eprintfln(
				"otsh: libssh rejected the %s list %q.\n" +
				"      Every name in it is unknown to this libssh build, so it would have\n" +
				"      fallen back to libssh's own (weaker) default. Refusing to start.",
				what, v,
			)
			ok^ = false
		}
	}
	apply(b, .Key_Exchange, cfg.key_exchange, DEFAULT_KEX, "key exchange", &ok)
	apply(b, .Ciphers_C_S, cfg.ciphers, DEFAULT_CIPHERS, "cipher (client->server)", &ok)
	apply(b, .Ciphers_S_C, cfg.ciphers, DEFAULT_CIPHERS, "cipher (server->client)", &ok)
	apply(b, .Hmac_C_S, cfg.macs, DEFAULT_MACS, "MAC (client->server)", &ok)
	apply(b, .Hmac_S_C, cfg.macs, DEFAULT_MACS, "MAC (server->client)", &ok)
	apply(b, .Hostkey_Algorithms, cfg.hostkey_algorithms, DEFAULT_HOSTKEYS, "host key algorithm", &ok)
	return ok
}

// Defaults applied to a zero-valued Config field. sshtui fills these in too;
// they live here as well so calling ssh.serve directly cannot bind port 0.
DEFAULT_HOST :: "0.0.0.0"
// Port used when `Config.port` is zero.
DEFAULT_PORT :: 2222
// Host key path used when `Config.host_key_path` is empty.
DEFAULT_HOST_KEY :: "hostkey"

// Binds, listens, and accepts connections until the process exits, spawning one
// thread per connection. Returns false if setup fails; otherwise blocks.
// Refuses to continue on a libssh too old to have the Terrapin fix. The check
// is at runtime, not compile time, because the shared library that gets loaded
// is not necessarily the one the bindings were compiled against.
@(private)
check_libssh_version :: proc() -> bool {
	required := ls.version_int(ls.MIN_MAJOR, ls.MIN_MINOR, ls.MIN_MICRO)
	if got := ls.version(required); got != nil {
		return true
	}
	// ssh_version returns nil when the runtime library is older than requested.
	actual := ls.version(0)
	fmt.eprintfln(
		"otsh: refusing to start — libssh %s is older than the required %d.%d.%d.\n" +
		"      Versions before 0.10.6 lack the fix for CVE-2023-48795 (Terrapin).\n" +
		"      Upgrade the system libssh, then rebuild.",
		actual == nil ? "(unknown)" : string(actual),
		ls.MIN_MAJOR, ls.MIN_MINOR, ls.MIN_MICRO,
	)
	return false
}

serve :: proc(cfg: Config) -> bool {
	if !check_libssh_version() {
		return false
	}
	cfg := cfg
	if cfg.host == "" {cfg.host = DEFAULT_HOST}
	if cfg.port == 0 {cfg.port = DEFAULT_PORT}
	if cfg.host_key_path == "" {cfg.host_key_path = DEFAULT_HOST_KEY}

	ls.threads_set_callbacks(ls.threads_get_default())
	if ls.init() != ls.OK {
		fmt.eprintln("otsh: ssh_init failed")
		return false
	}

	if !ensure_host_key(cfg.host_key_path,
	    cfg.hostkey_algorithms == "" ? DEFAULT_HOSTKEYS : cfg.hostkey_algorithms) {
		return false
	}

	srv := new(Server)
	srv.allocator = runtime.heap_allocator()
	srv.handler = cfg.handler
	srv.authenticate = cfg.authenticate
	srv.methods = cfg.methods == {} ? ALL_AUTH : cfg.methods
	srv.audit = cfg.audit
	srv.user_data = cfg.user_data
	srv.host = cfg.host
	srv.port = cfg.port
	limiter_init(&srv.limiter, cfg.limits)

	if cfg.identity_secret != "" {
		secret, ok := load_or_create_secret(cfg.identity_secret)
		if !ok {
			return false
		}
		srv.secret = secret
	}

	srv.bind = ls.bind_new()
	if srv.bind == nil {
		fmt.eprintln("otsh: ssh_bind_new failed")
		return false
	}

	chost := strings.clone_to_cstring(cfg.host)
	ckey := strings.clone_to_cstring(cfg.host_key_path)
	defer delete(chost)
	defer delete(ckey)
	port := c.int(cfg.port)

	ls.bind_options_set(srv.bind, .Bindaddr, rawptr(chost))
	ls.bind_options_set(srv.bind, .Bindport, &port)
	ls.bind_options_set(srv.bind, .Hostkey, rawptr(ckey))
	if !set_algorithms(srv.bind, cfg) {
		return false
	}

	if ls.bind_listen(srv.bind) < 0 {
		fmt.eprintfln("otsh: listen failed: %s", ls.get_error(rawptr(srv.bind)))
		return false
	}

	srv.running = true
	if !cfg.no_signal_handlers {
		install_signal_handlers()
	}
	defer if !cfg.no_signal_handlers {restore_signal_handlers()}

	// The only non-ASCII byte this package writes to a console, and a Windows
	// console decodes what it is given with the *console output code page* —
	// the user's OEM one unless somebody changed it, 852 on the machine this
	// was found on, where the arrow arrived as "Ôćĺ". tui/local_windows.odin
	// switches that code page to UTF-8 for the TUI and restores it on exit, but
	// a server that may never draw a frame has no business mutating the parent
	// shell's console state for one glyph, so here the arrow is ASCII.
	arrow :: "->" when ODIN_OS == .Windows else "→"
	fmt.printfln("otsh: listening on %s:%d  %s  ssh -p %d %s",
		cfg.host, cfg.port, arrow, cfg.port, cfg.host)
	audit_emit(srv, Audit_Event{kind = .Listen, host = cfg.host, port = cfg.port})

	// The listening socket, watched directly so the loop can wait with a
	// timeout. ssh_bind_accept blocks in accept(2) with no timeout of its own,
	// which would mean a stop signal went unnoticed until the next client
	// happened to connect — on an idle server, indefinitely.
	listen_fd := ls.bind_get_fd(srv.bind)

	for sync.atomic_load(&srv.running) {
		if sync.atomic_load(&signal_requested) {
			break
		}
		// Wait in poll, not in accept, so this loop wakes up regularly enough
		// to notice a stop request. A signal interrupting the wait leaves
		// alive == true; only a genuine poll failure ends the loop.
		readable, alive := wait_readable(listen_fd, ACCEPT_POLL_MS)
		if !alive {
			fmt.eprintfln("otsh: accept poll failed: %s", ls.get_error(rawptr(srv.bind)))
			break
		}
		if !readable {
			continue
		}

		s := new(Session, srv.allocator)
		s.server = srv
		s.user_data = srv.user_data
		s.sess = ls.new_session()
		if s.sess == nil {
			free(s, srv.allocator)
			continue
		}
		// A connection is already pending, so this does not block.
		if ls.bind_accept(srv.bind, s.sess) != ls.OK {
			fmt.eprintfln("otsh: accept failed: %s", ls.get_error(rawptr(srv.bind)))
			ls.free_session(s.sess)
			free(s, srv.allocator)
			continue
		}

		// Check the limits here, before committing a thread. Doing it inside the
		// session thread meant a rejected connection still cost a pthread and a
		// whole Session first, so the limiter protected memory but not the
		// accept path itself.
		addr := peer_address(ls.get_fd(s.sess), s.addr_buf[:])
		s.addr_len = len(addr)
		audit_emit(srv, Audit_Event{kind = .Accept, addr = addr})
		if ok, tripped := limiter_acquire(&srv.limiter, addr); !ok {
			audit_emit(srv, Audit_Event{kind = .Reject, addr = addr, limit = tripped})
			ls.disconnect(s.sess)
			ls.free_session(s.sess)
			free(s, srv.allocator)
			continue
		}
		// Thread creation can fail under resource pressure. Dropping the
		// connection cleanly is the only sane response — leaving it accepted
		// with nothing to service it would hold a socket open forever.
		if thread.create_and_start_with_poly_data(s, session_thread, self_cleanup = true) == nil {
			fmt.eprintln("otsh: could not start a session thread; dropping the connection")
			limiter_release(&srv.limiter, remote_addr(s))
			ls.disconnect(s.sess)
			ls.free_session(s.sess)
			free(s, srv.allocator)
		}
	}

	// Stop accepting, then let everyone still connected finish on their own.
	sync.atomic_store(&srv.running, false)
	sync.atomic_store(&srv.draining, true)

	secs := cfg.shutdown_seconds
	if secs == 0 {secs = DEFAULT_SHUTDOWN_SECONDS}
	if secs > 0 {
		report_shutdown(srv, drain_sessions(srv, secs), secs)
	}

	ls.bind_free(srv.bind)
	ls.finalize()
	return true
}

@(private)
session_thread :: proc(s: ^Session) {
	// The accept loop already took this connection's limiter slot and recorded
	// the peer address; this thread owns releasing it.
	defer {
		limiter_release(&s.server.limiter, remote_addr(s))
		if s.chan != nil {
			ls.channel_send_eof(s.chan)
			ls.channel_close(s.chan)
			ls.channel_free(s.chan)
		}
		if s.event != nil {
			ls.event_remove_session(s.event, s.sess)
			ls.event_free(s.event)
		}
		ls.disconnect(s.sess)
		// Nothing here is a secret we chose to keep, but the fingerprint and id
		// are the user's data; do not leave them in freed memory.
		s.fp_buf = {}
		s.id_buf = {}
		ls.free_session(s.sess)
		free(s, s.server.allocator)
	}

	// A client that opens a socket and then goes quiet would otherwise hold
	// this thread forever. The socket timeout covers key exchange and auth.
	if secs := s.server.limiter.limits.handshake_seconds; secs > 0 {
		t := u64(secs)
		ls.options_set(s.sess, .Timeout, &t)
	}

	// Callbacks and auth methods MUST be installed before key exchange, not
	// after. The client's SERVICE_REQUEST routinely shares a TCP segment with
	// its NEWKEYS, so handle_key_exchange consumes it — and libssh's
	// ssh_message_queue only answers a service request when server callbacks
	// are already set. With none set, it appends the message to an internal
	// list that nothing ever drains: no SERVICE_ACCEPT is sent, the client
	// waits for a reply that will never come, and the connection dies at the
	// handshake timeout with no error anywhere. Whether it happens depends on
	// how the client's packets were coalesced, which is why it presented as a
	// load-dependent 1-in-3 hang. Measured: 12/30 connections stalled with
	// this block after handle_key_exchange, 0/30 with it before, on libssh
	// 0.10.6, 0.11.2 and 0.12.2 alike.
	//
	// Consequence to respect: authentication can now complete *inside*
	// handle_key_exchange, so nothing below may assume s.authenticated is
	// false at this point. The pump loop's condition already allows for it.
	s.server_cb = ls.Server_Callbacks {
		size                                  = size_of(ls.Server_Callbacks),
		userdata                              = s,
		auth_none_function                    = cb_auth_none,
		auth_password_function                = cb_auth_password,
		auth_pubkey_function                  = cb_auth_pubkey,
		channel_open_request_session_function = cb_channel_open,
	}
	ls.set_server_callbacks(s.sess, &s.server_cb)

	methods := c.int(0)
	if .None in s.server.methods {methods |= ls.AUTH_METHOD_NONE}
	if .Password in s.server.methods {methods |= ls.AUTH_METHOD_PASSWORD}
	if .Publickey in s.server.methods {methods |= ls.AUTH_METHOD_PUBLICKEY}
	ls.set_auth_methods(s.sess, methods)

	// Key exchange: negotiates ciphers and proves we own the host key.
	if ls.handle_key_exchange(s.sess) != ls.OK {
		audit_emit(s.server, Audit_Event{kind = .Kex_Fail, addr = remote_addr(s)})
		return
	}

	s.event = ls.event_new()
	ls.event_add_session(s.event, s.sess)

	// Pump the protocol until the client has authenticated, opened a session
	// channel and asked for a shell. Everything is driven by the callbacks
	// below, which run inside event_dopoll on this thread.
	for i := 0; i < 200 && !(s.authenticated && s.chan != nil && s.shell); i += 1 {
		if ls.event_dopoll(s.event, 100) == ls.ERROR {
			return
		}
	}
	if !(s.authenticated && s.chan != nil && s.shell) {
		return
	}

	cols, rows := size(s)
	s.started = time.now()
	audit_session(s, Audit_Event{kind = .Session_Start, term = term(s), cols = cols, rows = rows})
	// Declared after the start event so it runs before the teardown block above,
	// while the address and id buffers are still populated.
	defer audit_session(s, Audit_Event{kind = .Session_End, duration = time.since(s.started)})

	if s.server.handler != nil {
		s.server.handler(s)
	}

	if s.chan != nil {
		ls.channel_request_send_exit_status(s.chan, 0)
	}
}

// --- libssh callbacks -------------------------------------------------------
//
// These run with the C calling convention, so they set up an Odin context
// before touching anything that might need one.

@(private)
set_user :: proc "contextless" (s: ^Session, u: cstring) {
	if u != nil {
		copy_cstr(s.user_buf[:], &s.user_len, u)
	}
}

// ssh_set_auth_methods only advertises what the server offers; libssh still
// invokes the callback for a method the client tries anyway. The policy has to
// be enforced here or `methods = {.Publickey}` means nothing.
@(private)
allow :: proc "contextless" (s: ^Session, req: Auth_Request) -> bool {
	// The Authenticator and the audit sink are both ordinary Odin procs, so a
	// context has to exist before either can be called.
	context = runtime.default_context()

	ok := true
	switch {
	case req.method not_in s.server.methods:
		ok = false
	case s.server.limiter.limits.max_auth_attempts > 0 &&
	     s.auth_failures >= s.server.limiter.limits.max_auth_attempts:
		ok = false
	case s.server.authenticate != nil:
		ok = s.server.authenticate(req)
		if !ok {
			s.auth_failures += 1
			// One-shot across all connections. Atomic because every session
			// thread can reach it; the exchange makes exactly one of them print.
			if req.method == .Publickey &&
			   !sync.atomic_exchange(&s.server.warned_enum, true) {
				fmt.eprintln(
					"otsh: NOTE an Authenticator rejected a public key. The client will now\n" +
					"      offer its next key, and the next — a rejecting server learns every\n" +
					"      key in the user's agent. Prefer accepting the key and refusing\n" +
					"      inside the app (see examples/members).",
				)
			}
		}
	}

	// Every outcome is audited, including the two policy refusals above that
	// never reach an Authenticator — a client hammering a method this server
	// does not offer is exactly what a log filter needs to see.
	audit_emit(
		s.server,
		Audit_Event {
			kind = .Auth,
			addr = req.remote_addr,
			user = req.user,
			method = req.method,
			ok = ok,
			id = req.id,
		},
	)
	return ok
}

@(private)
cb_auth_none :: proc "c" (session: ls.Session, u: cstring, userdata: rawptr) -> c.int {
	s := (^Session)(userdata)
	set_user(s, u)
	if !allow(s, Auth_Request{user = user(s), method = .None, remote_addr = remote_addr(s)}) {
		return c.int(ls.Auth.Denied)
	}
	s.authenticated = true
	s.auth_method = "none"
	return c.int(ls.Auth.Success)
}

@(private)
cb_auth_password :: proc "c" (
	session: ls.Session,
	u, password: cstring,
	userdata: rawptr,
) -> c.int {
	s := (^Session)(userdata)
	set_user(s, u)
	req := Auth_Request {
		user        = user(s),
		method      = .Password,
		password    = string(password),
		remote_addr = remote_addr(s),
	}
	if !allow(s, req) {
		return c.int(ls.Auth.Denied)
	}
	s.authenticated = true
	s.auth_method = "password"
	return c.int(ls.Auth.Success)
}

@(private)
cb_auth_pubkey :: proc "c" (
	session: ls.Session,
	u: cstring,
	pubkey: ls.Key,
	signature_state: c.char,
	userdata: rawptr,
) -> c.int {
	s := (^Session)(userdata)
	set_user(s, u)

	// This callback fires twice per key. First with state None — "would you
	// accept this key?" — where the client has proven nothing and the key blob
	// is simply a claim anyone could make. Then with state Valid, after libssh
	// has verified a signature over the session id, which is unforgeable and
	// unreplayable to another server.
	//
	// We answer the probe with an unconditional yes and never show it to the
	// application. Two reasons: an unverified key must not drive any decision,
	// and saying yes ends the client's key enumeration at the first key.
	state := ls.Pubkey_State(i8(signature_state))
	if state != .Valid {
		if state == .None && .Publickey in s.server.methods {
			return c.int(ls.Auth.Success)
		}
		return c.int(ls.Auth.Denied)
	}

	// From here the key is proven. Only now does it become an identity.
	capture_key_identity(s, pubkey)
	derive_id(s)

	req := Auth_Request {
		user        = user(s),
		method      = .Publickey,
		fingerprint = fingerprint(s),
		key_type    = key_type(s),
		id          = id(s),
		remote_addr = remote_addr(s),
	}
	if !allow(s, req) {
		s.fp_len, s.kt_len, s.id_len = 0, 0, 0
		return c.int(ls.Auth.Denied)
	}

	s.authenticated = true
	s.auth_method = "publickey"
	return c.int(ls.Auth.Success)
}

@(private)
derive_id :: proc "contextless" (s: ^Session) {
	s.id_len = 0
	if !s.server.secret.loaded || s.fp_len == 0 {
		return
	}
	// pseudonym allocates nothing; the context is only for the crypto calls.
	context = runtime.default_context()
	s.id_len = len(pseudonym(&s.server.secret, fingerprint(s), s.id_buf[:]))
}

// Records the SHA256 fingerprint and key type into the session's fixed buffers.
@(private)
capture_key_identity :: proc "contextless" (s: ^Session, pubkey: ls.Key) {
	s.fp_len, s.kt_len = 0, 0
	if pubkey == nil {
		return
	}

	if name := ls.key_type_to_char(ls.key_type(pubkey)); name != nil {
		copy_cstr(s.kt_buf[:], &s.kt_len, name)
	}

	hash: [^]u8
	hlen: c.size_t
	if ls.get_publickey_hash(pubkey, .Sha256, &hash, &hlen) != ls.OK {
		return
	}
	defer ls.clean_pubkey_hash(&hash)

	if fp := ls.get_fingerprint_hash(.Sha256, hash, hlen); fp != nil {
		copy_cstr(s.fp_buf[:], &s.fp_len, fp)
		ls.string_free_char(fp)
	}
}

@(private)
copy_cstr :: proc "contextless" (dst: []u8, n: ^int, src: cstring) {
	p := ([^]u8)(rawptr(src))
	i := 0
	for i < len(dst) && p[i] != 0 {
		dst[i] = p[i]
		i += 1
	}
	n^ = i
}

@(private)
cb_channel_open :: proc "c" (session: ls.Session, userdata: rawptr) -> ls.Channel {
	s := (^Session)(userdata)
	if s.chan != nil {
		return nil // one channel per connection is plenty
	}
	ch := ls.channel_new(session)
	if ch == nil {
		return nil
	}
	// No channel_data_function here, deliberately: `read` is the input path's
	// single consumer and registering a data callback would make it fight
	// libssh's own buffer. The comment above `take_input` has the history.
	s.channel_cb = ls.Channel_Callbacks {
		size                               = size_of(ls.Channel_Callbacks),
		userdata                           = s,
		channel_eof_function               = cb_channel_eof,
		channel_close_function             = cb_channel_close,
		channel_pty_request_function       = cb_pty_request,
		channel_shell_request_function     = cb_shell_request,
		channel_pty_window_change_function = cb_window_change,
		channel_env_request_function       = cb_env_request,
		channel_exec_request_function      = cb_exec_request,
	}
	ls.set_channel_callbacks(ch, &s.channel_cb)
	s.chan = ch
	return ch
}

@(private)
cb_channel_eof :: proc "c" (session: ls.Session, channel: ls.Channel, userdata: rawptr) {
	s := (^Session)(userdata)
	s.eof = true
}

@(private)
cb_channel_close :: proc "c" (session: ls.Session, channel: ls.Channel, userdata: rawptr) {
	s := (^Session)(userdata)
	s.eof = true
}

@(private)
cb_pty_request :: proc "c" (
	session: ls.Session,
	channel: ls.Channel,
	term_name: cstring,
	width, height, pxwidth, pxheight: c.int,
	userdata: rawptr,
) -> c.int {
	s := (^Session)(userdata)
	if term_name != nil {
		copy_cstr(s.term_buf[:], &s.term_len, term_name)
	}

	s.pty = Pty {
		cols    = clamp(int(width), 1, MAX_PTY_COLS),
		rows    = clamp(int(height), 1, MAX_PTY_ROWS),
		px      = clamp(int(pxwidth), 0, 1 << 20),
		py      = clamp(int(pxheight), 0, 1 << 20),
		present = true,
	}
	// "Yes, you have a terminal." No actual pty is allocated — we just record
	// the geometry the client told us about.
	return ls.OK
}

@(private)
cb_shell_request :: proc "c" (session: ls.Session, channel: ls.Channel, userdata: rawptr) -> c.int {
	s := (^Session)(userdata)
	if !s.pty.present {
		return ls.ERROR // refuse non-interactive sessions
	}
	s.shell = true
	return ls.OK
}

@(private)
cb_window_change :: proc "c" (
	session: ls.Session,
	channel: ls.Channel,
	width, height, pxwidth, pxheight: c.int,
	userdata: rawptr,
) -> c.int {
	s := (^Session)(userdata)
	s.pty.cols = clamp(int(width), 1, MAX_PTY_COLS)
	s.pty.rows = clamp(int(height), 1, MAX_PTY_ROWS)
	s.pty.px = clamp(int(pxwidth), 0, 1 << 20)
	s.pty.py = clamp(int(pxheight), 0, 1 << 20)
	s.resized = true
	return ls.OK
}

@(private)
cb_env_request :: proc "c" (
	session: ls.Session,
	channel: ls.Channel,
	name, value: cstring,
	userdata: rawptr,
) -> c.int {
	return ls.OK
}

@(private)
cb_exec_request :: proc "c" (
	session: ls.Session,
	channel: ls.Channel,
	command: cstring,
	userdata: rawptr,
) -> c.int {
	return ls.ERROR // this server only speaks TUI
}
