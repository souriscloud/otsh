# otsh:ssh — API reference

The SSH server: bind, handshake, auth, pty and shell requests, then a byte stream. No dependency on `tui`.

Generated from `ssh/*.odin` by `docs/tools/gen_api.py`. For how these fit together, see the hand-written guide ([ssh](ssh.md)).

## Contents

**Types** — [`Audit_Event`](#audit-event), [`Audit_Kind`](#audit-kind), [`Audit_Limit`](#audit-limit), [`Audit_Sink`](#audit-sink), [`Auth_Method`](#auth-method), [`Auth_Methods`](#auth-methods), [`Auth_Request`](#auth-request), [`Authenticator`](#authenticator), [`Config`](#config), [`Handler`](#handler), [`Identity_Secret`](#identity-secret), [`Limits`](#limits), [`Pty`](#pty), [`Server`](#server), [`Session`](#session)

**Constants** — [`ALL_AUTH`](#all-auth), [`AUDIT_LINE_MAX`](#audit-line-max), [`DEFAULT_CIPHERS`](#default-ciphers), [`DEFAULT_HOST`](#default-host), [`DEFAULT_HOST_IPV4`](#default-host-ipv4), [`DEFAULT_HOST_KEY`](#default-host-key), [`DEFAULT_HOSTKEYS`](#default-hostkeys), [`DEFAULT_KEX`](#default-kex), [`DEFAULT_LIMITS`](#default-limits), [`DEFAULT_MACS`](#default-macs), [`DEFAULT_PORT`](#default-port), [`DEFAULT_SHUTDOWN_SECONDS`](#default-shutdown-seconds), [`ID_BYTES`](#id-bytes), [`ID_SIZE`](#id-size), [`MAX_PTY_COLS`](#max-pty-cols), [`MAX_PTY_ROWS`](#max-pty-rows), [`SECRET_SIZE`](#secret-size), [`VERSION`](#version), [`VERSION_MAJOR`](#version-major), [`VERSION_MINOR`](#version-minor), [`VERSION_PATCH`](#version-patch)

**Procedures** — [`audit_format`](#audit-format), [`audit_stderr`](#audit-stderr), [`ensure_host_key`](#ensure-host-key), [`fingerprint`](#fingerprint), [`id`](#id), [`ids_equal`](#ids-equal), [`key_type`](#key-type), [`load_or_create_secret`](#load-or-create-secret), [`pseudonym`](#pseudonym), [`read`](#read), [`remote_addr`](#remote-addr), [`serve`](#serve), [`shutdown`](#shutdown), [`shutting_down`](#shutting-down), [`size`](#size), [`take_resize`](#take-resize), [`term`](#term), [`user`](#user), [`warn_if_world_readable`](#warn-if-world-readable), [`write`](#write), [`write_string`](#write-string)

## Types

### `Audit_Event`

```odin
Audit_Event :: struct {
	kind:     Audit_Kind,
	// Stamped by the emitter rather than the call site, so every line's clock
	// comes from one place. UTC.
	at:       time.Time,
	// Numeric peer address. Present on every kind except `.Listen` — this is
	// the field a fail2ban-style filter keys on.
	addr:     string,
	host:     string,       // .Listen: the bind address
	port:     int,          // .Listen
	limit:    Audit_Limit,  // .Reject: which limit tripped
	user:     string,       // .Auth, .Session_Start: client-offered, unverified
	method:   Auth_Method,  // .Auth
	ok:       bool,         // .Auth: the verdict
	// Pseudonymous account id, empty when there is none. Carried by `.Auth`,
	// `.Session_Start` and `.Session_End`. Never the fingerprint.
	id:       string,
	term:     string,       // .Session_Start: client-reported $TERM
	cols:     int,          // .Session_Start
	rows:     int,          // .Session_Start
	duration: time.Duration, // .Session_End: how long the handler ran
}
```

One auditable thing that happened.

A flat struct rather than a tagged union: this is copied on the accept path
and on every session thread, and a struct of borrowed strings copies without
a branch and without an allocator. Fields that a kind does not carry stay
zero and are not formatted.

Every string here borrows memory owned by the connection and dies with it.
A sink that keeps an event past its own return must copy what it keeps.

*[ssh/audit.odin:45](../ssh/audit.odin#L45)*

### `Audit_Kind`

```odin
Audit_Kind :: enum u8 {
	Listen,        // the port is bound and the accept loop is running
	Accept,        // a TCP connection was accepted, before any crypto
	Reject,        // a connection was dropped by Limits, before any crypto
	Kex_Fail,      // key exchange failed; there is no client identity yet
	Auth,          // one authentication attempt, accepted or refused
	Session_Start, // authenticated, pty requested, shell granted
	Session_End,   // the handler returned and the connection is closing
}
```

What happened. One value per line handed to the sink.

*[ssh/audit.odin:19](../ssh/audit.odin#L19)*

### `Audit_Limit`

```odin
Audit_Limit :: enum u8 {
	None,
	Sessions, // Limits.max_sessions, the process-wide cap
	Per_Ip,   // Limits.max_per_ip, the per-source-address cap
}
```

Which limit refused a connection. Only meaningful on `.Reject`.

*[ssh/audit.odin:30](../ssh/audit.odin#L30)*

### `Audit_Sink`

```odin
Audit_Sink :: #type proc(e: Audit_Event)
```

Where audit events go. Set it on `Config.audit`; nil disables auditing.

Called from the accept loop, from every session thread, and from inside
libssh's authentication callbacks — concurrently, and on the connection's
critical path. A sink must therefore be thread-safe, must not block, and
should not allocate. `audit_stderr` satisfies all three; a sink that writes
to a database or a network service wants a queue in front of it.

*[ssh/audit.odin:75](../ssh/audit.odin#L75)*

### `Auth_Method`

```odin
Auth_Method :: enum u8 {
	None,
	Password,
	Publickey,
}
```

The SSH authentication methods this server understands.

*[ssh/server.odin:55](../ssh/server.odin#L55)*

### `Auth_Methods`

```odin
Auth_Methods :: distinct bit_set[Auth_Method;u8]
```

A set of `Auth_Method`. Note that offering `.None` means an OpenSSH client
authenticates before ever offering a key, leaving `Session.id` empty.

*[ssh/server.odin:62](../ssh/server.odin#L62)*

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

Example:

```odin
authenticate :: proc(req: ssh.Auth_Request) -> bool {
	if req.method == .Publickey {
		return req.fingerprint == allowed_fingerprint
	}
	return false
}
```

*[ssh/server.odin:78](../ssh/server.odin#L78)*

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

Example:

```odin
authenticate :: proc(req: ssh.Auth_Request) -> bool {
	return true // accept everyone; authorize inside the app instead
}
```

*[ssh/server.odin:108](../ssh/server.odin#L108)*

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
```

How to run the server. Every field has a documented default, so the zero value
is a working — if wide open — public server on port 2222.

Example:

```odin
ssh.serve(ssh.Config{
	host_key_path = "hostkey",
	handler       = handler,
	authenticate  = authenticate,
})
```

*[ssh/server.odin:465](../ssh/server.odin#L465)*

### `Handler`

```odin
Handler :: #type proc(s: ^Session)
```

Handler runs on its own thread, one per connection, and owns the session for
as long as it runs. When it returns the connection is torn down.

*[ssh/server.odin:52](../ssh/server.odin#L52)*

### `Identity_Secret`

```odin
Identity_Secret :: struct {
	bytes:  [SECRET_SIZE]u8,
	loaded: bool,
}
```

The per-server HMAC key behind `Session.id`. Back it up with the host key:
losing it re-pseudonymises every user, so everyone looks new.

*[ssh/identity.odin:30](../ssh/identity.odin#L30)*

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
	// Seconds a client may leave its flow-control window shut — i.e. simply stop
	// reading — before its session is torn down.
	//
	// `handshake_seconds` does not cover this: it is a socket timeout, and the
	// wait inside libssh's ssh_channel_write does not honour it. Measured before
	// this limit existed: three clients that authenticated, asked for a shell and
	// then never read held all three session slots for a full 60 seconds, past a
	// 20-second handshake timeout, while a fourth client was refused with
	// `limit=sessions`. Nothing about it is malformed — a slow reader is entitled
	// to stop reading — so it costs the attacker one idle socket per pinned
	// thread and is invisible to a protocol-level filter.
	//
	// The window closing is normal and harmless; only staying shut this long is
	// not. Raise it for clients on genuinely slow links.
	//
	// Negative disables the *disconnect*, not the protection: `write` never
	// blocks regardless of this setting. A stalled client then keeps its slot
	// for as long as it likes, but on a thread that is still responsive and
	// still notices shutdown, rather than one wedged inside libssh.
	write_stall_seconds: int,
}
```

Per field: 0 means "use the default below", negative means "no limit".
That way the zero value of the whole struct is the safe default rather than
an accidental free-for-all, and you can still opt out of any single limit.

Example:

```odin
limits := ssh.Limits{max_sessions = 64, max_per_ip = 4} // tighter than DEFAULT_LIMITS
ssh.serve(ssh.Config{limits = limits, handler = handler})
```

*[ssh/limits.odin:21](../ssh/limits.odin#L21)*

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

*[ssh/server.odin:153](../ssh/server.odin#L153)*

### `Server`

```odin
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
```

Server-wide state, shared by every connection. Internal; reach it through
`Session.server` only if you know what you are doing.

*[ssh/server.odin:112](../ssh/server.odin#L112)*

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
	// When the shell was granted, for the session_end audit duration. Written
	// by this connection's own session thread just before it calls the handler,
	// and read only by that same thread — it never crosses a thread boundary.
	started:       time.Time,
	// Flow-control stall tracking for `write`. Same single-thread ownership as
	// `started`: only this connection's own thread touches them.
	write_stalled: bool,
	stall_since:   time.Time,

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
```

One connection. Created and freed by the accept loop; your `Handler` owns it
for the duration of the call. All its string accessors borrow memory that
dies with the session.

*[ssh/server.odin:165](../ssh/server.odin#L165)*

## Constants

### `ALL_AUTH`

```odin
ALL_AUTH :: Auth_Methods{.None, .Password, .Publickey}
```

Every method. The default when `Config.methods` is left zero.

*[ssh/server.odin:65](../ssh/server.odin#L65)*

### `AUDIT_LINE_MAX`

```odin
AUDIT_LINE_MAX :: 320
```

Upper bound on one formatted line, newline included. The longest line is a
session_start with every field at its cap.

*[ssh/audit.odin:165](../ssh/audit.odin#L165)*

### `DEFAULT_CIPHERS`

```odin
DEFAULT_CIPHERS :: "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com"
```

AEAD ciphers only: no CBC, no stream ciphers with separate MACs.

*[ssh/server.odin:515](../ssh/server.odin#L515)*

### `DEFAULT_HOST`

```odin
DEFAULT_HOST :: "::"
```

Bind address used when `Config.host` is empty. sshtui fills this in too; it
lives here as well so calling `ssh.serve` directly cannot bind port 0.

`"::"` is the IPv6 wildcard, and on a dual-stack kernel one socket bound to
it serves BOTH families: IPv4 clients arrive as IPv4-mapped addresses, which
`peer_address` normalises back to the dotted quad, so an audit line for a
v4 client reads `addr=127.0.0.1` exactly as it did on an IPv4-only bind.
Where that is not available `serve` falls back to `DEFAULT_HOST_IPV4` and
says so on stderr; see below for the two ways it detects that.

Why not `"0.0.0.0"`, which this used to be: `localhost` resolves to `::1`
before `127.0.0.1` on macOS and on Linux, so a client's first connection
attempt went to IPv6, found nothing listening, and only then retried on
IPv4. The wasted attempt costs one round trip. On loopback that is nothing —
measured on macOS 26.3, 200 connects each, the connect phase alone: median
0.11 ms via `localhost` against an IPv4-only bind versus 0.06 ms against a
dual-stack one, which is at the edge of run-to-run noise. But the cost is
one RTT, not a constant, so it scales with distance to the server. Measured
in Docker on Linux 6.x with a 50 ms one-way delay on `lo` (netem), best of
five connects to `localhost`:

```
                     localhost   127.0.0.1   ::1
bind 0.0.0.0         206.66 ms   104.39 ms   refused
bind ::              104.09 ms   102.70 ms   107.70 ms
```

The `localhost` column is the point: two round trips become one. The `::1`
column is the other half of it — an IPv4-only server is not reachable from an
IPv6-only client at all, which is not a latency problem but an outage.

What this does NOT fix: a client whose first SYN is DROPPED rather than
refused — a firewall using `-j DROP`, some VPNs — waits out its full connect
timeout, and no bind address changes that, because a dropped packet never
reaches any listener. Measured with an `ip6tables ... -j DROP` rule in place:
134 s to connect via `localhost` with an IPv4-only bind, and 135 s with a
dual-stack one. If connecting is slow in that way, the fix is in the
firewall, not here.

Two things can make the dual-stack bind unusable, and `serve` handles both by
rebinding on `DEFAULT_HOST_IPV4` with an explanation on stderr:

  - The host has no IPv6 at all, so binding `"::"` fails outright. (Note that
    Linux's `net.ipv6.conf.all.disable_ipv6=1` is NOT this case: measured in
    Docker, a `"::"` bind still succeeds there and still serves IPv4.)
  - The kernel makes the socket IPv6-ONLY, so it would refuse every IPv4
    client. libssh never sets `IPV6_V6ONLY` itself, so this is the kernel's
    default: Linux with `net.ipv6.bindv6only=1` (measured: the bind succeeds
    and IPv4 clients get "connection refused"), FreeBSD, and Windows. `serve`
    reads the option back off the listening socket and rebinds rather than
    serving an IPv4 outage.

The fallback applies ONLY to this default. An operator who writes
`Config.host = "::"` asked for IPv6 and gets exactly that, refusals included.

*[ssh/server.odin:798](../ssh/server.odin#L798)*

### `DEFAULT_HOST_IPV4`

```odin
DEFAULT_HOST_IPV4 :: "0.0.0.0"
```

Where the default bind retreats to when a dual-stack socket is unavailable —
the IPv4 wildcard, which is what `DEFAULT_HOST` itself used to be. Never used
unless `Config.host` was left empty; see `DEFAULT_HOST`.

*[ssh/server.odin:802](../ssh/server.odin#L802)*

### `DEFAULT_HOST_KEY`

```odin
DEFAULT_HOST_KEY :: "hostkey"
```

Host key path used when `Config.host_key_path` is empty.

*[ssh/server.odin:806](../ssh/server.odin#L806)*

### `DEFAULT_HOSTKEYS`

```odin
DEFAULT_HOSTKEYS :: "ssh-ed25519"
```

Ed25519 only — matches the key `ensure_host_key` generates.

*[ssh/server.odin:519](../ssh/server.odin#L519)*

### `DEFAULT_KEX`

```odin
DEFAULT_KEX :: "curve25519-sha256,curve25519-sha256@libssh.org"
```

Modern-only. Every one of these is an AEAD or an ETM MAC with a
curve25519 exchange; nothing here depends on SHA-1, CBC, or NIST curves.

*[ssh/server.odin:513](../ssh/server.odin#L513)*

### `DEFAULT_LIMITS`

```odin
DEFAULT_LIMITS :: Limits {
	max_sessions        = 256,
	max_per_ip          = 8,
	handshake_seconds   = 20,
	max_auth_attempts   = 6,
	// Generous: a real client on a bad link recovers in well under this, and an
	// app that draws at 30fps notices the window shut within one frame.
	write_stall_seconds = 30,
}
```

Applied to any `Limits` field left at zero. Deliberately conservative — raise
them deliberately rather than discovering you had none.

*[ssh/limits.odin:61](../ssh/limits.odin#L61)*

### `DEFAULT_MACS`

```odin
DEFAULT_MACS :: "hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com"
```

Encrypt-then-MAC only, SHA-2 only.

*[ssh/server.odin:517](../ssh/server.odin#L517)*

### `DEFAULT_PORT`

```odin
DEFAULT_PORT :: 2222
```

Port used when `Config.port` is zero.

*[ssh/server.odin:804](../ssh/server.odin#L804)*

### `DEFAULT_SHUTDOWN_SECONDS`

```odin
DEFAULT_SHUTDOWN_SECONDS :: 5
```

How long `serve` waits for connected sessions to finish once shutdown
begins, when `Config.shutdown_seconds` is zero. Long enough for an app to
notice its input has closed and paint one last frame, short enough not to
hold up a service restart.

*[ssh/shutdown.odin:31](../ssh/shutdown.odin#L31)*

### `ID_BYTES`

```odin
ID_BYTES :: 16
```

128 bits of id. Collisions are not a practical concern and the shorter
string is easier to eyeball in logs.

*[ssh/identity.odin:24](../ssh/identity.odin#L24)*

### `ID_SIZE`

```odin
ID_SIZE :: ID_BYTES * 2
```

Length of a pseudonymous id as hex text.

*[ssh/identity.odin:26](../ssh/identity.odin#L26)*

### `MAX_PTY_COLS`

```odin
MAX_PTY_COLS :: 1000
```

Upper bounds on client-supplied terminal geometry, matching tui's own limits.
pty-req and window-change both carry uint32 dimensions chosen by the client;
unclamped they are an allocation-size overflow and a remote crash.

*[ssh/server.odin:148](../ssh/server.odin#L148)*

### `MAX_PTY_ROWS`

```odin
MAX_PTY_ROWS :: 300
```

*[ssh/server.odin:149](../ssh/server.odin#L149)*

### `SECRET_SIZE`

```odin
SECRET_SIZE :: 32
```

Length of the identity secret, in bytes.

*[ssh/identity.odin:21](../ssh/identity.odin#L21)*

### `VERSION`

```odin
VERSION :: "0.4.0"
```

The same version as a string, for banners and log lines: "0.2.0".

Written out rather than composed from the three constants above, because Odin
has no compile-time integer-to-string. tests/version_test.odin asserts the two
spellings agree, since a bumped triple beside a stale string is exactly the
mistake a release makes.

*[ssh/version.odin:54](../ssh/version.odin#L54)*

### `VERSION_MAJOR`

```odin
VERSION_MAJOR :: 0
```

The first of the three numbers described above. Assert against it at
compile time if your app needs a particular API:

Example:

```odin
#assert(ssh.VERSION_MAJOR == 0 && ssh.VERSION_MINOR >= 1)
```

*[ssh/version.odin:44](../ssh/version.odin#L44)*

### `VERSION_MINOR`

```odin
VERSION_MINOR :: 4
```

*[ssh/version.odin:45](../ssh/version.odin#L45)*

### `VERSION_PATCH`

```odin
VERSION_PATCH :: 0
```

*[ssh/version.odin:46](../ssh/version.odin#L46)*

## Procedures

### `audit_format`

```odin
audit_format :: proc "contextless" (e: Audit_Event, buf: []u8) -> string
```

Formats `e` into `buf` and returns a string viewing the bytes written. No
newline is appended — `audit_stderr` adds one so it can write the whole line
in a single call. Allocates nothing and needs no context, so a sink can run
it on a stack buffer from anywhere. Output is truncated rather than
overflowing if `buf` is shorter than AUDIT_LINE_MAX.

*[ssh/audit.odin:122](../ssh/audit.odin#L122)*

### `audit_stderr`

```odin
audit_stderr :: proc(e: Audit_Event)
```

A ready-made `Audit_Sink` writing the format above to stderr, one line per
event.

The line is assembled in a stack buffer and handed to a single `os.write`,
because events fire from the accept loop and from every session thread at
once: two partial writes would interleave into a line no filter can parse.
Nothing here allocates, so it is safe on the connection's critical path.

Example:

```odin
ssh.serve(ssh.Config{audit = ssh.audit_stderr, handler = handler})
```

*[ssh/audit.odin:178](../ssh/audit.odin#L178)*

### `ensure_host_key`

```odin
ensure_host_key :: proc(path: string, advertised := DEFAULT_HOSTKEYS) -> bool
```

Creates the host key if it does not exist yet — the SSH equivalent of a TLS
certificate. Clients pin it in ~/.ssh/known_hosts, so it must be stable
across restarts.

*[ssh/server.odin:524](../ssh/server.odin#L524)*

### `fingerprint`

```odin
fingerprint :: proc "contextless" (s: ^Session) -> string
```

SHA256 fingerprint of the key the client authenticated with, or "" if they
did not use one. Stable across connections — use it as an account id.

Example:

```odin
handler :: proc(s: ^ssh.Session) {
	fp := ssh.fingerprint(s) // "" unless the client used a key
}
```

*[ssh/server.odin:237](../ssh/server.odin#L237)*

### `id`

```odin
id :: proc "contextless" (s: ^Session) -> string
```

Pseudonymous account id: HMAC(server secret, fingerprint). Empty unless an
identity secret is configured and the client used a key. Store this, not the
fingerprint. See identity.odin.

Example:

```odin
handler :: proc(s: ^ssh.Session) {
	account := ssh.id(s) // "" unless Config.identity_secret is set
}
```

*[ssh/server.odin:256](../ssh/server.odin#L256)*

### `ids_equal`

```odin
ids_equal :: proc "contextless" (a, b: string) -> bool
```

Compares two ids without leaking where they differ via timing. Use this
rather than `==` when checking an id against a stored one.

*[ssh/identity.odin:113](../ssh/identity.odin#L113)*

### `key_type`

```odin
key_type :: proc "contextless" (s: ^Session) -> string
```

The verified key's algorithm, e.g. "ssh-ed25519". Empty unless public-key
auth was used.

*[ssh/server.odin:243](../ssh/server.odin#L243)*

### `load_or_create_secret`

```odin
load_or_create_secret :: proc(path: string) -> (secret: Identity_Secret, ok: bool)
```

Loads the secret from `path`, creating it on first run. Treat this file
exactly like the host key: back it up, keep it 0600, never commit it.
Losing it does not leak anything — it just re-pseudonymises everybody, which
means every user looks like a new user.

Most apps just set Config.identity_secret and never call this directly.
It exists for tooling that needs the secret without starting a server:

Example:

```odin
secret, ok := ssh.load_or_create_secret("identity-secret")
```

*[ssh/identity.odin:46](../ssh/identity.odin#L46)*

### `pseudonym`

```odin
pseudonym :: proc(secret: ^Identity_Secret, fingerprint: string, dst: []u8) -> string
```

Stable per-server id for a verified key fingerprint. Writes into `dst`
(needs ID_SIZE bytes) and returns a string viewing it, so this allocates
nothing and can run on a session thread without touching an allocator.

*[ssh/identity.odin:88](../ssh/identity.odin#L88)*

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

Example:

```odin
buf: [4096]u8
n, ok := ssh.read(s, buf[:], 100) // waits up to 100ms
if !ok {
	return // connection is gone
}
```

*[ssh/server.odin:291](../ssh/server.odin#L291)*

### `remote_addr`

```odin
remote_addr :: proc "contextless" (s: ^Session) -> string
```

Numeric peer address, no reverse DNS.

*[ssh/server.odin:261](../ssh/server.odin#L261)*

### `serve`

```odin
serve :: proc(cfg: Config) -> bool
```

Binds, listens, and accepts connections until the process exits, spawning one
thread per connection. Returns false if setup fails; otherwise blocks.
Refuses to continue on a libssh too old to have the Terrapin fix.

Most apps want `sshtui.serve`, which adapts a `tui.App` for you. Use this
directly only when working with the byte stream yourself:

Example:

```odin
handler :: proc(s: ^ssh.Session) {
	ssh.write_string(s, fmt.tprintf("hello, %s\r\n", ssh.user(s)))
}
ssh.serve(ssh.Config{handler = handler})
```

*[ssh/server.odin:890](../ssh/server.odin#L890)*

### `shutdown`

```odin
shutdown :: proc(srv: ^Server)
```

Asks `srv` to stop: the accept loop exits, connected sessions are told their
input has finished, and `serve` returns once they are gone or the deadline
passes. Safe to call from any thread, including from inside a Handler.

Example:

```odin
handler :: proc(s: ^ssh.Session) {
	if ssh.user(s) == "admin-stop" {
		ssh.shutdown(s.server) // ask the whole server to stop
	}
}
```

*[ssh/shutdown.odin:68](../ssh/shutdown.odin#L68)*

### `shutting_down`

```odin
shutting_down :: proc "contextless" () -> bool
```

True once a signal asked this process to stop. Useful to an app that wants
to know why its loop is unwinding.

*[ssh/shutdown.odin:53](../ssh/shutdown.odin#L53)*

### `size`

```odin
size :: proc "contextless" (s: ^Session) -> (cols, rows: int)
```

Current terminal geometry in cells, falling back to 80x24 if the client never
said.

*[ssh/server.odin:267](../ssh/server.odin#L267)*

### `take_resize`

```odin
take_resize :: proc "contextless" (s: ^Session) -> bool
```

True exactly once after each window resize.

*[ssh/server.odin:447](../ssh/server.odin#L447)*

### `term`

```odin
term :: proc "contextless" (s: ^Session) -> string
```

The client's `$TERM`, e.g. "xterm-256color". Empty if no pty was requested.

Example:

```odin
handler :: proc(s: ^ssh.Session) {
	t := ssh.term(s) // "xterm-256color", "", ...
}
```

*[ssh/server.odin:225](../ssh/server.odin#L225)*

### `user`

```odin
user :: proc "contextless" (s: ^Session) -> string
```

The username the client offered. Client-chosen and unverified — never use it
as identity; use `id` instead.

Example:

```odin
handler :: proc(s: ^ssh.Session) {
	name := ssh.user(s) // client-chosen; do not treat it as verified identity
}
```

*[ssh/server.odin:214](../ssh/server.odin#L214)*

### `warn_if_world_readable`

```odin
warn_if_world_readable :: proc(path: string)
```

A host key or identity secret that other local users can read is not a
secret. Say so loudly rather than failing silently.

*[ssh/perm_posix.odin:13](../ssh/perm_posix.odin#L13)*

### `write`

```odin
write :: proc(s: ^Session, data: []u8) -> int
```

Sends bytes to the client. Returns how many were written — which may be
fewer than asked for, or 0 — and 0 once the connection is gone.

Never blocks waiting for the client to read. That is a deliberate departure
from `ssh_channel_write`, which does: once the peer's flow-control window is
exhausted it waits inside ssh_handle_packets for a WINDOW_ADJUST, and that
wait does not honour SSH_OPTIONS_TIMEOUT. Measured: three clients that
authenticated, requested a shell and then simply stopped reading held all
three session slots for a full 60 s with `handshake_seconds` at 20, while a
fourth was refused with `limit=sessions`. Nothing in that exchange is
malformed, so it costs the client one idle socket per pinned server thread.

So only what the peer has credit for is handed to libssh, and a window that
stays shut past `Limits.write_stall_seconds` ends the session. Callers must
cope with a short write: `tui.run` repaints in full on the next frame, since
a partially sent frame leaves its diff baseline describing a screen the
terminal is not showing.

Example:

```odin
msg := "hello\r\n"
n := ssh.write(s, transmute([]u8)msg)
```

*[ssh/server.odin:399](../ssh/server.odin#L399)*

### `write_string`

```odin
write_string :: proc(s: ^Session, str: string) -> int
```

`write` for a string.

*[ssh/server.odin:442](../ssh/server.odin#L442)*
