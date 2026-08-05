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

<!-- check:skip signature fragment; `Config` is defined below, `serve`'s body in ssh/server.odin -->
```odin
serve :: proc(cfg: Config) -> bool
```

Blocks, accepting connections. Returns `false` if setup fails: `ssh_init`,
host key creation, or `ssh_bind_listen`. Otherwise it returns `true` once it
has been asked to stop — by `SIGINT`/`SIGTERM`, which it handles by default,
or by a `shutdown(srv)` call — and the connected sessions have drained. See
[Shutdown](#shutdown) below.

### `Config`

| Field | Type | Zero value |
| --- | --- | --- |
| `host` | `string` | `""` uses `DEFAULT_HOST` (`"::"`), which serves IPv4 and IPv6 from one socket, falling back to `DEFAULT_HOST_IPV4` (`"0.0.0.0"`) with a message on stderr where that is not possible. See [Bind address](#bind-address). |
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
| `shutdown_seconds` | `int` | `0` uses `DEFAULT_SHUTDOWN_SECONDS` (5) — how long `serve` waits for connected sessions to finish once shutdown starts. Negative returns immediately. See Shutdown below. |
| `no_signal_handlers` | `bool` | `false` means `serve` handles `SIGINT`/`SIGTERM` itself and restores the previous handlers before returning. Set it when the surrounding program owns signal handling; then stop the server with `shutdown`. |

`key_exchange`, `ciphers`, `macs`, and `hostkey_algorithms` take libssh's
comma-separated algorithm-name format (e.g. what `DEFAULT_CIPHERS` is written
in below) — not Odin literals of any structured type.

### Bind address

The default is `DEFAULT_HOST`, the IPv6 wildcard `"::"`. On a dual-stack
kernel one socket bound there serves **both** families: an IPv4 client arrives
as an IPv4-mapped address, which `otsh` converts back to the dotted quad
before anything sees it, so `ssh.remote_addr` and every audit line read
`127.0.0.1`, not `::ffff:127.0.0.1`. Nothing downstream — the limiter's
per-address counting, the fail2ban filter in `deploy/` — has to know which
family the socket is.

It used to be `"0.0.0.0"`, and the reason it changed is that `localhost`
resolves to `::1` before `127.0.0.1` on both macOS and Linux. An IPv4-only
server therefore made every `ssh localhost` attempt IPv6 first, get refused,
and retry — one wasted round trip per connection, and no reachability at all
from an IPv6-only client. Measured in Docker on Linux with a 50 ms one-way
delay on `lo`, best of five connects:

| bind | via `localhost` | via `127.0.0.1` | via `::1` |
| --- | --- | --- | --- |
| `0.0.0.0` | 206.66 ms | 104.39 ms | connection refused |
| `::` | 104.09 ms | 102.70 ms | 107.70 ms |

On loopback with no added delay the same saving is a twentieth of a
millisecond — real, and invisible (measured on macOS, 200 connects each: the
connect phase alone is a median 0.11 ms via `localhost` against `0.0.0.0` and
0.06 ms against `::`). The cost is one RTT, so it scales with distance to the
server.

**This does not fix a slow connect caused by a dropped SYN.** Where a firewall
uses `DROP` rather than a refusal, the client waits out its full connect
timeout and no bind address changes that, because a dropped packet never
reaches any listener: measured with an `ip6tables … -j DROP` rule in place,
`ssh localhost` took 134 s against an IPv4-only bind and 135 s against a
dual-stack one. That symptom is a firewall to fix, not this.

Two things can make the dual-stack bind unusable. `serve` handles both by
rebinding on `DEFAULT_HOST_IPV4` (`"0.0.0.0"`) and saying so on stderr:

- **The host has no IPv6 at all**, so binding `"::"` fails. Note that Linux's
  `net.ipv6.conf.all.disable_ipv6=1` is *not* this case — measured, a `"::"`
  bind still succeeds there and still serves IPv4.
- **The kernel makes the socket IPv6-only**, which would refuse every IPv4
  client. libssh never sets `IPV6_V6ONLY` itself (`bind_socket` in its
  `src/bind.c` sets `SO_REUSEADDR` and nothing else, in every version `otsh`
  supports), so this is the kernel's default: Linux with
  `net.ipv6.bindv6only=1`, FreeBSD, and Windows. `serve` reads the option back
  off the listening socket and rebinds rather than serving an IPv4 outage.

```
otsh: the kernel made the :: listener IPv6-only, so it would refuse
      every IPv4 client (Linux net.ipv6.bindv6only=1, or FreeBSD's or
      Windows' default). Falling back to 0.0.0.0: IPv4 clients work, IPv6
      clients do not. Set Config.host = "::" to keep the IPv6-only bind.
```

The fallback applies **only** to the default. Set `Config.host` yourself and
you get exactly what you asked for — `"::"` stays IPv6-only where the kernel
made it so, `"0.0.0.0"` stays IPv4, `"127.0.0.1"` stays loopback.

## Handler

<!-- check:verbatim ssh/server.odin -->
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

<!-- check:skip signature cheat-sheet gathered from several places in ssh/server.odin; `Session` is opaque here, not contiguous source -->
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

<!-- check:skip signature fragment; `Session` is opaque here, body in ssh/server.odin -->
```odin
read :: proc(s: ^Session, buf: []u8, timeout_ms: int) -> (n: int, ok: bool)
```

Blocks for up to `timeout_ms` waiting for input, then returns. The contract:

- `n == 0, ok == true` — nothing was typed inside the timeout. Not an error;
  call `read` again.
- `n > 0, ok == true` — got `n` bytes of raw client input into `buf`.
- `ok == false` — the connection is gone (closed, errored, or EOF). Stop
  reading; the `Handler` should return soon after.

Input is buffered inside libssh's own per-channel buffer and `read` is its
only consumer; `read` never allocates, and SSH's transport window caps what a
client can buffer server-side at ~2 MiB (see architecture.md, "Input flow and
backpressure"). `write` and `write_string` push bytes out over the channel
immediately and return the number of bytes written (`0` if the connection is
already gone or `data`/`str` was empty).

<!-- check:skip signature fragment; `Session` is opaque here, bodies in ssh/server.odin -->
```odin
write        :: proc(s: ^Session, data: []u8) -> int
write_string :: proc(s: ^Session, str: string) -> int
```

## Auth

<!-- check:decls reformatted onto three lines; ssh/server.odin spells the enum out over several -->
```odin
Auth_Method  :: enum u8 { None, Password, Publickey }
Auth_Methods :: distinct bit_set[Auth_Method;u8]
ALL_AUTH     :: Auth_Methods{.None, .Password, .Publickey}
```

<!-- check:verbatim ssh/server.odin -->
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

<!-- check:decls realigned into one block; ssh/server.odin declares each constant separately with its own comment -->
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

<!-- check:decls field comments stripped from ssh/limits.odin's Limits/DEFAULT_LIMITS, which changes odin fmt's column alignment -->
```odin
Limits :: struct {
	max_sessions:        int,
	max_per_ip:          int,
	handshake_seconds:   int,
	max_auth_attempts:   int,
	write_stall_seconds: int,
}

DEFAULT_LIMITS :: Limits {
	max_sessions        = 256,
	max_per_ip          = 8,
	handshake_seconds   = 20,
	max_auth_attempts   = 6,
	write_stall_seconds = 30,
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
| `max_auth_attempts` | Failed `Authenticator` verdicts on one connection before that connection stops being asked. Note what it does not do — it does **not** drop the connection, and it does **not** bound guessing across connections, because the counter lives on the `Session` and a client that reconnects gets a fresh budget (measured: ~37 guesses/second from one address). If you accept passwords, rate-limit them yourself; this is not that control. |
| `write_stall_seconds` | A client that authenticates, asks for a shell and then simply stops reading. `handshake_seconds` does not cover it — the wait inside libssh's `ssh_channel_write` does not honour the session timeout, so such a client pinned its session thread indefinitely (measured: three of them held all three slots past a 20s handshake timeout until they left at 70s, with a fourth client refused throughout). `ssh.write` now sends only what the peer has flow-control credit for, and a window that stays shut this long ends the session. Unlike the others, a **negative value disables only the disconnect** — `write` never blocks whatever this is set to, so a stalled client keeps its slot but not a wedged thread. |

Limit enforcement for `max_sessions` and `max_per_ip` happens per source
address in `remote_addr`'s numeric form; a connection that is over one of those
is dropped before the handshake even starts, so it never reaches your
`Authenticator` or `Handler`. `handshake_seconds`, `max_auth_attempts` and
`write_stall_seconds` apply to a connection already accepted.

One consequence of `write_stall_seconds` reaches the `Backend` contract:
[`write`](api-ssh.md#write) may now return a **short count**, having sent fewer bytes
than it was given, where previously it blocked until all of them were away.
`tui.run` handles this by repainting the whole screen on the next frame. A
custom `Handler` that calls `ssh.write` directly must not assume the whole
slice was sent.

## Shutdown

<!-- check:skip signature fragment; `Server` is opaque here, bodies in ssh/shutdown.odin -->
```odin
shutdown      :: proc(srv: ^Server)
shutting_down :: proc "contextless" () -> bool

DEFAULT_SHUTDOWN_SECONDS :: 5
```

A TUI leaves state on the *client's* side that only the client can undo: the
alternate screen, a hidden cursor, disabled autowrap. Killing the server
process strands every connected user in exactly that state — no prompt, no
cursor, until they work out that `reset` is what they need. `tui.run` already
restores all of it on the way out; the entire problem is giving it the chance
to run.

So `serve` handles `SIGINT` and `SIGTERM` by default and stops cooperatively:

1. the accept loop stops taking new connections;
2. every session's next `read` reports the connection as finished;
3. each app loop exits on its own, restores the terminal, and returns through
   its `Handler`, which frees the session;
4. `serve` waits for the last session to go, then returns.

Because it works by closing each session's *input*, an app gets its ordinary
teardown path — the same one a user pressing `q` takes. No special case, and
nothing for an app to opt into.

| Field | Meaning |
| --- | --- |
| `shutdown_seconds` | How long step 4 waits. `0` uses `DEFAULT_SHUTDOWN_SECONDS` (5). Negative returns immediately without waiting, which strands terminals and is only sensible when you are about to `exec` anyway. |
| `no_signal_handlers` | Set when the surrounding program owns signal handling. `serve` then installs nothing, and `shutdown(srv)` is how you stop it. |

`serve` restores whatever handlers were installed before it, so embedding it
does not leave a process with signal handling it never asked for. Signal
shutdown is process-wide by nature — a `proc "c"` handler receives only a
signal number, so there is nowhere to put a server pointer — which is the
right shape for `SIGTERM`: it means "this process is stopping". To stop one
server out of several, call `shutdown` on it.

The deadline exists because an app is free to ignore its input, and a server
that refuses to stop is worse than one that stops rudely. When it expires,
`serve` says exactly what happened and how many sessions were still running.

Measured on a real server with live `ssh` clients attached: shutdown completes
in about **0.55 s**, with every client's alternate screen and cursor restored
and every `ssh` process exiting on its own — the same with 8 concurrent
sessions as with 3, for both `SIGINT` and `SIGTERM`. The floor is
`ACCEPT_POLL_MS` (200 ms), the interval at which the accept loop re-checks
whether it has been asked to stop.

## Identity

<!-- check:decls realigned from ssh/identity.odin, which declares each constant on its own line with its own comment -->
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
`id = hex(HMAC-SHA256(secret, fingerprint)[:ID_BYTES])` — the 32-byte MAC is
truncated to `ID_BYTES` (16) bytes *first*, and then hex-encoded, so the id
is `ID_SIZE` (32) hex characters carrying 128 bits. It writes into `dst`
(which needs `ID_SIZE` bytes) and returns a string viewing it, so deriving an
id never allocates and is safe to call from a session thread's fast path.

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

<!-- check:skip signature fragment; `Audit_Event` is defined further down this page (ssh/audit.odin), not in this block -->
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

<!-- check:skip usage sketch, not a file-scope declaration -->
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
change to it as a breaking change. A ready-made fail2ban filter for these
lines ships in `deploy/` and is walked through in
[Deployment and abuse mitigation](deploy.md). What a parser may rely on:

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
  `kex_fail`, and `auth` with `ok=false` — carries `addr`.** An IPv4 client is
  always a dotted quad, never the IPv4-mapped `::ffff:127.0.0.1` form, even
  though the default bind is a dual-stack IPv6 socket that is what
  `getpeername` reports: `otsh` normalises it, so the field does not depend on
  which family the listening socket happens to be. See
  [Bind address](#bind-address).
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

That capture predates the dual-stack default, which is why its `listen` line
reads `host=0.0.0.0`; on the current default it reads `host=::`. The `addr`
lines are unaffected — an IPv4 client is still `addr=127.0.0.1`. What is new
is that a client reaching the same server over IPv6 now gets in, and logs
`addr=::1` (or its global v6 address). If you filter these lines, make sure
what reads them handles IPv6 — for fail2ban that means 0.10 or newer, which
`deploy/fail2ban/filter.d/otsh.conf` explains.

### Writing your own sink

<!-- check:verbatim ssh/audit.odin -->
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

<!-- check:skip signature fragment; `DEFAULT_HOSTKEYS` and the body are in ssh/server.odin -->
```odin
ensure_host_key :: proc(path: string, advertised := DEFAULT_HOSTKEYS) -> bool
```

Called automatically by `serve` before it binds, with `advertised` set from
`Config.hostkey_algorithms`.

If `path` already exists, it checks the permissions (see below), then reads
the key back and checks its *type* against `advertised`. A key whose type is
not in that list returns `false` and refuses to start, naming both — an
ed25519-only server pointed at an RSA key would otherwise fail key exchange
for every client with nothing in any log to say why. `advertised = "-"`
(libssh's own broader defaults) skips the type check.

Otherwise it generates a fresh ed25519 key (`ssh_pki_generate`) and writes
it to `path` unencrypted (`ssh_pki_export_privkey_file`) — but creates the
file itself first, empty, with `O_EXCL` and mode `0600`. libssh writes new
files with `fopen(path, "wb")`, i.e. `0666` masked by the process umask, and
chmod-ing afterwards does not close that window: a descriptor another process
opens inside it survives the chmod, and under a permissive umask the key is
briefly world-*writable*, so it could be replaced and not merely read.
Pre-creating the file avoids that — `fopen("wb")` on an existing file
truncates but leaves the mode alone, so `0600` is the only mode the key is
ever observable at.

<!-- check:decls signature only; body in ssh/server.odin -->
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

<!-- check:file -->
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
the connection as soon as `handle` returns. This builds as-is: save it into a
directory of its own and run `./build.sh path/to/that/directory` from the repo
root. `build.sh` takes an Odin *package directory*, not a source file, and
names the binary after it.

## See also

- [`./sshtui.md`](./sshtui.md) — serving a `tui.App` over this package instead
  of writing raw bytes yourself.
- [`./security.md`](./security.md) — the full rationale behind the auth and
  identity design above.
- `examples/whoami` — smallest full `sshtui` app, shows the auth hook and the
  audit log.
- `examples/members` — the "accept the key, gate inside the app" pattern.
