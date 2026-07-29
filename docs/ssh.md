# ssh — the server

`ssh` is the SSH server on its own: bind, accept, key exchange, authenticate,
answer `pty-req` and `shell`, then hand your code a byte stream. It does not
depend on `tui` and knows nothing about screens, cells, or rendering — you
could use it to serve a line-oriented protocol, a chat, or a log tail just as
easily as a TUI.

Most apps should use [`sshtui`](./sshtui.md) instead, which adapts a
`Session` into a `tui.Backend` and runs a `tui.Program` per connection. Reach
for `ssh` directly only when you want the transport without the renderer.

## What it does

A normal `sshd` answers a client's `pty-req` by allocating a real
pseudo-terminal and forking a login shell into it. `ssh` does neither. It
answers `pty-req` with "noted" — recording the terminal type and window size
the client sent, allocating nothing — and answers `shell` with "go ahead".
From that point the channel itself is the terminal: bytes the client sends
are keystrokes, bytes you send back are interpreted by the client's own
terminal emulator. **No pty is allocated and no shell is forked — the remote
terminal is the display.**

Concretely, `serve` runs this sequence per connection, all on one thread
dedicated to that connection:

1. Accept the TCP connection (`ssh_bind_accept`).
2. Run key exchange (`ssh_handle_key_exchange`) — negotiates algorithms and
   proves the server owns the host key.
3. Pump libssh's event loop, answering auth, channel-open, `pty-req` and
   `shell` requests via callbacks, until the client is authenticated, has a
   channel open, and asked for a shell.
4. Call your `Handler` with the resulting `Session`.
5. When `Handler` returns, send exit status 0, close the channel, and tear
   the connection down.

A session that never requests a pty cannot get a shell either —
`cb_shell_request` refuses shell requests with no preceding `pty-req`. `exec`
and `subsystem` requests are refused outright; this server only speaks
interactive sessions.

## Serving

```odin
serve :: proc(cfg: Config) -> bool
```

Blocks, accepting connections until the process exits (or `Server.running` is
set false from outside — there is no exported stop function today). Returns
`false` if setup fails: `ssh_init`, host key creation, or `ssh_bind_listen`.

### `Config`

| Field | Type | Zero value |
| --- | --- | --- |
| `host` | `string` | `""` uses `DEFAULT_HOST` (`"0.0.0.0"`). |
| `port` | `int` | `0` uses `DEFAULT_PORT` (`2222`). |
| `host_key_path` | `string` | `""` uses `DEFAULT_HOST_KEY` (`"hostkey"`). Generated on first run if missing. |
| `handler` | `Handler` | No default. A `nil` handler still completes the handshake and auth, acks the shell request, then immediately closes with exit status 0 — the client sees a clean, silent, instant disconnect. |
| `user_data` | `rawptr` | `nil`. Copied onto every `Session.user_data` unchanged; yours to use or ignore. |
| `authenticate` | `Authenticator` | `nil` accepts every client. See Auth below before relying on this. |
| `methods` | `Auth_Methods` | `{}` is replaced with `ALL_AUTH` (all three methods offered). |
| `identity_secret` | `string` | `""` disables pseudonymous ids — `ssh.id(s)` is always `""`. Non-empty loads the secret from that path, creating it on first run. |
| `limits` | `Limits` | The zero-valued struct resolves to `DEFAULT_LIMITS` field-by-field — see Limits below. |
| `audit` | `Audit_Sink` | `nil` records nothing. Auditing is opt-in because every line carries a peer address — see Audit below. |
| `key_exchange` | `string` | `""` uses `DEFAULT_KEX`. `"-"` leaves libssh's own (broader) default alone. |
| `ciphers` | `string` | `""` uses `DEFAULT_CIPHERS`, applied to both directions (`Ciphers_C_S` and `Ciphers_S_C`). `"-"` opts out. |
| `macs` | `string` | `""` uses `DEFAULT_MACS`, applied to both directions (`Hmac_C_S` and `Hmac_S_C`). `"-"` opts out. |
| `hostkey_algorithms` | `string` | `""` uses `DEFAULT_HOSTKEYS`. `"-"` opts out. |

`key_exchange`, `ciphers`, `macs`, and `hostkey_algorithms` take libssh's
comma-separated algorithm-name format (e.g. what `DEFAULT_CIPHERS` is written
in below) — not Odin literals of any structured type.

## Handler

```odin
Handler :: #type proc(s: ^Session)
```

