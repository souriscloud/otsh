# sshtui — serving a TUI over SSH

`sshtui` is the glue package: it adapts an `ssh.Session` into a `tui.Backend`
and runs one `tui.Program` per connection. This is the piece that plays the
role of Charm's [`wish`](https://github.com/charmbracelet/wish) bridging to
[`bubbletea`](https://github.com/charmbracelet/bubbletea) — your `update`/`view`
code never imports `otsh:ssh` and never learns whether the bytes it is reading
came off a socket or off your own terminal.

Concretely, `sshtui` does three things:

- turns each accepted, authenticated `ssh.Session` into a `tui.Backend` (its
  `write`, `poll`, and `size` are just `ssh.write`, `ssh.read`, `ssh.size`
  closed over that session)
- builds an `Info` describing the client and hands it to a `Create_Proc` you
  supply, which returns the `tui.App` for that connection
- runs `tui.run` against that backend and app until the app quits or the
  connection drops, then calls your `Destroy_Proc`

If you have not read `tui`'s own docs, the short version: an `App` is a
`data: rawptr` plus an `update` and a `view` proc, Elm-style — `update` reacts
to `tui.Msg` (`Key`, `Mouse`, `Resize`, `Tick`), `view` repaints a `tui.Screen`
every frame. `sshtui` never touches either; it only supplies the backend they
run against.

## Overview

Three things to know before anything else:

- `create` is called once per connection and returns the `tui.App` for it.
- `destroy` is called once, after that connection's app loop ends, to free
  whatever `create` allocated.
- `serve` blocks — it accepts connections until the server is asked to stop
  (`Ctrl+C`, `SIGTERM`, or `ssh.shutdown`).

A complete minimal program:

<!-- check:file -->
```odin
package main

import "core:fmt"
import "otsh:sshtui"
import "otsh:tui"

Model :: struct {
	count: int,
}

update :: proc(p: ^tui.Program, msg: tui.Msg) {
	m := (^Model)(p.app.data)
	#partial switch k in msg {
	case tui.Key:
		#partial switch k.kind {
		case .Up:   m.count += 1
		case .Down: m.count -= 1
		case .Esc:  tui.quit(p)
		}
	}
}

view :: proc(p: ^tui.Program, s: ^tui.Screen) {
	m := (^Model)(p.app.data)
	tui.draw_box(s, 2, 1, 30, 5, tui.Style{fg = tui.ansi(6)}, tui.BORDER_ROUND, " demo ")
	tui.draw_text(s, 4, 3, fmt.tprintf("count: %d", m.count), tui.Style{attrs = {.Bold}})
}

create :: proc(info: sshtui.Info) -> tui.App {
	return tui.App{data = new(Model), update = update, view = view}
}

destroy :: proc(app: tui.App) {
	free(app.data)
}

main :: proc() {
	sshtui.serve(sshtui.Config{
		port          = 2222,
		host_key_path = "hostkey", // generated on first run
		create        = create,
		destroy       = destroy,
	})
}
```

`ssh -p 2222 localhost` connects to it. Nothing above mentions SSH except the
`Info` type `create` receives and the `Config` passed to `serve`.

## `Config`

<!-- check:verbatim sshtui/sshtui.odin -->
```odin
Config :: struct {
	host:          string, // default "0.0.0.0"
	port:          int, // default 2222
	host_key_path: string, // default "./hostkey"; generated if missing
	create:        Create_Proc,
	destroy:       Destroy_Proc,
	fps:           int, // default 30
	mouse:         bool, // request mouse reporting
	identity_secret: string,
	limits:        ssh.Limits,
	shutdown_seconds: int, // default ssh.DEFAULT_SHUTDOWN_SECONDS (5)
	no_signal_handlers: bool, // set if the program handles signals itself
	authenticate:  ssh.Authenticator, // nil accepts everyone
	methods:       ssh.Auth_Methods, // zero means all
	audit:         ssh.Audit_Sink, // nil records nothing
	on_connect:    proc(info: Info), // optional logging hooks
	on_disconnect: proc(info: Info),
}
```

Every field left at its zero value falls back to a documented default; nothing
about `Config{create = create}` alone is an error, it just serves on
`0.0.0.0:2222` with a host key file called `hostkey` in the working directory.

| Field | Zero value means | Notes |
| --- | --- | --- |
| `host` | `"0.0.0.0"` | Bind address, resolved in `serve`. |
| `port` | `2222` | |
| `host_key_path` | `"hostkey"` | Created on first run if it does not exist (`ssh.ensure_host_key`). Clients pin this in `known_hosts`, so keep it stable across restarts — back it up. |
| `create` | connection is accepted, then silently dropped | Effectively required. `serve` checks `cfg.create == nil` per session and returns without running anything; `run_local` returns `false`. |
| `destroy` | nothing runs after the app loop ends | Only called if non-nil. If `create` allocates, set this or you leak. |
| `fps` | `30` | Frame budget for `tui.run`; also paces how often `poll` is given a chance to return. |
| `mouse` | mouse reporting off | Passed straight through to `tui.Program.mouse`. |
| `identity_secret` | `Info.id` is always `""` | Path to a per-server secret file, created `0600` on first run if missing. Enables `Info.id`. See [./security.md](./security.md). |
| `limits` | `ssh.DEFAULT_LIMITS` | `ssh.Limits`: max concurrent sessions, max per source IP, handshake timeout, max failed auth attempts. Per field, `0` takes the default and a negative value disables that one limit. |
| `shutdown_seconds` | `ssh.DEFAULT_SHUTDOWN_SECONDS` (5) | How long `serve` waits for connected apps to finish once the server is stopping, so each one restores its client's terminal instead of having it cut off. Negative returns immediately. |
| `no_signal_handlers` | `serve` stops cleanly on `SIGINT`/`SIGTERM` | Set it when the surrounding program owns signal handling; then stop the server with `ssh.shutdown`. |
| `authenticate` | everyone is accepted | `ssh.Authenticator`. Read its doc comment before setting one — rejecting a public key here makes the client offer its next one, which lets a rejecting server enumerate every key in the client's agent. Prefer authorizing inside your app with `Info.id`, as in `examples/members/main.odin`. See [./security.md](./security.md). |
| `methods` | all of `ssh.ALL_AUTH` (`.None`, `.Password`, `.Publickey`) are offered | If you depend on `Info.id`, set this to `{.Publickey}` — every OpenSSH client tries `.None` first, and if the server accepts it the client never offers a key at all, so `Info.id` stays empty. |
| `audit` | nothing is recorded | `ssh.Audit_Sink`, passed straight through to `ssh.Config.audit`. `ssh.audit_stderr` writes one machine-parseable line per listen, accept, limiter rejection, key-exchange failure, auth attempt and session. Opt-in because every line carries the client's numeric address. Unlike the hooks below it also sees connections that never became sessions. Format: [./ssh.md](./ssh.md#audit). |
| `on_connect` | no hook runs | See "Connection hooks" below. |
| `on_disconnect` | no hook runs | |

`shutdown_seconds` and `no_signal_handlers` are the two knobs on graceful
shutdown, which you get without asking for it: `Ctrl+C` on the server stops
the accept loop and closes each session's *input*, so every app takes its
ordinary teardown path — the same one a user pressing `q` takes — and restores
its client's terminal instead of stranding it in the alternate screen. `serve`
returns once they are all gone, or once `shutdown_seconds` runs out. The
mechanism, the deadline, and how to stop a server from inside your own code
(`ssh.shutdown`, from `otsh:ssh`) are covered in
[./ssh.md](./ssh.md#shutdown).

## `Info`

What `create` (and the connect/disconnect hooks) are told about the client:

<!-- check:verbatim sshtui/sshtui.odin -->
```odin
Info :: struct {
	user:        string, // username the client offered — unverified, they pick it
	term:        string, // $TERM, e.g. "xterm-256color"
	id:          string,
	fingerprint: string,
	key_type:    string, // "ssh-ed25519" etc., else ""
	auth_method: string, // "none" | "password" | "publickey" | "local"
	remote_addr: string, // numeric peer address, no reverse DNS
	cols, rows:  int, // initial geometry; use Resize msgs after that
	local:       bool, // true when running via run_local
	session:     ^ssh.Session, // escape hatch; nil when local
}
```

How much to trust each field:

| Field | Trust level | Detail |
| --- | --- | --- |
| `user` | Unverified | Whatever the client typed after `ssh user@host` or passed with `-l`. They choose it freely — an SSH username is not an authentication mechanism. Never use it as an identity or a lookup key. |
| `term` | Unverified | Client-reported `$TERM`. Cosmetic only. |
| `id` | Trustworthy, but conditionally present | `HMAC-SHA256(identity_secret, fingerprint)`, truncated to 128 bits. Empty unless **both** `Config.identity_secret` is set **and** the client authenticated with a key (never with `.None` or `.Password`). This is the field to store and to key application data on. Compare with `ssh.ids_equal`, not `==`, to avoid leaking timing information about where a comparison differed. |
| `fingerprint` | Trustworthy, but only from a verified key | `"SHA256:…"` of the public key. Only ever set after libssh has verified a signature over the session identifier — the unverified "probe" step of public-key auth (RFC 4252 §7) never reaches application code at all. Prefer `id` for storage: a raw fingerprint is a durable, correlatable identifier across every other service that has seen the same key. |
| `key_type` | Same guarantee as `fingerprint` | e.g. `"ssh-ed25519"`. Empty when the client did not authenticate with a key. |
| `auth_method` | Trustworthy (server-decided) | One of `"none"`, `"password"`, `"publickey"`, `"local"`. This reflects what actually succeeded, not what the client claimed. |
| `remote_addr` | Trustworthy (from the socket) | Numeric peer address. No reverse DNS is ever performed — that would leak every connection to a resolver and block a thread doing it. |
| `cols`, `rows` | Trustworthy, but a snapshot | Geometry at connect time only; the client can resize afterward, so track `tui.Resize` messages in `update`, not this field, for anything ongoing. |
| `local` | Trustworthy | `true` only when the app is running under `run_local`; always `false` over SSH. |
| `session` | Escape hatch | The underlying `^ssh.Session`, for reaching `otsh:ssh` procs `sshtui` does not wrap. `nil` when `local` is `true` — do not dereference it without checking `local` first. |

The identity story — why `id` exists, how it is derived, and why it is safer
to store than `fingerprint` — is covered in full in
[./security.md](./security.md).

## `Create_Proc`, `Destroy_Proc`, and the connection lifecycle

<!-- check:verbatim sshtui/sshtui.odin -->
```odin
// Called once per connection, on that connection's own thread.
Create_Proc :: #type proc(info: Info) -> tui.App
// Called after the app's loop ends. Free whatever `create` allocated.
Destroy_Proc :: #type proc(app: tui.App)
```

Each accepted TCP connection gets its own OS thread in `otsh:ssh`
(`thread.create_and_start_with_poly_data` in `ssh/server.odin`), and that same
thread runs the whole session end to end: key exchange, authentication, pty
and shell negotiation, and then — once all of that has succeeded — the
`sshtui` handler. Concretely, for one connection, in order:

1. `ssh` finishes the handshake, authenticates the client, and waits for a
   channel open plus a shell request. `create` never sees a connection that
   did not get this far.
2. `cfg.on_connect(info)` runs, if set.
3. `cfg.create(info)` runs and returns the `tui.App`.
4. `tui.run` drives that `App` against the SSH channel until the app calls
   `tui.quit` or the connection drops (`poll` reports `ok == false`). This is
   the bulk of the connection's lifetime.
5. `cfg.destroy(app)` runs, if set.
6. `cfg.on_disconnect(info)` runs, if set.

Because step 1 already requires authentication and a shell request, `create`
is never called for a connection that never sent real keystrokes — it is not
called during the public-key "probe" (the unsigned first message of RFC 4252
§7 public-key auth), only after a full session is ready to run.

### Info string lifetime

Every string in an `Info` is borrowed from the connection that produced it.
They are valid for all six steps above — `create`, the app loop, `destroy`,
`on_disconnect` — and are freed with the connection. `fingerprint` and `id` are
additionally zeroed on teardown, so a stale pointer reads as blanks rather than
plausible-looking garbage.

That covers almost everything an app does. To keep any of it for longer — a
roster keyed by `id`, an audit record, a work item handed to another thread —
take an owned copy:

<!-- check:skip signature fragment; `Info` is defined above, bodies in sshtui/sshtui.odin -->
```odin
clone_info  :: proc(info: Info, allocator := context.allocator) -> Info
delete_info :: proc(info: Info, allocator := context.allocator)
```

<!-- check:skip usage sketch with a "// ..." elision, referencing an `info` from surrounding context -->
```odin
saved := sshtui.clone_info(info)   // survives the connection
// ...
sshtui.delete_info(saved)          // when you are done with it
```

The clone's `session` is deliberately `nil`: a cloned `Info` may outlive the
connection, and a session pointer that outlives its session is a dangling
pointer.

Never call `delete_info` on an `Info` handed to `create` — those strings belong
to the connection, not to you. If you only need one field, `strings.clone` on
that field is cheaper than cloning the whole struct; `examples/members` does
exactly that for its roster key.

**`create` and `destroy` run concurrently across connections.** There is no
global lock around them — every connection has its own thread, and libssh
callbacks for that connection fire only on that thread, so nothing needs
locking *within* one session. But if `create`/`destroy`/`update`/`view` touch
anything shared across sessions — a roster, a database handle, a counter — that
shared state needs its own synchronization. `examples/members/main.odin` shows
the pattern: a package-level `roster: map[string]Member` guarded by a
`sync.Mutex`, locked for the duration of each lookup or insert.

## `serve` and `run_local`

<!-- check:skip signature fragment; `Config` is defined above, bodies in sshtui/sshtui.odin -->
```odin
serve :: proc(cfg: Config) -> bool
run_local :: proc(cfg: Config) -> bool
```

`serve` opens the listening socket, ensures the host key exists, and blocks,
handing off one thread per connection. It returns `false` if setup failed —
the host key could not be generated or validated, or the port could not be
bound. Otherwise it returns `true` after a `SIGINT`/`SIGTERM` or an
`ssh.shutdown` has stopped the accept loop and the connected sessions have
drained (see [./ssh.md](./ssh.md#shutdown)).

`run_local` runs the identical `App` — same `create`, same `update`, same
`view` — against the developer's own terminal instead of a network
connection. It puts the terminal into raw mode, wraps it in a `tui.Backend`,
builds an `Info` with `user`/`term` read from the `USER`/`TERM` environment
variables, `auth_method = "local"`, `local = true`, and `session = nil`, then
runs the same `tui.run` loop `serve` would have. It returns `false` — without
running anything — when standard input is not a terminal (so it fails cleanly
if piped or run from a non-interactive context), or if `cfg.create` is `nil`.

The usual reason to call it is a `--local` flag, so the same binary either
serves or runs in-terminal depending on how it is invoked. That is the whole
of it, from the end of `main` in `examples/tracker/main.odin`:

<!-- check:verbatim examples/tracker/main.odin -->
```odin
for arg in os.args[1:] {
	if arg == "--local" || arg == "-l" {
		if !sshtui.run_local(cfg) {
			fmt.eprintln("tracker: stdin is not a terminal")
			os.exit(1)
		}
		return
	}
}
if !sshtui.serve(cfg) {
	os.exit(1)
}
```

The same `sshtui.Config` value is used for both calls — nothing about `create`,
`destroy`, `fps`, or `mouse` differs between serving and running locally.

## Connection hooks

<!-- check:verbatim sshtui/sshtui.odin -->
```odin
on_connect:    proc(info: Info),
on_disconnect: proc(info: Info),
```

Both are optional and exist for side effects like logging — they run in
addition to, not instead of, `create`/`destroy`, and per the lifecycle above,
`on_connect` fires before `create` while `on_disconnect` fires after
`destroy`. `examples/members/main.odin` uses `on_connect` for exactly this:

<!-- check:verbatim examples/members/main.odin -->
```odin
connected :: proc(info: sshtui.Info) {
	// Log the pseudonymous id, never the fingerprint or the key.
	fmt.printfln("members: session id=%s auth=%s", info.id, info.auth_method)
}
```

Log `info.id`, not `info.fingerprint`, and never a raw key. A fingerprint is
stable and global — it correlates your logs with any other service that saw
the same key — while `id` is meaningless outside your own server. See
[./security.md](./security.md) for why.

These hooks only see connections that got as far as a session. If you want the
ones that did not — rejections, failed key exchanges, refused authentication —
set `Config.audit` instead: `ssh.audit_stderr` writes one parseable line per
event and already logs `id` rather than the fingerprint. The two compose; a
hook is for your application's own record, `audit` for the operator's.

## Worked example: per-user state from `Info.id`

A shorter version of the `examples/members` pattern: greet a returning client
by a visit count keyed on their pseudonymous id, guarding the shared map with
a mutex since `create` runs on a different thread per connection.

<!-- check:file -->
```odin
package main

import "core:fmt"
import "core:sync"
import "otsh:sshtui"
import "otsh:tui"

visits:    map[string]int
visits_mu: sync.Mutex

// Called from many connection threads at once — same reasoning as the
// `roster_mu` lock around examples/members' roster.
bump :: proc(id: string) -> int {
	if id == "" {
		return 0 // identity_secret unset, or client didn't authenticate with a key
	}
	sync.lock(&visits_mu)
	defer sync.unlock(&visits_mu)
	visits[id] += 1
	return visits[id]
}

State :: struct {
	n: int,
}

update :: proc(p: ^tui.Program, msg: tui.Msg) {
	#partial switch m in msg {
	case tui.Key:
		if m.kind == .Esc || (m.kind == .Rune && m.r == 'q') {
			tui.quit(p)
		}
	}
}

view :: proc(p: ^tui.Program, s: ^tui.Screen) {
	defer free_all(context.temp_allocator)
	st := (^State)(p.app.data)
	tui.draw_box(s, 2, 1, 34, 5, tui.Style{fg = tui.ansi(6)}, tui.BORDER_ROUND, " welcome back ")
	tui.draw_text(s, 4, 3, fmt.tprintf("visit #%d", st.n), tui.Style{attrs = {.Bold}})
	tui.draw_text(s, 4, 4, "q to quit", tui.Style{fg = tui.ansi(8)})
}

create :: proc(info: sshtui.Info) -> tui.App {
	st := new(State)
	st.n = bump(info.id)
	return tui.App{data = st, update = update, view = view}
}

destroy :: proc(app: tui.App) {
	free(app.data)
}

main :: proc() {
	visits = make(map[string]int)
	sshtui.serve(sshtui.Config{
		port            = 2224,
		host_key_path   = "greeter_hostkey",
		identity_secret = "greeter_secret", // enables Info.id
		methods         = {.Publickey}, // required so a key is always offered
		create          = create,
		destroy         = destroy,
	})
}
```

Connecting twice with the same key reports `visit #1` and `visit #2`;
connecting with a different key starts back at `visit #1`. Without
`methods = {.Publickey}`, an OpenSSH client's first attempt is the `.None`
method, which this server would accept by default — no key would ever be
offered, and `info.id` would stay `""` on every connection.

## When not to use `sshtui`

Use `otsh:ssh` directly, without `sshtui`, when you want the SSH transport but
not a `tui.Program` driving the channel — a line-oriented prompt, or a raw
protocol answered over the same "bytes in are keystrokes, bytes out are what
you send" channel, without a screen-diffing renderer in between. `ssh.serve`
takes a `Handler :: #type proc(s: ^Session)` directly, and you get
`ssh.read`/`ssh.write`/`ssh.size` to build your own loop on. Note that this
`ssh` package's server still only ever answers `pty-req` and `shell` —
`exec` and `subsystem` channel requests are refused unconditionally — so it
remains a TUI-shaped server either way, just without `tui`'s renderer on top.
See [./ssh.md](./ssh.md).

Use `otsh:tui` alone, without `ssh` or `sshtui`, for a program that only ever
runs in the operator's own terminal — a local full-screen CLI tool with no
network component at all. `tui.run` takes any `tui.Backend`; `sshtui` is one
way to obtain one (over a network), but `tui.local_backend` gets you one over
the calling terminal directly, with no SSH code linked in. See
[./tui.md](./tui.md).
