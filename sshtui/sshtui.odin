// sshtui — serve a `tui.App` over SSH.
//
// This is the glue between the two halves: it adapts an ssh.Session into a
// tui.Backend and runs one Program per connection. Your app code never
// mentions SSH, and the same App runs locally with `run_local`.
//
//	create :: proc(info: sshtui.Info) -> tui.App {
//	    m := new(My_Model)
//	    m.who = info.user
//	    return tui.App{data = m, update = update, view = view}
//	}
//	destroy :: proc(app: tui.App) { free(app.data) }
//
//	sshtui.serve({port = 2222, host_key_path = "hostkey", create = create, destroy = destroy})
package sshtui

import "core:os"
import "core:strings"
import "../ssh"
import "../tui"

// What an app is told about the client it is serving.
//
// Example:
//
//	create :: proc(info: sshtui.Info) -> tui.App {
//		m := new(Model)
//		m.who = info.user
//		return tui.App{data = m, update = update, view = view}
//	}
Info :: struct {
	user:        string, // username the client offered — unverified, they pick it
	term:        string, // $TERM, e.g. "xterm-256color"
	// Pseudonymous account id, present when `identity_secret` is configured and
	// the client used a key. This is what you store and key your data on.
	id:          string,
	// Raw SHA256 fingerprint of the verified key. Prefer `id`; persisting this
	// makes your database correlatable with every other service that saw the
	// same key. Useful for showing the user which key they connected with.
	fingerprint: string,
	key_type:    string, // "ssh-ed25519" etc., else ""
	auth_method: string, // "none" | "password" | "publickey" | "local"
	remote_addr: string, // numeric peer address, no reverse DNS
	cols, rows:  int, // initial geometry; use Resize msgs after that
	local:       bool, // true when running via run_local
	session:     ^ssh.Session, // escape hatch; nil when local
}

// Every string in an Info is borrowed from the connection that produced it.
// They stay valid for the whole session — through `create`, the app loop,
// `destroy` and `on_disconnect` — and are freed with the connection.
//
// To keep any of them for longer (a roster keyed by `id`, an audit record, a
// queue consumed by another thread), take an owned copy.
//
// Example:
//
//	saved := sshtui.clone_info(info)
//	// ... later, when you are done with it:
//	sshtui.delete_info(saved)
//
// The copy's `session` is nil: a cloned Info may outlive the connection, and a
// session pointer that outlives its session is a dangling pointer.
clone_info :: proc(info: Info, allocator := context.allocator) -> Info {
	out := info
	out.user = strings.clone(info.user, allocator)
	out.term = strings.clone(info.term, allocator)
	out.id = strings.clone(info.id, allocator)
	out.fingerprint = strings.clone(info.fingerprint, allocator)
	out.key_type = strings.clone(info.key_type, allocator)
	out.remote_addr = strings.clone(info.remote_addr, allocator)
	// auth_method is a string literal owned by the ssh package, not the session.
	out.session = nil
	return out
}

// Frees a value produced by clone_info. Never call it on an Info handed to
// `create` — those strings belong to the connection.
delete_info :: proc(info: Info, allocator := context.allocator) {
	delete(info.user, allocator)
	delete(info.term, allocator)
	delete(info.id, allocator)
	delete(info.fingerprint, allocator)
	delete(info.key_type, allocator)
	delete(info.remote_addr, allocator)
}

// Called once per connection, on that connection's own thread.
//
// Example:
//
//	create :: proc(info: sshtui.Info) -> tui.App {
//		return tui.App{data = new(Model), update = update, view = view}
//	}
//	destroy :: proc(app: tui.App) {free(app.data)}
Create_Proc :: #type proc(info: Info) -> tui.App
// Called after the app's loop ends. Free whatever `create` allocated.
Destroy_Proc :: #type proc(app: tui.App)

// Frame rate used when `Config.fps` is zero.
DEFAULT_FPS :: 30

// How to serve your app. The zero value works: it serves on [::]:2222 — one
// socket for IPv4 and IPv6 both, see `ssh.DEFAULT_HOST` — with a generated host
// key at ./hostkey, at 30fps, accepting every client.
//
// Example:
//
//	sshtui.serve(sshtui.Config{
//		port          = 2222,
//		host_key_path = "hostkey",
//		create        = create,
//		destroy       = destroy,
//	})
Config :: struct {
	host:          string, // default ssh.DEFAULT_HOST ("::", IPv4 and IPv6)
	port:          int, // default ssh.DEFAULT_PORT (2222)
	host_key_path: string, // default ssh.DEFAULT_HOST_KEY ("hostkey"); generated if missing
	create:        Create_Proc,
	destroy:       Destroy_Proc,
	fps:           int, // default DEFAULT_FPS (30)
	mouse:         bool, // request mouse reporting
	// Enables Info.id. Path to a per-server secret, created on first run.
	// Without it, Info.id is always "" and you have no stable account id.
	identity_secret: string,
	// Resource limits; per field 0 = default, negative = unlimited.
	limits:        ssh.Limits,
	// Seconds to wait for connected apps to finish when the server is stopping,
	// so each one restores its client's terminal instead of having it cut off.
	// 0 uses ssh.DEFAULT_SHUTDOWN_SECONDS.
	shutdown_seconds: int,
	// By default the server stops cleanly on SIGINT/SIGTERM. Set this if the
	// surrounding program handles signals itself.
	no_signal_handlers: bool,
	// Read ssh.Authenticator's docs first — rejecting keys here enumerates the
	// client's agent. Authorize inside your app instead.
	authenticate:  ssh.Authenticator, // nil accepts everyone
	methods:       ssh.Auth_Methods, // zero means all
	// Machine-readable audit log of listens, accepts, limiter rejections, auth
	// attempts and sessions. nil — the zero value — records nothing, which is
	// deliberate: every audit line carries the client's numeric address, so
	// logging it is a privacy decision the operator makes on purpose.
	// `ssh.audit_stderr` is a ready-made sink; its line format is documented in
	// `ssh/audit.odin`. Unlike the hooks below, it also sees the connections
	// that never became sessions.
	audit:         ssh.Audit_Sink,
	on_connect:    proc(info: Info), // optional logging hooks
	on_disconnect: proc(info: Info),
}

