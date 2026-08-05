# otsh:sshtui — API reference

The glue: adapts an `ssh.Session` into a `tui.Backend` and runs one `tui.Program` per connection.

Generated from `sshtui/*.odin` by `docs/tools/gen_api.py`. For how these fit together, see the hand-written guide ([sshtui](sshtui.md)).

## Contents

**Types** — [`Config`](#config), [`Create_Proc`](#create-proc), [`Destroy_Proc`](#destroy-proc), [`Info`](#info)

**Constants** — [`DEFAULT_FPS`](#default-fps), [`VERSION`](#version), [`VERSION_MAJOR`](#version-major), [`VERSION_MINOR`](#version-minor), [`VERSION_PATCH`](#version-patch)

**Procedures** — [`clone_info`](#clone-info), [`delete_info`](#delete-info), [`run_local`](#run-local), [`serve`](#serve)

## Types

### `Config`

```odin
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
```

How to serve your app. The zero value works: it serves on [::]:2222 — one
socket for IPv4 and IPv6 both, see `ssh.DEFAULT_HOST` — with a generated host
key at ./hostkey, at 30fps, accepting every client.

Example:

```odin
sshtui.serve(sshtui.Config{
	port          = 2222,
	host_key_path = "hostkey",
	create        = create,
	destroy       = destroy,
})
```

*[sshtui/sshtui.odin:115](../sshtui/sshtui.odin#L115)*

### `Create_Proc`

```odin
Create_Proc :: #type proc(info: Info) -> tui.App
```

Called once per connection, on that connection's own thread.

Example:

```odin
create :: proc(info: sshtui.Info) -> tui.App {
	return tui.App{data = new(Model), update = update, view = view}
}
destroy :: proc(app: tui.App) {free(app.data)}
```

*[sshtui/sshtui.odin:96](../sshtui/sshtui.odin#L96)*

### `Destroy_Proc`

```odin
Destroy_Proc :: #type proc(app: tui.App)
```

Called after the app's loop ends. Free whatever `create` allocated.

*[sshtui/sshtui.odin:98](../sshtui/sshtui.odin#L98)*

### `Info`

```odin
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
```

What an app is told about the client it is serving.

Example:

```odin
create :: proc(info: sshtui.Info) -> tui.App {
	m := new(Model)
	m.who = info.user
	return tui.App{data = m, update = update, view = view}
}
```

*[sshtui/sshtui.odin:31](../sshtui/sshtui.odin#L31)*

## Constants

### `DEFAULT_FPS`

```odin
DEFAULT_FPS :: 30
```

Frame rate used when `Config.fps` is zero.

*[sshtui/sshtui.odin:101](../sshtui/sshtui.odin#L101)*

### `VERSION`

```odin
VERSION :: ssh.VERSION
```

The version as a string, for banners and log lines.

*[sshtui/version.odin:15](../sshtui/version.odin#L15)*

### `VERSION_MAJOR`

```odin
VERSION_MAJOR :: ssh.VERSION_MAJOR
```

*[sshtui/version.odin:11](../sshtui/version.odin#L11)*

### `VERSION_MINOR`

```odin
VERSION_MINOR :: ssh.VERSION_MINOR
```

*[sshtui/version.odin:12](../sshtui/version.odin#L12)*

### `VERSION_PATCH`

```odin
VERSION_PATCH :: ssh.VERSION_PATCH
```

*[sshtui/version.odin:13](../sshtui/version.odin#L13)*

## Procedures

### `clone_info`

```odin
clone_info :: proc(info: Info, allocator := context.allocator) -> Info
```

Every string in an Info is borrowed from the connection that produced it.
They stay valid for the whole session — through `create`, the app loop,
`destroy` and `on_disconnect` — and are freed with the connection.

To keep any of them for longer (a roster keyed by `id`, an audit record, a
queue consumed by another thread), take an owned copy.

Example:

```odin
saved := sshtui.clone_info(info)
// ... later, when you are done with it:
sshtui.delete_info(saved)
```

The copy's `session` is nil: a cloned Info may outlive the connection, and a
session pointer that outlives its session is a dangling pointer.

*[sshtui/sshtui.odin:64](../sshtui/sshtui.odin#L64)*

### `delete_info`

```odin
delete_info :: proc(info: Info, allocator := context.allocator)
```

Frees a value produced by clone_info. Never call it on an Info handed to
`create` — those strings belong to the connection.

*[sshtui/sshtui.odin:79](../sshtui/sshtui.odin#L79)*

### `run_local`

```odin
run_local :: proc(cfg: Config) -> bool
```

Runs the same App against the local terminal. Handy during development:
one flag switches between `--local` and serving.

Example:

```odin
cfg := sshtui.Config{create = create, destroy = destroy}
if local {
	sshtui.run_local(cfg)
} else {
	sshtui.serve(cfg)
}
```

*[sshtui/sshtui.odin:241](../sshtui/sshtui.odin#L241)*

### `serve`

```odin
serve :: proc(cfg: Config) -> bool
```

Blocks, serving connections until the process exits.

Example:

```odin
sshtui.serve(sshtui.Config{create = create, destroy = destroy})
```

*[sshtui/sshtui.odin:156](../sshtui/sshtui.odin#L156)*
