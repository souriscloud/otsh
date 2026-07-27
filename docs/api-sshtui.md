# otsh:sshtui — API reference

The glue: adapts an `ssh.Session` into a `tui.Backend` and runs one `tui.Program` per connection.

Generated from `sshtui/*.odin` by `docs/tools/gen_api.py`. For how these fit together, see the hand-written guide ([sshtui](sshtui.md)).

## Contents

**Types** — [`Config`](#config), [`Create_Proc`](#create-proc), [`Destroy_Proc`](#destroy-proc), [`Info`](#info)

**Constants** — [`DEFAULT_FPS`](#default-fps)

**Procedures** — [`clone_info`](#clone-info), [`delete_info`](#delete-info), [`run_local`](#run-local), [`serve`](#serve)

## Types

### `Config`

```odin
Config :: struct {
	host:          string, // default ssh.DEFAULT_HOST ("0.0.0.0")
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
	// Read ssh.Authenticator's docs first — rejecting keys here enumerates the
	// client's agent. Authorize inside your app instead.
	authenticate:  ssh.Authenticator, // nil accepts everyone
	methods:       ssh.Auth_Methods, // zero means all
	on_connect:    proc(info: Info), // optional logging hooks
	on_disconnect: proc(info: Info),
}
```

How to serve your app. The zero value works: it serves on 0.0.0.0:2222 with a
generated host key at ./hostkey, at 30fps, accepting every client.

*sshtui/sshtui.odin:88*

### `Create_Proc`

```odin
Create_Proc :: #type proc(info: Info) -> tui.App
```

Called once per connection, on that connection's own thread.

*sshtui/sshtui.odin:79*

### `Destroy_Proc`

```odin
Destroy_Proc :: #type proc(app: tui.App)
```

Called after the app's loop ends. Free whatever `create` allocated.

*sshtui/sshtui.odin:81*

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

*sshtui/sshtui.odin:23*

## Constants

### `DEFAULT_FPS`

```odin
DEFAULT_FPS :: 30

// How to serve your app. The zero value works: it serves on 0.0.0.0:2222 with a
// generated host key at ./hostkey, at 30fps, accepting every client.
Config :: struct {
	host:          string, // default ssh.DEFAULT_HOST ("0.0.0.0")
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
	// Read ssh.Authenticator's docs first — rejecting keys here enumerates the
	// client's agent. Authorize inside your app instead.
	authenticate:  ssh.Authenticator, // nil accepts everyone
	methods:       ssh.Auth_Methods, // zero means all
	on_connect:    proc(info: Info), // optional logging hooks
	on_disconnect: proc(info: Info),
}
```

Frame rate used when `Config.fps` is zero.

*sshtui/sshtui.odin:84*

## Procedures

### `clone_info`

```odin
clone_info :: proc(info: Info, allocator := context.allocator) -> Info
```

Every string in an Info is borrowed from the connection that produced it.
They stay valid for the whole session — through `create`, the app loop,
`destroy` and `on_disconnect` — and are freed with the connection.

To keep any of them for longer (a roster keyed by `id`, an audit record, a
queue consumed by another thread), take an owned copy:

saved := sshtui.clone_info(info)
// ... later, when you are done with it:
sshtui.delete_info(saved)

The copy's `session` is nil: a cloned Info may outlive the connection, and a
session pointer that outlives its session is a dangling pointer.

*sshtui/sshtui.odin:54*

### `delete_info`

```odin
delete_info :: proc(info: Info, allocator := context.allocator)
```

Frees a value produced by clone_info. Never call it on an Info handed to
`create` — those strings belong to the connection.

*sshtui/sshtui.odin:69*

### `run_local`

```odin
run_local :: proc(cfg: Config) -> bool
```

Runs the same App against the local terminal. Handy during development:
one flag switches between `--local` and serving.

*sshtui/sshtui.odin:183*

### `serve`

```odin
serve :: proc(cfg: Config) -> bool
```

Blocks, serving connections until the process exits.

*sshtui/sshtui.odin:110*