Runs on its own OS thread, one per connection, and owns the `Session` for as
long as it runs. When it returns, the connection is torn down: the channel is
sent EOF and closed, the libssh event and session objects are freed, and the
fingerprint/id buffers are zeroed. There is nothing to clean up on your side
beyond whatever you allocated for the connection.

## Session

The struct itself carries fixed-size buffers and libssh handles you are not
meant to touch directly; treat the procs below as the API.

```odin
user         :: proc "contextless" (s: ^Session) -> string
term         :: proc "contextless" (s: ^Session) -> string
fingerprint  :: proc "contextless" (s: ^Session) -> string
key_type     :: proc "contextless" (s: ^Session) -> string
id           :: proc "contextless" (s: ^Session) -> string
remote_addr  :: proc "contextless" (s: ^Session) -> string
size         :: proc "contextless" (s: ^Session) -> (cols, rows: int)
read         :: proc(s: ^Session, buf: []u8, timeout_ms: int) -> (n: int, ok: bool)
write        :: proc(s: ^Session, data: []u8) -> int
write_string :: proc(s: ^Session, str: string) -> int
take_resize  :: proc "contextless" (s: ^Session) -> bool
```

| Proc | Returns |
| --- | --- |
| `user` | Whatever the client sent as the login name. **Client-chosen and unverified — never use it as identity.** Anyone can `ssh root@host` or `ssh anyone-you-like@host`; nothing checks it. |
| `term` | `$TERM` as the client reported it in `pty-req`, e.g. `"xterm-256color"`. |
| `fingerprint` | SHA256 fingerprint of the key the client authenticated with, or `""` if they didn't use one. Stable across connections. |
| `key_type` | Key algorithm name, e.g. `"ssh-ed25519"`, or `""`. |
| `id` | Pseudonymous account id — `HMAC(server secret, fingerprint)`. Empty unless `identity_secret` is configured and the client used a key. Store this, not the fingerprint (see Identity below). |
| `remote_addr` | Numeric peer address. No reverse DNS. |
| `size` | Current `(cols, rows)`. Falls back to `80, 24` if either is `<= 0` (no `pty-req` seen yet). |
| `take_resize` | `true` exactly once after each window resize (`window-change`), then `false` until the next one. Poll it from your own loop. |

`read` and `write`/`write_string` are the actual byte stream:

```odin
read :: proc(s: ^Session, buf: []u8, timeout_ms: int) -> (n: int, ok: bool)
```

Blocks for up to `timeout_ms` waiting for input, then returns. The contract:

- `n == 0, ok == true` — nothing was typed inside the timeout. Not an error;
  call `read` again.
- `n > 0, ok == true` — got `n` bytes of raw client input into `buf`.
- `ok == false` — the connection is gone (closed, errored, or EOF). Stop
  reading; the `Handler` should return soon after.

Input is buffered in a fixed 4 KiB ring per session (`MAX_INPUT`); `read`
never allocates. `write` and `write_string` push bytes out over the channel
immediately and return the number of bytes written (`0` if the connection is
already gone or `data`/`str` was empty).

```odin
write        :: proc(s: ^Session, data: []u8) -> int
write_string :: proc(s: ^Session, str: string) -> int
```

## Auth

```odin
Auth_Method  :: enum u8 { None, Password, Publickey }
Auth_Methods :: distinct bit_set[Auth_Method;u8]
ALL_AUTH     :: Auth_Methods{.None, .Password, .Publickey}
```

```odin
Auth_Request :: struct {
	user:        string,
	method:      Auth_Method,
	password:    string, // .Password only
	fingerprint: string, // .Publickey only, e.g. "SHA256:0Cn7…" — signature verified
	key_type:    string, // .Publickey only, e.g. "ssh-ed25519"
	id:          string, // pseudonymous account id, when an identity secret is set
	remote_addr: string, // numeric peer address
}

Authenticator :: #type proc(req: Auth_Request) -> bool
```

Return `true` to let the client in. **A `nil` `Authenticator` accepts
everyone** — that is the default, and it is deliberate: SSH public-key auth
is two messages (RFC 4252 §7), a probe with no signature followed by a
signed proof, and this server never shows your `Authenticator` the probe —
only a key that reached the second message and verified. So by the time
`Auth_Request.fingerprint` is populated, the key is already proven.

**Read this before setting `authenticate`.** Rejecting a public key here does
not just deny access — it makes the client offer its *next* key, and the
next, until it runs out. A rejecting server therefore learns every public key
in the client's agent before authenticating anyone at all, which is a real
fingerprinting vector. If you need a members-only app, do not reject in
`Authenticator`: accept the key, take `req.id` (or `Session.id` once
connected), and show non-members a "not on the list" screen *inside* the
app. They are equally excluded, and you learned exactly one key instead of
all of them. `examples/members` is that pattern. See
[`./security.md`](./security.md) for the full explanation; if you do set an
`Authenticator` that rejects a key, `ssh` prints a one-time warning to stderr
pointing back here.

