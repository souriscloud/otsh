# otsh:ssh — API reference

The SSH server: bind, handshake, auth, pty and shell requests, then a byte stream. No dependency on `tui`.

Generated from `ssh/*.odin` by `docs/tools/gen_api.py`. For how these fit together, see the hand-written guide ([ssh](ssh.md)).

## Contents

**Types** — [`Auth_Method`](#auth-method), [`Auth_Methods`](#auth-methods), [`Auth_Request`](#auth-request), [`Authenticator`](#authenticator), [`Config`](#config), [`Handler`](#handler), [`Identity_Secret`](#identity-secret), [`Limits`](#limits), [`Pty`](#pty), [`Ring`](#ring), [`Server`](#server), [`Session`](#session)

**Constants** — [`ALL_AUTH`](#all-auth), [`DEFAULT_CIPHERS`](#default-ciphers), [`DEFAULT_HOST`](#default-host), [`DEFAULT_HOST_KEY`](#default-host-key), [`DEFAULT_HOSTKEYS`](#default-hostkeys), [`DEFAULT_KEX`](#default-kex), [`DEFAULT_LIMITS`](#default-limits), [`DEFAULT_MACS`](#default-macs), [`DEFAULT_PORT`](#default-port), [`ID_BYTES`](#id-bytes), [`ID_SIZE`](#id-size), [`MAX_INPUT`](#max-input), [`MAX_PTY_COLS`](#max-pty-cols), [`MAX_PTY_ROWS`](#max-pty-rows), [`SECRET_SIZE`](#secret-size)

**Procedures** — [`ensure_host_key`](#ensure-host-key), [`fingerprint`](#fingerprint), [`id`](#id), [`ids_equal`](#ids-equal), [`key_type`](#key-type), [`load_or_create_secret`](#load-or-create-secret), [`pseudonym`](#pseudonym), [`read`](#read), [`remote_addr`](#remote-addr), [`ring_pop`](#ring-pop), [`ring_push`](#ring-push), [`serve`](#serve), [`size`](#size), [`take_resize`](#take-resize), [`term`](#term), [`user`](#user), [`warn_if_world_readable`](#warn-if-world-readable), [`write`](#write), [`write_string`](#write-string)

## Types

### `Auth_Method`

```odin
Auth_Method :: enum u8 {
	None,
	Password,
	Publickey,
}
```

The SSH authentication methods this server understands.

*ssh/server.odin:29*

### `Auth_Methods`

```odin
Auth_Methods :: distinct bit_set[Auth_Method;u8]
```

A set of `Auth_Method`. Note that offering `.None` means an OpenSSH client
authenticates before ever offering a key, leaving `Session.id` empty.

*ssh/server.odin:36*

### `Auth_Request`

```odin
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
```

What an `Authenticator` is told. For `.Publickey`, the key's signature has
already been verified — unverified probes never reach application code.

*ssh/server.odin:43*

### `Authenticator`

```odin
Authenticator :: #type proc(req: Auth_Request) -> bool
```

Return true to let the client in. A nil Authenticator accepts everyone.

READ THIS BEFORE USING IT. Rejecting a public key here does not just deny
access — it makes the client offer its *next* key, and the next, so a
rejecting server learns every public key in the user's agent. That is a real
fingerprinting vector and it is why this server accepts by default.

If you want a members-only app, do not reject here. Accept the key, take the
`id` from Info, and show non-members a "you are not on the list" screen
inside the app. They are equally excluded and you learn exactly one key.
See examples/members.

*ssh/server.odin:67*

### `Config`

```odin
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
	// Algorithm allow-lists, in libssh's comma-separated format. Empty means
	// the hardened defaults below; set to "-" to accept libssh's own defaults,
	// which are broader and include things like RSA/SHA-1-era compatibility.
	key_exchange:      string,
	ciphers:           string,
	macs:              string,
	hostkey_algorithms: string,
}
```

How to run the server. Every field has a documented default, so the zero value
is a working — if wide open — public server on port 2222.

*ssh/server.odin:307*

### `Handler`

```odin
Handler :: #type proc(s: ^Session)
```

Handler runs on its own thread, one per connection, and owns the session for
as long as it runs. When it returns the connection is torn down.

*ssh/server.odin:26*

### `Identity_Secret`

```odin
Identity_Secret :: struct {
	bytes:  [SECRET_SIZE]u8,
	loaded: bool,
}
```

The per-server HMAC key behind `Session.id`. Back it up with the host key:
losing it re-pseudonymises every user, so everyone looks new.

*ssh/identity.odin:30*

### `Limits`

```odin
Limits :: struct {
	// Total concurrent sessions.
	max_sessions:      int,
	// Concurrent sessions from one source address.
	max_per_ip:        int,
	// Seconds a client gets to complete key exchange and authentication before
	// the socket times out. Without this, a client that connects and then says
	// nothing holds a thread indefinitely.
	handshake_seconds: int,
	// Failed `Authenticator` verdicts after which this connection stops being
	// asked. It does NOT drop the connection, and it does NOT bound guessing
	// across connections: the counter lives on the Session, so a client that
	// reconnects gets a fresh budget. Measured at roughly 37 guesses/second from
	// one address against a rejecting Authenticator. If you accept passwords,
	// rate-limit them yourself — this is not that control.
	max_auth_attempts: int,
}
```

Per field: 0 means "use the default below", negative means "no limit".
That way the zero value of the whole struct is the safe default rather than
an accidental free-for-all, and you can still opt out of any single limit.

*ssh/limits.odin:16*

### `Pty`

```odin
Pty :: struct {
	term:    string, // borrowed from Session.term_buf
	cols:    int,
	rows:    int,
	px:      int,
	py:      int,
	present: bool,
}
```

The terminal geometry the client asked for. No pseudo-terminal is actually
allocated — this is just what the client told us about its own.

*ssh/server.odin:105*

### `Ring`

```odin
Ring :: struct {
	data:  [MAX_INPUT]u8,
	start: int,
	count: int,
}
```

Fixed-size byte ring for incoming keystrokes. Fixed so that libssh callbacks,
which run without an Odin context, never touch an allocator.

*ssh/server.odin:153*

### `Server`

```odin
Server :: struct {
	bind:         ls.Bind,
	handler:      Handler,
	authenticate: Authenticator,
	methods:      Auth_Methods,
	secret:       Identity_Secret,
	limiter:      Limiter,
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
	running:      bool,
	warned_enum:  bool, // one-shot enumeration warning; touched atomically
}
```

Server-wide state, shared by every connection. Internal; reach it through
`Session.server` only if you know what you are doing.

*ssh/server.odin:71*

### `Session`

```odin
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
	input:         Ring,
	user_data:     rawptr, // copied from Server.user_data for handler use
}
```

One connection. Created and freed by the accept loop; your `Handler` owns it
for the duration of the call. All its string accessors borrow memory that
dies with the session.

*ssh/server.odin:117*

## Constants

### `ALL_AUTH`

```odin
ALL_AUTH :: Auth_Methods{.None, .Password, .Publickey}
```

Every method. The default when `Config.methods` is left zero.

*ssh/server.odin:39*

### `DEFAULT_CIPHERS`

```odin
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
```

AEAD ciphers only: no CBC, no stream ciphers with separate MACs.

*ssh/server.odin:335*

### `DEFAULT_HOST`

```odin
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
```

Defaults applied to a zero-valued Config field. sshtui fills these in too;
they live here as well so calling ssh.serve directly cannot bind port 0.

*ssh/server.odin:451*

### `DEFAULT_HOST_KEY`

```odin
DEFAULT_HOST_KEY :: "hostkey"

// Binds, listens, and accepts connections until the process exits, spawning one
// thread per connection. Returns false if setup fails; otherwise blocks.
// Refuses to continue on a libssh too old to have the Terrapin fix. The check
// is at runtime, not compile time, because the shared library that gets loaded
// is not necessarily the one the bindings were compiled against.
@(private)
```

Host key path used when `Config.host_key_path` is empty.

*ssh/server.odin:455*

### `DEFAULT_HOSTKEYS`

```odin
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
```

Ed25519 only — matches the key `ensure_host_key` generates.

*ssh/server.odin:339*

### `DEFAULT_KEX`

```odin
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
```

Modern-only. Every one of these is an AEAD or an ETM MAC with a
curve25519 exchange; nothing here depends on SHA-1, CBC, or NIST curves.

*ssh/server.odin:333*

### `DEFAULT_LIMITS`

```odin
DEFAULT_LIMITS :: Limits {
	max_sessions      = 256,
	max_per_ip        = 8,
	handshake_seconds = 20,
	max_auth_attempts = 6,
}
```

Applied to any `Limits` field left at zero. Deliberately conservative — raise
them deliberately rather than discovering you had none.

*ssh/limits.odin:36*

### `DEFAULT_MACS`

```odin
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
```

Encrypt-then-MAC only, SHA-2 only.

*ssh/server.odin:337*

### `DEFAULT_PORT`

```odin
DEFAULT_PORT :: 2222
// Host key path used when `Config.host_key_path` is empty.
DEFAULT_HOST_KEY :: "hostkey"

// Binds, listens, and accepts connections until the process exits, spawning one
// thread per connection. Returns false if setup fails; otherwise blocks.
// Refuses to continue on a libssh too old to have the Terrapin fix. The check
// is at runtime, not compile time, because the shared library that gets loaded
// is not necessarily the one the bindings were compiled against.
@(private)
```

Port used when `Config.port` is zero.

*ssh/server.odin:453*

### `ID_BYTES`

```odin
ID_BYTES :: 16
// Length of a pseudonymous id as hex text.
ID_SIZE :: ID_BYTES * 2

// The per-server HMAC key behind `Session.id`. Back it up with the host key:
// losing it re-pseudonymises every user, so everyone looks new.
Identity_Secret :: struct {
	bytes:  [SECRET_SIZE]u8,
	loaded: bool,
}
```

128 bits of id. Collisions are not a practical concern and the shorter
string is easier to eyeball in logs.

*ssh/identity.odin:24*

### `ID_SIZE`

```odin
ID_SIZE :: ID_BYTES * 2

// The per-server HMAC key behind `Session.id`. Back it up with the host key:
// losing it re-pseudonymises every user, so everyone looks new.
Identity_Secret :: struct {
	bytes:  [SECRET_SIZE]u8,
	loaded: bool,
}
```

Length of a pseudonymous id as hex text.

*ssh/identity.odin:26*

### `MAX_INPUT`

```odin
MAX_INPUT :: 16 * 1024

// Handler runs on its own thread, one per connection, and owns the session for
// as long as it runs. When it returns the connection is torn down.
Handler :: #type proc(s: ^Session)
```

Per-session input buffer. Bytes beyond this stay in libssh's own buffer and
are re-offered later, which is the protocol's flow control.

*ssh/server.odin:22*

### `MAX_PTY_COLS`

```odin
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
```

Upper bounds on client-supplied terminal geometry, matching tui's own limits.
pty-req and window-change both carry uint32 dimensions chosen by the client;
unclamped they are an allocation-size overflow and a remote crash.

*ssh/server.odin:100*

### `MAX_PTY_ROWS`

```odin
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
```

*ssh/server.odin:101*

### `SECRET_SIZE`

```odin
SECRET_SIZE :: 32
// 128 bits of id. Collisions are not a practical concern and the shorter
// string is easier to eyeball in logs.
ID_BYTES :: 16
// Length of a pseudonymous id as hex text.
ID_SIZE :: ID_BYTES * 2

// The per-server HMAC key behind `Session.id`. Back it up with the host key:
// losing it re-pseudonymises every user, so everyone looks new.
Identity_Secret :: struct {
	bytes:  [SECRET_SIZE]u8,
	loaded: bool,
}
```

Length of the identity secret, in bytes.

*ssh/identity.odin:21*

## Procedures

### `ensure_host_key`

```odin
ensure_host_key :: proc(path: string, advertised := DEFAULT_HOSTKEYS) -> bool
```

Creates the host key if it does not exist yet — the SSH equivalent of a TLS
certificate. Clients pin it in ~/.ssh/known_hosts, so it must be stable
across restarts.

*ssh/server.odin:344*

### `fingerprint`

```odin
fingerprint :: proc "contextless" (s: ^Session) -> string
```

SHA256 fingerprint of the key the client authenticated with, or "" if they
did not use one. Stable across connections — use it as an account id.

*ssh/server.odin:195*

### `id`

```odin
id :: proc "contextless" (s: ^Session) -> string
```

Pseudonymous account id: HMAC(server secret, fingerprint). Empty unless an
identity secret is configured and the client used a key. Store this, not the
fingerprint. See identity.odin.

*ssh/server.odin:208*

### `ids_equal`

```odin
ids_equal :: proc "contextless" (a, b: string) -> bool
```

Compares two ids without leaking where they differ via timing. Use this
rather than `==` when checking an id against a stored one.

*ssh/identity.odin:97*

### `key_type`

```odin
key_type :: proc "contextless" (s: ^Session) -> string
```

The verified key's algorithm, e.g. "ssh-ed25519". Empty unless public-key
auth was used.

*ssh/server.odin:201*

### `load_or_create_secret`

```odin
load_or_create_secret :: proc(path: string) -> (secret: Identity_Secret, ok: bool)
```

Loads the secret from `path`, creating it on first run. Treat this file
exactly like the host key: back it up, keep it 0600, never commit it.
Losing it does not leak anything — it just re-pseudonymises everybody, which
means every user looks like a new user.

*ssh/identity.odin:39*

### `pseudonym`

```odin
pseudonym :: proc(secret: ^Identity_Secret, fingerprint: string, dst: []u8) -> string
```

Stable per-server id for a verified key fingerprint. Writes into `dst`
(needs ID_SIZE bytes) and returns a string viewing it, so this allocates
nothing and can run on a session thread without touching an allocator.

*ssh/identity.odin:81*

### `read`

```odin
read :: proc(s: ^Session, buf: []u8, timeout_ms: int) -> (n: int, ok: bool)
```

Blocks for up to timeout_ms waiting for input. Returns ok=false once the
connection is gone. n == 0 with ok == true just means "nothing typed".

Note on the two-step wait: ssh_event_dopoll's timeout argument does not
actually block for us — it returns immediately every time, which would spin
a core per session. So libssh gets to do the parsing while we do the waiting,
on the session socket directly.

*ssh/server.odin:235*

### `remote_addr`

```odin
remote_addr :: proc "contextless" (s: ^Session) -> string
```

Numeric peer address, no reverse DNS.

*ssh/server.odin:213*

### `ring_pop`

```odin
ring_pop :: proc "contextless" (r: ^Ring, dst: []u8) -> int
```

Removes up to `len(dst)` bytes, returning how many were moved.

*ssh/server.odin:170*

### `ring_push`

```odin
ring_push :: proc "contextless" (r: ^Ring, src: []u8) -> int
```

Appends what fits, returning how many bytes were taken.

*ssh/server.odin:160*

### `serve`

```odin
serve :: proc(cfg: Config) -> bool
```

*ssh/server.odin:480*

### `size`

```odin
size :: proc "contextless" (s: ^Session) -> (cols, rows: int)
```

Current terminal geometry in cells, falling back to 80x24 if the client never
said.

*ssh/server.odin:219*

### `take_resize`

```odin
take_resize :: proc "contextless" (s: ^Session) -> bool
```

True exactly once after each window resize.

*ssh/server.odin:297*

### `term`

```odin
term :: proc "contextless" (s: ^Session) -> string
```

The client's `$TERM`, e.g. "xterm-256color". Empty if no pty was requested.

*ssh/server.odin:189*

### `user`

```odin
user :: proc "contextless" (s: ^Session) -> string
```

The username the client offered. Client-chosen and unverified — never use it
as identity; use `id` instead.

*ssh/server.odin:184*

### `warn_if_world_readable`

```odin
warn_if_world_readable :: proc(path: string)
```

A host key or identity secret that other local users can read is not a
secret. Say so loudly rather than failing silently.

*ssh/perm_posix.odin:13*

### `write`

```odin
write :: proc(s: ^Session, data: []u8) -> int
```

Sends bytes to the client. Returns how many were written, 0 once the
connection is gone.

*ssh/server.odin:279*

### `write_string`

```odin
write_string :: proc(s: ^Session, str: string) -> int
```

`write` for a string.

*ssh/server.odin:292*