// Blocks, serving connections until the process exits.
//
// Example:
//
//	sshtui.serve(sshtui.Config{create = create, destroy = destroy})
serve :: proc(cfg: Config) -> bool {
	// Heap-allocated so every session thread can reach it through user_data,
	// rather than through a package global.
	c := new(Config)
	c^ = cfg
	// host/port/host_key_path are defaulted by ssh.serve; mirrored here only so
	// Config reads back the values actually in use.
	if c.host == "" {c.host = ssh.DEFAULT_HOST}
	if c.port == 0 {c.port = ssh.DEFAULT_PORT}
	if c.host_key_path == "" {c.host_key_path = ssh.DEFAULT_HOST_KEY}
	if c.fps == 0 {c.fps = DEFAULT_FPS}

	return ssh.serve(
		ssh.Config {
			host = c.host,
			port = c.port,
			host_key_path = c.host_key_path,
			authenticate = c.authenticate,
			methods = c.methods,
			identity_secret = c.identity_secret,
			limits = c.limits,
			audit = c.audit,
			shutdown_seconds = c.shutdown_seconds,
			no_signal_handlers = c.no_signal_handlers,
			handler = on_session,
			user_data = c,
		},
	)
}

@(private)
on_session :: proc(s: ^ssh.Session) {
	cfg := (^Config)(s.user_data)
	if cfg == nil || cfg.create == nil {
		return
	}

	cols, rows := ssh.size(s)
	info := Info {
		user        = ssh.user(s),
		term        = ssh.term(s),
		id          = ssh.id(s),
		fingerprint = ssh.fingerprint(s),
		key_type    = ssh.key_type(s),
		auth_method = s.auth_method,
		remote_addr = ssh.remote_addr(s),
		cols        = cols,
		rows        = rows,
		session     = s,
	}
	if cfg.on_connect != nil {cfg.on_connect(info)}
	defer if cfg.on_disconnect != nil {cfg.on_disconnect(info)}

	app := cfg.create(info)
	defer if cfg.destroy != nil {cfg.destroy(app)}

	p: tui.Program
	p.backend = tui.Backend {
		data  = s,
		write = proc(data: rawptr, buf: []u8) -> int {
			return ssh.write((^ssh.Session)(data), buf)
		},
		poll  = proc(data: rawptr, buf: []u8, timeout_ms: int) -> (n: int, ok: bool) {
			return ssh.read((^ssh.Session)(data), buf, timeout_ms)
		},
		size  = proc(data: rawptr) -> (cols, rows: int) {
			return ssh.size((^ssh.Session)(data))
		},
	}
	p.fps = cfg.fps
	p.mouse = cfg.mouse
	tui.run(&p, app)
}

// Runs the same App against the local terminal. Handy during development:
// one flag switches between `--local` and serving.
//
// Example:
//
//	cfg := sshtui.Config{create = create, destroy = destroy}
//	if local {
//		sshtui.run_local(cfg)
//	} else {
//		sshtui.serve(cfg)
//	}
run_local :: proc(cfg: Config) -> bool {
	l: tui.Local
	if !tui.local_enter_raw(&l) {
		return false // stdin is not a terminal
	}
	defer tui.local_exit_raw(&l)

	backend := tui.local_backend(&l)
	cols, rows := backend.size(backend.data)

	ub, tb: [64]u8
	info := Info {
		user        = os.get_env_buf(ub[:], "USER"),
		term        = os.get_env_buf(tb[:], "TERM"),
		auth_method = "local",
		cols        = cols,
		rows        = rows,
		local       = true,
	}
	if cfg.create == nil {
		return false
	}
	app := cfg.create(info)
	defer if cfg.destroy != nil {cfg.destroy(app)}

	p: tui.Program
	p.backend = backend
	p.fps = cfg.fps == 0 ? DEFAULT_FPS : cfg.fps
	p.mouse = cfg.mouse
	tui.run(&p, app)
	return true
}