One more trap for identity-driven apps: `ALL_AUTH` — the default — includes
`.None`, and every OpenSSH client tries the `none` method first. If the
server accepts it, the client is already authenticated and never offers a
key at all, so `fingerprint`/`id` stay empty. Set `methods = {.Publickey}` to
require a key. This does not reintroduce enumeration risk: the client still
stops at its first key, because that key is accepted.

## Algorithm defaults

```odin
DEFAULT_KEX      :: "curve25519-sha256,curve25519-sha256@libssh.org"
DEFAULT_CIPHERS  :: "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com"
DEFAULT_MACS     :: "hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com"
DEFAULT_HOSTKEYS :: "ssh-ed25519"
```

Modern-only: every cipher is an AEAD, every MAC is encrypt-then-MAC, the
key exchange is curve25519. Nothing here depends on SHA-1, CBC, or a NIST
curve. `Config.key_exchange`, `.ciphers`, `.macs`, and `.hostkey_algorithms`
each control the matching option:

- `""` (the zero value) uses the hardened default above.
- `"-"` opts out entirely and leaves libssh's own built-in defaults in
  place, which are broader — they include RSA/SHA-1-era algorithms kept
  around for compatibility with older clients.

Verified on the wire against these defaults: a connecting client negotiated
`curve25519-sha256` key exchange, an `ssh-ed25519` host key, and the
`aes128-gcm@openssh.com` cipher. `ssh -c aes128-cbc ...` and
`ssh -o KexAlgorithms=diffie-hellman-group14-sha1 ...` are both refused —
neither algorithm is in the lists above.

## Limits

```odin
Limits :: struct {
	max_sessions:      int,
	max_per_ip:        int,
	handshake_seconds: int,
	max_auth_attempts: int,
}

DEFAULT_LIMITS :: Limits {
	max_sessions      = 256,
	max_per_ip        = 8,
	handshake_seconds = 20,
	max_auth_attempts = 6,
}
```

Per field: `0` means "use the default above", negative means "no limit".
That makes the zero-valued `Limits{}` the safe default rather than an
accidental free-for-all, while still letting you opt out of any one limit
individually.

| Field | Protects against |
| --- | --- |
| `max_sessions` | Total concurrent sessions across the whole process. Without it, connections accumulate threads until the process runs out of them. |
| `max_per_ip` | Concurrent sessions from one source address. Without it, a single host can hold every session slot open by itself. Verified: with `max_per_ip = 3` and 12 simultaneous connection attempts from one address, exactly 3 were admitted. |
| `handshake_seconds` | Time allowed to complete key exchange and authentication, enforced as a timeout on the session socket. Without it, a client that opens a TCP connection and then sends nothing pins a thread forever. |
| `max_auth_attempts` | Failed authentication attempts on one connection before it is dropped. Limits brute-force guessing within a single session. |

Limit enforcement happens per source address in `remote_addr`'s numeric
form; a connection that is over a limit is dropped before the handshake
even starts, so it never reaches your `Authenticator` or `Handler`.

## Identity

```odin
SECRET_SIZE :: 32
ID_BYTES    :: 16
ID_SIZE     :: ID_BYTES * 2

Identity_Secret :: struct {
	bytes:  [SECRET_SIZE]u8,
	loaded: bool,
}

load_or_create_secret :: proc(path: string) -> (secret: Identity_Secret, ok: bool)
pseudonym              :: proc(secret: ^Identity_Secret, fingerprint: string, dst: []u8) -> string
ids_equal               :: proc "contextless" (a, b: string) -> bool
```

`load_or_create_secret` reads the secret from `path`, or generates
`SECRET_SIZE` random bytes and writes them there (mode 0600, `O_EXCL`) if the
file doesn't exist yet. `serve` calls this automatically when
`Config.identity_secret` is non-empty and stores the result on the `Server`.

`pseudonym` is what turns a verified fingerprint into `Session.id`:
`id = hex(HMAC-SHA256(secret, fingerprint))[:ID_BYTES]`, i.e. `ID_SIZE`
(32) hex characters of a truncated HMAC. It writes into `dst` (which needs
`ID_SIZE` bytes) and returns a string viewing it, so deriving an id never
allocates and is safe to call from a session thread's fast path.

The reason to store this instead of the fingerprint: a public key fingerprint
is a fine account id but a bad thing to persist, because it's *global* — a
database leak lets anyone correlate your users against any other service
that saw the same keys, or confirm "was this person a user here?" against a
public key they already hold. `HMAC(secret, fingerprint)` is stable for as
long as the secret lives, meaningless to anyone without that secret, and
unlinkable back to the raw fingerprint. Losing the secret doesn't leak
anything — it just re-pseudonymizes everyone, so every returning user looks
new.

`ids_equal` compares two ids using `crypto.compare_constant_time`, so
lookups against a stored id don't leak where the strings differed through
timing. Use it, not `==`, whenever you check a session's `id` against one
you have on file. Full rationale: [`./security.md`](./security.md).

## Audit

```odin
Audit_Sink :: #type proc(e: Audit_Event)

audit_stderr :: proc(e: Audit_Event)
audit_format :: proc "contextless" (e: Audit_Event, buf: []u8) -> string

AUDIT_LINE_MAX :: 320
```

Set `Config.audit` and the server records what happens to every connection:
the listen, each accept, each limiter rejection, each key-exchange failure,
every authentication attempt with its verdict, and every session's start and
end. `ssh.audit_stderr` is a ready-made sink; anything matching `Audit_Sink`
works.

```odin
ssh.serve(ssh.Config{handler = handle, audit = ssh.audit_stderr})
```

**`nil` — the zero value — records nothing at all**, so a `Config` written
before this existed behaves exactly as it did. That is deliberate, not an
oversight: every line carries the client's numeric address, and keeping a
record of who talked to your server and when is a privacy decision the
operator has to make on purpose, not one a library should make for them.

Two things are never logged, whatever sink you use: passwords, and the
client's public key fingerprint. The fingerprint is a *global* identifier
(see Identity above), so audit lines carry the pseudonymous `id` instead —
present only when `identity_secret` is set and the client used a key.

### Events

| `event=` | Fires when | Fields, in order |
| --- | --- | --- |
| `listen` | The port is bound and the accept loop is running. | `host` `port` |
| `accept` | A TCP connection was accepted, before any crypto. | `addr` |
| `reject` | `Limits` refused the connection, before any crypto. | `addr` `limit` |
| `kex_fail` | Key exchange failed; there is no client identity yet. | `addr` |
| `auth` | One authentication attempt resolved, either way. | `addr` `method` `user` `ok` `[id]` |
| `session_start` | Authenticated, pty requested, shell granted — just before your `Handler` runs. | `addr` `user` `term` `cols` `rows` `[id]` |
| `session_end` | Your `Handler` returned. | `addr` `secs` `[id]` |

`limit` is `sessions` (the process-wide `max_sessions`) or `per_ip`
(`max_per_ip`). `method` is `none`, `password` or `publickey`. `ok` is `true`
or `false`. `secs` is the session's duration in seconds with three decimals.

Note that `auth` fires for *every* outcome, including the two the server
decides on its own: a method that is not in `Config.methods`, and an attempt
past `max_auth_attempts`. A client hammering a method you do not offer is
exactly what a log filter needs to see.

### The line format

One event, one line, never wrapped or continued:

```
otsh: audit ts=2026-07-29T12:00:00Z event=auth addr=203.0.113.7 method=publickey user=git ok=false
```

This grammar is a contract — log filters are written against it, so treat a
change to it as a breaking change. What a parser may rely on:

- The line always begins with the literal `otsh: audit `.
- `ts` is RFC 3339 in UTC at second resolution, always exactly the 20
  characters `YYYY-MM-DDTHH:MM:SSZ`.
- Fields are separated by exactly one space, appear in the fixed order given
  in the table above, and no key repeats within a line.
- A field whose value is unknown or empty is written as `-`. The only
  optional field is `id`, which is omitted entirely when absent and is always
  last on the line.
- `addr` is present on every event except `listen`, and holds the peer
  address in numeric form — an IPv4 dotted quad, or an IPv6 address with an
  optional `%zone`. **Every failure record a filter cares about — `reject`,
  `kex_fail`, and `auth` with `ok=false` — carries `addr`.**
- Values never contain a space, an `=`, or a control character. Every byte
  outside `[A-Za-z0-9.:_@/+,%-]` is replaced with `?`, and values are capped:
  `addr` and `host` at 64 bytes, `user`, `term` and `id` at 32. `user` and
  `term` are client-controlled text, so without this a client could forge
  fields — or whole extra lines — in your log.

A real capture, from a connection that authenticated with a key and quit
after a few seconds:

```
otsh: audit ts=2026-07-29T19:34:20Z event=listen host=0.0.0.0 port=2229
otsh: audit ts=2026-07-29T19:34:21Z event=accept addr=127.0.0.1
otsh: audit ts=2026-07-29T19:34:21Z event=auth addr=127.0.0.1 method=none user=souris ok=false
otsh: audit ts=2026-07-29T19:34:21Z event=auth addr=127.0.0.1 method=publickey user=souris ok=true id=8550aab27bd698618495ca868215c5b7
otsh: audit ts=2026-07-29T19:34:21Z event=session_start addr=127.0.0.1 user=souris term=xterm-ghostty cols=120 rows=40 id=8550aab27bd698618495ca868215c5b7
otsh: audit ts=2026-07-29T19:34:24Z event=session_end addr=127.0.0.1 secs=3.412 id=8550aab27bd698618495ca868215c5b7
```

The `method=none ok=false` line is the OpenSSH client trying the `none`
method first, as it always does; this server was configured with
`methods = {.Publickey}`, so it refused and the client offered its key.

### Writing your own sink

```odin
Audit_Event :: struct {
	kind:     Audit_Kind,
	at:       time.Time,     // stamped by the emitter, UTC
	addr:     string,
	host:     string,        // .Listen
	port:     int,           // .Listen
	limit:    Audit_Limit,   // .Reject
	user:     string,        // .Auth, .Session_Start
	method:   Auth_Method,   // .Auth
	ok:       bool,          // .Auth
	id:       string,        // pseudonymous id, when there is one
	term:     string,        // .Session_Start
	cols:     int,           // .Session_Start
	rows:     int,           // .Session_Start
	duration: time.Duration, // .Session_End
}
```

A sink is called from the accept loop, from every session thread, and from
inside libssh's authentication callbacks — concurrently, and on the
connection's critical path. So it must be thread-safe, must not block, and
should not allocate; a sink that writes to a database or a network service
wants a queue in front of it. Every string in an `Audit_Event` is borrowed
from the connection and dies with it, so copy anything you keep past your own
return.

`audit_stderr` is the reference implementation of all three constraints: it
formats into a stack buffer and hands the whole line to a single `os.write`,
because two partial writes from two threads would interleave into a line no
filter can parse. If you want the same line somewhere else, call
`audit_format` — it needs no context and no allocator, and writes into a
buffer you own (`AUDIT_LINE_MAX` bytes is always enough, newline included).

## Host key

```odin
ensure_host_key :: proc(path: string) -> bool
```

Called automatically by `serve` before it binds. If `path` already exists,
it just checks the permissions (see below) and returns. Otherwise it
generates a fresh ed25519 key (`ssh_pki_generate`), writes it to `path`
unencrypted (`ssh_pki_export_privkey_file`), and `chmod`s it to `0600`
(owner read/write only) immediately afterward — libssh writes new files with
the process umask, typically `0644`, which is too permissive for a key that
lets someone impersonate this host.

```odin
warn_if_world_readable :: proc(path: string)
```

Runs at startup against both the host key and the identity secret, and
prints a warning to stderr if the file is group- or world-readable. It does
not refuse to start; it just makes the mistake loud.

The host key must stay stable across restarts. Clients pin it in
`~/.ssh/known_hosts` the first time they connect (TOFU — trust on first use);
regenerate it and every returning client sees a host-key-mismatch warning
and has to be told to remove the old entry. Back it up like you would a TLS
private key.

## Example

A handler that writes one line and disconnects — no `tui`, no pty tracking
beyond what `ssh` already does for you:

```odin
package main

import "core:fmt"
import "otsh:ssh"

handle :: proc(s: ^ssh.Session) {
	ssh.write_string(s, fmt.tprintf("hello, %s\r\n", ssh.user(s)))
}

main :: proc() {
	ssh.serve(
		ssh.Config{
			port          = 2225,
			host_key_path = "sshdoc_hostkey",
			handler       = handle,
		},
	)
}
```

`ssh -p 2225 localhost` connects, gets one line back, and the server closes
the connection as soon as `handle` returns. This builds as-is with
`./build.sh path/to/this/file`.

## See also

- [`./sshtui.md`](./sshtui.md) — serving a `tui.App` over this package instead
  of writing raw bytes yourself.
- [`./security.md`](./security.md) — the full rationale behind the auth and
  identity design above.
- `examples/whoami` — smallest full `sshtui` app, shows the auth hook and the
  audit log.
- `examples/members` — the "accept the key, gate inside the app" pattern.
