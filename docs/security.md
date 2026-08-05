# Security model

This page describes what `otsh` does at the SSH transport and identity layer,
what was measured, and what is left for the application and the operator.

**`otsh` has never been professionally audited.** Four adversarial review
passes have been made over it by people with no stake in it, and between them
they found and fixed a good number of real defects (§11, §13) — but a review
pass is not an audit. An audit means a qualified firm agrees a scope, applies a
methodology, puts its name to a report and carries liability for it. None of
that has happened here, and finding bugs in four passes is evidence that bugs
were findable, not that the supply is exhausted. Nothing below should be read
as a claim that a server built with `otsh` is "secure" — that is not a property
a library can grant, and it is not one anybody should assert about
network-facing code without an audit that does not exist here.

What this page is instead: a record of specific, checkable behaviour, marked
throughout as measured or reasoned, plus an explicit list of what is out of
scope. §13 states in detail what the most recent pass did *not* cover.

The source of truth is `ssh/server.odin`, `ssh/identity.odin`, and
`ssh/limits.odin`. Where this page and `README.md` disagree, this page
follows the source; two such disagreements are called out at the end.

## 1. How SSH public-key auth actually works

Public-key authentication is two protocol messages, not one (RFC 4252 §7),
and the difference between them is the entire reason `otsh`'s auth callback
is shaped the way it is.

**The probe.** The client sends `SSH_MSG_USERAUTH_REQUEST` with method
`publickey`, a boolean set to `FALSE`, and a public key blob — no signature.
It is asking "would this key work?". Nothing about this message is proof of
anything: a public key is not secret, so any client can send any key it has
ever seen, including one it doesn't hold the private half of. The server
replies `SSH_MSG_USERAUTH_PK_OK` or a failure.

**The proof.** If the server answered `PK_OK`, the client re-sends the
request with the boolean `TRUE` and a signature over: the session
identifier, the username, the service name, the method name, the key
algorithm, and the key blob. The session identifier is the key-exchange
hash — a value derived from that connection's own Diffie-Hellman/ECDH
exchange, unique to it.

That last detail is what makes the proof mean something: the signature is
bound to one connection to one host key. It cannot be replayed against a
different server (the session identifier would not match its handshake),
and it cannot be replayed later against the same server (a new connection
gets a new key exchange and a new session identifier).

In `ssh/server.odin`, `cb_auth_pubkey` receives both messages as the same
callback, distinguished by a `signature_state` parameter (`ls.Pubkey_State`:
`None`, `Valid`, `Wrong`, `Error`). The handling is:

<!-- check:verbatim ssh/server.odin -->
```odin
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
```

Returning `Auth.Success` while `state == .None` does not authenticate the
session — libssh reads it as "yes, answer `PK_OK`" for the probe, not as
`SSH_MSG_USERAUTH_SUCCESS`. Only a `Success` returned at `state == .Valid`
causes `s.authenticated` to be set later in the function, after
`capture_key_identity` and `derive_id` have run and the configured
`Authenticator` (if any) has agreed.

The probe is therefore answered unconditionally with `PK_OK` whenever
`Publickey` is one of the server's offered methods, and it is never shown
to the application: `Auth_Request.fingerprint`, `Auth_Request.id`, and
`sshtui.Info.fingerprint` / `sshtui.Info.id` are only populated once
`state == .Valid`, i.e. once a signature has actually verified. A wrong
signature (`state == .Wrong`) or an error is rejected outright and never
reaches the app either.

## 2. Key harvesting — why rejecting keys is the harmful option

An SSH client that holds several keys (an agent with four loaded identities,
say) walks them in order during authentication. If the server rejects a
key, the client does not give up — it offers the next one, and the next,
until it runs out or one is accepted. A server that answers "no" to every
key it does not recognize therefore learns every public key the client
was willing to offer, before anyone has actually authenticated.

Public keys are not confidential — they are meant to be handed to servers.
But a public key is a stable, cross-service identifier: the same key
shows up wherever that user connects. A server that harvests all of a
client's keys is building a fingerprint it can potentially correlate
against any other place those same keys appear.

Measured against this server, with a client configured to offer four keys:

| Server behaviour | Public keys it learned (client offered 4) |
| --- | --- |
| Rejects unknown keys | 4 of 4 |
| Accepts the first key | 1 of 4 |

`ssh/server.odin` takes the second path: the `Authenticator` doc comment
states it directly —

> Rejecting a public key here does not just deny access — it makes the
> client offer its *next* key, and the next, so a rejecting server learns
> every public key in the user's agent.

The prescription: **do not gate access at the SSH layer.** Accept the key
unconditionally in `Authenticator` (or set no `Authenticator` at all — `nil`
accepts everyone), read `Info.id` (or `Auth_Request.id`), and decide inside
the application whether this identity gets in. A user who isn't on the
list sees a "you are not on the list" screen instead of an SSH-level
denial. They end up equally excluded, and the server has still learned
exactly one key. `examples/members/main.odin` is this pattern end to end:
it sets no `authenticate` at all and gates entirely in `view`, based on
`info.id`.

If you do set an `Authenticator` and it rejects a public key anyway,
`allow` in `ssh/server.odin` prints a one-time warning per server process
(`Server.warned_enum`) pointing back at this trade-off, so the mistake is
not silent.

## 3. The `none` method trap

Every OpenSSH client tries authentication method `none` before it tries
anything else — it is how the client discovers what the server will
accept. `Server.methods` (from `Config.methods`) defaults to `ALL_AUTH`,
which is `{.None, .Password, .Publickey}`. If `none` is offered and nothing
rejects it, `cb_auth_none` authenticates the connection immediately:

<!-- check:verbatim ssh/server.odin -->
```odin
if !allow(s, Auth_Request{user = user(s), method = .None, remote_addr = remote_addr(s)}) {
    return c.int(ls.Auth.Denied)
}
s.authenticated = true
s.auth_method = "none"
```

A session authenticated this way never went through `cb_auth_pubkey`, so
`fingerprint`, `key_type`, and `id` are all empty — `Info.auth_method` reads
`"none"` and `Info.id` is `""`.

Any app that means to use `Info.id` as identity must set
`methods = {.Publickey}` (as `examples/members` does), which removes
`.None` and `.Password` from the offered set. `allow` enforces this
independently of what libssh advertises — the comment above it notes that
`ssh_set_auth_methods` only controls what the server *offers*, and libssh
still invokes the callback if a client tries a method anyway, so the
`req.method not_in s.server.methods` check in `allow` is what actually
makes `methods = {.Publickey}` binding.

Restricting to `{.Publickey}` does not reintroduce the harvesting problem
from §2: the client's first offered key still gets the unconditional
`PK_OK` and (absent a rejecting `Authenticator`) is still accepted, so the
client stops at key one, same as before.

## 4. Pseudonymous identity

A SHA-256 key fingerprint is a good account identifier and a bad thing to
persist as one. It is *global*: the same fingerprint appears wherever that
key was used. A leaked table of raw fingerprints is directly correlatable
against any other service that logged the same keys, and anyone holding a
candidate public key can test membership by hashing it themselves — no
secret required.

`ssh/identity.odin` avoids storing the fingerprint at all. Instead:

```
id = hex( HMAC-SHA256(server_secret, fingerprint)[:ID_BYTES] )
```

`ID_BYTES :: 16` (128 bits of output, `ID_SIZE :: ID_BYTES * 2` hex
characters). The `pseudonym` proc computes this into a caller-supplied
buffer without allocating. The resulting id is:

- **stable** for as long as the secret is unchanged — same key, same id,
  every reconnect;
- **local** — meaningless to any other party, including one that saw the
  same public key elsewhere, because it does not hold `server_secret`;
- **not reversible and not testable** without the secret — an attacker with
  the whole id database still cannot recover a fingerprint or confirm a
  guessed public key against it.

`Server.secret` (type `Identity_Secret`, `bytes: [SECRET_SIZE]u8` where
`SECRET_SIZE :: 32`, plus `loaded: bool`) is loaded — or generated — by
`load_or_create_secret`, driven by `Config.identity_secret` /
`sshtui.Config.identity_secret`. Leave that path empty and `id` is always
`""`. On first run the secret is 32 random bytes from `crypto.rand_bytes`,
written by `write_private_file`, which opens the file with
`{.Write, .Create, .Excl}` (`O_EXCL`, so a race cannot silently overwrite
an existing secret) and mode `{.Read_User, .Write_User}` (0600) from the
moment the file exists — there is no window where it's created with a
broader mode and fixed up after. On every subsequent start it is read back
and `warn_if_world_readable` checks the mode again, in case something
outside the process loosened it.

Treat this file exactly like the host key: back it up alongside it, and
never commit it. Losing the secret does not expose anything — there is
nothing to reverse — it re-pseudonymises every user, so everyone who
reconnects looks like a brand-new identity to your application. That is
real operational damage (you lose the mapping to your own records), but it
is not a leak.

`derive_id` in `ssh/server.odin` computes `Session.id_buf` from
`Session.fp_buf` only when `s.server.secret.loaded` and a fingerprint was
actually captured; otherwise `id` stays empty.

For any comparison of an id against a stored value, use `ssh.ids_equal`
rather than `==`. It requires equal length and then calls
`crypto.compare_constant_time`, so a lookup does not leak, via timing, how
far a guessed id matched a real one before diverging.

Be precise about what that buys, because "constant-time comparison" is easy to
over-read. `ids_equal` returns early — and therefore in variable time — in two
cases: when either side is empty, and when the two lengths differ. It is
constant-time *given two non-empty strings of equal length*, which is the only
shape the hot path ever has, since every real id is exactly `ID_SIZE`
characters. The two early exits leak "that stored value was not a well-formed
id", which is not a secret. What they do not leak is any information about the
contents of a real id, and that is the property the function exists for.

## 5. Transport hardening

`ssh/server.odin` defines these defaults and applies them unless
overridden:

<!-- check:verbatim ssh/server.odin -->
```odin
DEFAULT_KEX :: "curve25519-sha256,curve25519-sha256@libssh.org"
DEFAULT_CIPHERS :: "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com"
DEFAULT_MACS :: "hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com"
DEFAULT_HOSTKEYS :: "ssh-ed25519"
```

Every cipher listed is an AEAD (ChaCha20-Poly1305, AES-GCM); every MAC
listed is encrypt-then-MAC; the only key exchange offered is Curve25519.
Deliberately excluded: anything depending on SHA-1, any CBC-mode cipher,
and the NIST P-256/P-384/P-521 curves. None of those are in the default
strings, and there is no fallback path to them.

Observed against a running server: negotiation settles on
`curve25519-sha256` for key exchange, `ssh-ed25519` for the host key, and
`aes128-gcm@openssh.com` for the cipher. `ssh -c aes128-cbc` and
`ssh -o KexAlgorithms=diffie-hellman-group14-sha1` are both refused —
neither algorithm is in the offered set, so there is nothing for the
client to negotiate down to.

`set_algorithms` applies four `Config` fields — `key_exchange`, `ciphers`,
`macs`, `hostkey_algorithms` — each in libssh's comma-separated algorithm
list syntax:

- left empty (the default), the hardened constant above is used;
- set to a list, that list replaces the default outright — you are
  choosing exactly what's negotiable;
- set to `"-"`, `otsh` does not call `ssh_bind_options_set` for that option
  at all, leaving libssh's own built-in default in force, which is broader
  and includes older, compatibility-oriented algorithms.

`ciphers` and `macs` each apply to both directions
(`Ciphers_C_S`/`Ciphers_S_C` and `Hmac_C_S`/`Hmac_S_C` respectively) —
there is no way to harden one direction and not the other.

**A list is validated name by name, and one bad name stops the server.** This
is stricter than checking what `ssh_bind_options_set` returns, and the gap
between the two was a real downgrade. libssh only fails that call when *every*
name in a list is unknown to it; hand it a list with five good names and one
typo and it returns success, silently drops the typo, and negotiates with
whatever is left. Measured against libssh 0.12.0, one misspelling each time:

| Configured | Was negotiated |
| --- | --- |
| `chacha20-poly1305@openssh.comTYPO,aes128-ctr` | `aes128-ctr` — a non-AEAD cipher |
| `hmac-sha2-256-etm@openssh.comTYPO,hmac-sha1` | `hmac-sha1` |
| `curve25519-sha256TYPO,diffie-hellman-group14-sha1` | the server's whole offered kex set was SHA-1 |

No error, no warning, nothing in any log — just weaker crypto than the operator
wrote down. `set_algorithms` now offers each name to a throwaway `ssh_bind` on
its own, where a single unknown name *is* an all-unknown list and does fail, and
refuses to start with the offending name quoted. A name dropped from `otsh`'s
own defaults is a warning rather than a fatal error, because those lists are
all-AEAD and all-ETM by construction so any surviving subset is still strong,
and a libssh built on a backend without chacha20-poly1305 legitimately lacks
one.

**What `"-"` actually re-admits**, measured rather than assumed — the server's
own KEXINIT as an OpenSSH client saw it, with all four fields set to `"-"` on
libssh 0.12.0: NIST curves (`ecdh-sha2-nistp256/384/521`), the SHA-2
Diffie-Hellman groups (`diffie-hellman-group14/16/18`, `group-exchange-sha256`),
CTR ciphers (`aes128/192/256-ctr`) and non-ETM MACs (`hmac-sha2-256`,
`hmac-sha2-512`). It also re-admits the post-quantum exchanges
(`mlkem768x25519-sha256`, `sntrup761x25519-sha512`), which are *stronger* than
the default list. On this version it does not re-admit SHA-1 or CBC. Earlier
editions of this page said `"-"` brought back SHA-1 and CBC; that was true of an
older libssh and is not true of 0.12. Check it against your own libssh rather
than trusting either statement.

**Overriding the kex list does not disable the Terrapin countermeasure.**
Verified by reading the proposal off the wire: with `key_exchange` set to a
single deliberately weak algorithm, the server still advertised
`kex-strict-s-v00@openssh.com` alongside it. libssh appends the strict-kex
marker unconditionally, so there is no way to configure it away through
`Config`.

## 6. Host key management

`ensure_host_key` generates an ed25519 key pair (`ls.pki_generate(.Ed25519,
0, &key)`) the first time `host_key_path` doesn't exist, and — exactly like
the identity secret — the file is created `O_EXCL` at 0600 before anything
is written into it. libssh's own writer would `fopen(path, "wb")`, i.e.
0666 masked by the process umask, and chmod-ing after the fact does not fix
that: a descriptor another process obtains inside the window survives the
chmod, and under a permissive umask that window is world-*writable*, so the
key could be replaced rather than merely read. So `otsh` opens the path
itself with `{.Write, .Create, .Excl}` and `{.Read_User, .Write_User}`,
closes it, and only then calls `ls.pki_export_privkey_file` — `fopen("wb")`
on an existing file truncates but leaves the mode alone, so 0600 is the only
mode the key is ever observable at. `ensure_private_mode` re-asserts it
afterwards as belt and braces. On every subsequent start the existing key is
kept: `warn_if_world_readable` checks its mode and warns (with the exact
`chmod` command to run) if group or world bits are set, and the key is
imported so its type can be checked against the advertised host-key
algorithms — a mismatch refuses to start rather than failing every client's
key exchange with nothing in the log to say why.

The host key is the server's identity, in the same sense a TLS certificate
is a site's identity. Clients that connect once remember it — pinned into
their local `known_hosts` — and expect it not to change. Rotating it
without warning breaks every returning client's host-key check.

That pinning is trust-on-first-use (TOFU), and TOFU has an honest gap: the
very first time a given client connects, it has nothing to check the key
against, and a standard SSH client will ask the user to accept it blind.
If an attacker can intercept that first connection, TOFU does not help.
The mitigation is out-of-band publication: run `ssh-keygen -lf hostkey` to
get the fingerprint and publish it somewhere the client can check before
connecting — a webpage, a README, wherever else you'd publish a TLS
certificate's fingerprint.

## 7. Resource limits and denial of service

`ssh/limits.odin` opens with the two failure modes it exists to prevent:
"one host can open connections until the process runs out of threads, and
a client that completes the TCP handshake but never finishes key exchange
pins a thread forever." `otsh` runs one OS thread per connection
(`thread.create_and_start_with_poly_data(s, session_thread, ...)` in
`serve`), so both are real: unbounded connections exhaust threads directly,
and a thread blocked in a handshake that never completes is a thread that
never comes back.

<!-- check:verbatim ssh/limits.odin -->
```odin
DEFAULT_LIMITS :: Limits {
    max_sessions        = 256,
    max_per_ip          = 8,
    handshake_seconds   = 20,
    max_auth_attempts   = 6,
    write_stall_seconds = 30,
}
```

- `max_sessions` bounds total concurrent connections — the blunt guard
  against thread exhaustion from any source.
- `max_per_ip` bounds concurrent connections from one source address — the
  guard against a single host opening enough connections on its own to
  starve everyone else, without needing a distributed attack to do it.
- `handshake_seconds` is the socket timeout (`ls.options_set(s.sess,
  .Timeout, &t)`) covering key exchange and authentication. Without it, a
  client that opens a TCP connection and then sends nothing holds its
  thread indefinitely — this is the "silent client" case called out in the
  package comment.
- `max_auth_attempts` counts failures accumulated in `allow` (only when an
  `Authenticator` is set and returns `false` — a `nil` Authenticator never
  fails, so this counter never engages when everyone is accepted). Its
  purpose is bounding repeated guesses against a password `Authenticator`;
  once `s.auth_failures` reaches the limit, `allow` denies further
  attempts on that connection outright. Read the correction at the end of
  §11 before relying on it: it does not bound guessing across connections.
- `write_stall_seconds` bounds how long a client may refuse to read.
  `handshake_seconds` does not cover this, and the difference was a
  service-denial hole: it is a socket timeout, and the wait inside libssh's
  `ssh_channel_write` does not honour it. A client that authenticated, asked
  for a shell and then simply stopped reading closed its flow-control window
  and pinned its session thread there indefinitely. Measured with three such
  clients against `max_sessions = 3` and `handshake_seconds = 20`: at t+22s
  all three threads were blocked — 2368 of 2368 sampled stack frames in
  `ssh::write` → `channel_write_common` → `ssh_handle_packets` → `poll` —
  the sessions ended only when the clients themselves left at t+70s, and a
  fourth client was refused with `limit=sessions` throughout. Nothing in that
  exchange is malformed; a slow reader is entitled to stop reading, so it is
  invisible to a protocol-level filter and costs the attacker one idle socket
  per pinned server thread. `ssh.write` now hands libssh only what the peer
  has credit for instead of blocking, and a window that stays shut this long
  ends the session. Re-measured with the bound at 8s: all three sessions ended
  at ~16s and the slots came back.

Every field follows one convention (`resolve_limits`): `0` takes the
default above, a negative value disables that specific limit, and a
positive value is used as given. The zero value of `Limits{}` is therefore
the hardened default, not an accidental free-for-all.

`limiter_acquire` runs in `serve`'s accept loop, immediately after
`ls.bind_accept` and before the session thread is created — a connection
that is over a limit is disconnected and freed without costing a pthread or
a single round of crypto (`if ok, tripped := limiter_acquire(&srv.limiter,
addr); !ok`). `session_thread` only *releases* the slot the accept loop
already took for it. Measured: configuring `max_per_ip = 3` and opening 12
simultaneous connections from one address admitted exactly 3; the rest were
refused at accept time.

**Size RAM for the geometry, not for the session count.** The largest
per-session cost is the cell grid, and the *client* chooses it: `pty-req`
carries the dimensions, and `tui` allocates two grids of `cols × rows × 16`
bytes, clamped at `MAX_COLS`/`MAX_ROWS` (1000 × 300). Measured RSS across 20
concurrent sessions on one server:

| Client asked for | Per session |
| --- | --- |
| 200 × 50, idle | ~0.55 MB |
| 200 × 50, each pushing 4 MiB of input | ~0.63 MB |
| 200 × 50, refusing to read | ~0.56 MB |
| **1000 × 300 (the maximum a client may request)** | **~10.4 MB** |

The ~0.55 MB floor is mostly the per-connection thread stack, not libssh —
`Session` itself is under 2 KB and the suite has a test pinning that. The jump
to 10.4 MB is entirely the grid, and it is requested, not negotiated. At the
default `max_sessions = 256` the worst case is therefore about **2.7 GB**, from
clients that need only complete a handshake and ask for a large pty. The clamps
prevent the overflow crash that an unbounded geometry used to cause (§11); they
do not make the ceiling small. Set `max_sessions` against the RAM you actually
have, at 10.4 MB a session, rather than against the thread count.

Be clear about what this does not cover: `Limiter` tracks state
per-process, keyed by the numeric source address it sees. It has no view
across processes or machines, so it cannot stop a distributed flood — many
source addresses each safely under `max_per_ip` can still collectively
exceed what the host can serve. That has to be handled in front of `otsh`
(a load balancer, a firewall, a rate limiter that sees the whole picture),
not inside it. Nothing added to `ssh/limits.odin` would change that: a
per-process limiter cannot see what it cannot see.

[`./deploy.md`](./deploy.md) is the mitigation path — kernel-level rate
limiting, a fail2ban filter over the audit log, and a hardened systemd unit,
shipped as working configuration in `deploy/`. It composes with the limits
above rather than replacing them, and it is equally plain about its own
ceiling: a genuinely distributed flood is refused, not absorbed, and a
volumetric one needs filtering upstream of the machine.

## 8. Data handling

Per-session state lives in fixed-size fields on `Session`, filled by
`copy_cstr`, which stops at the destination length — an oversized value
from the client is silently truncated, not overflowed and not rejected:
`user_buf: [64]u8`, `term_buf: [32]u8`, `fp_buf: [96]u8`, `kt_buf: [64]u8`,
`id_buf: [ID_SIZE]u8`, `addr_buf: [64]u8`. Input from the channel stays in
libssh's own per-channel buffer until `read` consumes it; that buffer is not
growable without limit, because libssh only widens the client's transport
window as this side consumes, capping what an uncooperative client can park
server-side at ~2 MiB (architecture.md, "Input flow and backpressure").

On teardown, `session_thread`'s deferred cleanup explicitly zeroes two of
those buffers — `s.fp_buf = {}` and `s.id_buf = {}` — with the reasoning
given directly in the comment: "the fingerprint and id are the user's
data; do not leave them in freed memory." The other buffers (username,
term, key type, address) are not zeroed, because none of them is treated
as sensitive in the same sense — they're connection metadata, not
credential-adjacent.

`peer_address` (in `ssh/net_posix.odin`, with a twin in
`ssh/net_windows.odin`) fills `Session.addr_buf` using
`posix.inet_ntop` on the socket's peer address — numeric only. There is no
reverse-DNS lookup anywhere in this path: doing one would hand every
connecting address to a DNS resolver and block the session thread while
waiting on it.

**What the server tells an unauthenticated client about itself.** Before any
authentication, the version banner is sent in the clear, and it is libssh's
default — observed on the wire as `SSH-2.0-libssh_0.12.0`. That names the
transport library *and its exact patch version* to anyone who opens a socket,
which is precisely what someone matching hosts against a CVE list wants. `otsh`
does not set `SSH_BIND_OPTIONS_BANNER` and offers no `Config` field for it, so
there is currently no supported way to change it short of patching.

Treat that as a fingerprinting fact to know about rather than a hole to plug.
Suppressing a version string patches nothing, and the honest mitigation is the
one already in the checklist below: keep libssh current, so the version it
announces is one with no outstanding advisory. It is recorded here because an
operator doing threat modelling should not have to discover it by running
`nc` against their own port.

Two request types are not serviced at all. `cb_exec_request` in
`ssh/server.odin` returns `ls.ERROR` unconditionally, with the comment
"this server only speaks TUI." Subsystem requests go further: `cb_
channel_open`'s `Channel_Callbacks` literal never sets `channel_
subsystem_request_function` (a field libssh's callback struct defines),
so there is no code in this repository that could answer one.

## 9. Threat model — what is not covered

Stated plainly rather than left implicit:

- **This has not been audited.** Nothing in this document is a substitute
  for one.
- **The transport is libssh.** Its CVEs are this server's CVEs. Keeping
  libssh patched is not optional maintenance, it's part of the security
  boundary.
- **Anything the application does with untrusted input is the
  application's problem.** `otsh` hands your `create`/`update`/`view`
  callbacks bytes from the remote terminal; what you parse out of them and
  what you do with `Info.user` or channel input is outside this library.
- **`Info.user` is attacker-chosen.** It is whatever string the client
  put after `ssh user@host` — there is no verification of it anywhere in
  the auth path. Never use it as an identity or authorization key; use
  `Info.id`. **And do not log it unescaped.** `otsh`'s own audit sink
  scrubs it (every byte outside `[A-Za-z0-9.:_@/+,%-]` becomes `?`, capped
  at 32), so a username of `bob ok=true id=deadbeef` lands as
  `user=bob?ok?true?id?deadbeef` and a username containing a newline cannot
  open a second line — both verified against a live server, along with CR,
  tab, `=`, control bytes and a 400-byte name. An application that prints
  the same string with `fmt.println` has none of that protection: in the
  very test that confirmed the audit path was safe, the sample app's own
  log line faithfully reproduced the embedded newline and the forged
  `otsh: audit ...` text after it. `Info.term` is client-chosen in exactly
  the same way.
- **TOFU is still TOFU** (§6): a user's first connection trusts the host
  key without independent verification unless you've published its
  fingerprint somewhere they'll actually check.
- **Distributed floods are not mitigated by anything in this process.**
  `Limiter` (§7) is per-process, per-source-address only, and no change to it
  could be otherwise. What can be done is done in front of the process:
  [`./deploy.md`](./deploy.md) ships a kernel rate limiter, a fail2ban filter
  over the audit log, and a hardened unit, and says which part of the problem
  each one actually solves. Past those, a volumetric flood is a matter for
  your provider's filtering, not for this repository.
- **The audit log is opt-in, and there is no session recording.**
  `Config.audit` records the listen, every accept, every limiter rejection,
  every key-exchange failure, every authentication attempt with its verdict,
  and every session's start and end — one machine-parseable line each, format
  documented in [`./ssh.md`](./ssh.md#audit). But it is `nil` by default and
  a `nil` sink records nothing, because every line carries the client's
  numeric address and keeping that record is the operator's decision to make.
  Nothing anywhere records what was typed or drawn inside a session, and
  nothing logs a password or a key fingerprint.
- **There is no account recovery.** Identity is the key. A user who loses
  their private key is, as far as `Info.id` is concerned, a new person —
  there is no mechanism here for re-linking them to their old id. Decide
  what that means for your application before it happens to a real user.

## 10. Hardening checklist

Before exposing an `otsh` server to the internet:

1. **Decide your `methods`.** If the app relies on `Info.id`, set
   `methods = {.Publickey}` (§3) — otherwise `none` (or `password`, if
   offered) can authenticate a session with no key and no id at all.
2. **Do not set an `Authenticator` that rejects unknown public keys.**
   Accept at the SSH layer; authorize inside the app using `Info.id`
   (§2). If you inherited an `Authenticator` that does reject keys, watch
   for the one-time enumeration warning on startup and reconsider it.
3. **Set `identity_secret`.** Without it `Info.id` is always empty and
   you have no option but to key off the fingerprint or the (untrusted)
   username. Back the secret file up alongside the host key; both must
   survive together or neither is useful (§4, §6).
4. **Publish the host key fingerprint out of band** (`ssh-keygen -lf
   hostkey`) before advertising the server's address, so a real user's
   first connection isn't blind trust (§6).
5. **Leave `key_exchange`, `ciphers`, `macs`, `hostkey_algorithms`
   empty** unless a specific, known client needs the broader
   compatibility set behind `"-"`. Know what you are re-admitting if you do,
   and check it against your own libssh rather than against this page (§5).
6. **Size `Limits` for your deployment** rather than taking the defaults on
   faith: `max_sessions`, `max_per_ip`, `handshake_seconds`,
   `max_auth_attempts`, `write_stall_seconds`. Remember `0` = default,
   negative = unlimited (§7). Size `max_sessions` against RAM at **10.4 MB a
   session**, the measured cost of the largest pty a client may ask for — not
   against the thread count (§7).
7. **Put a network-level limiter in front of it** if a distributed flood is
   in your threat model — `otsh`'s limiter cannot see across source
   addresses (§7). [`./deploy.md`](./deploy.md) has the ruleset
   (`deploy/nftables-ratelimit.conf`, with pf equivalents), a fail2ban filter
   for the audit log, and a hardened systemd unit; it also states where that
   stops being enough.
8. **Check that whatever is in front of it covers IPv6.** `ssh.DEFAULT_HOST`
   is the IPv6 wildcard `"::"`, so unless you set `Config.host` the server
   answers on both families and a host with a global IPv6 address is reachable
   over it. A firewall, rate limiter or fail2ban action written only for IPv4
   is not a partial control here — it is no control at all for the v6 half,
   and it fails silently. The shipped `deploy/` artifacts are paired for both
   families; anything you wrote yourself needs checking. Binding
   `Config.host = "0.0.0.0"` is the deliberate way to stay IPv4-only. See
   [ssh.md § Bind address](./ssh.md#bind-address).
9. **Decide whether you want an audit log**, then set `Config.audit` (or
   leave it `nil`) on purpose rather than by default. `ssh.audit_stderr`
   gives you one parseable line per connection, auth attempt and session,
   which is what a log filter or an incident review needs — at the cost of
   a file recording every peer address that reached your server. Both
   choices are defensible; drifting into one is not (§9).
10. **Use `ssh.ids_equal`, never `==`,** for any comparison against a
    stored id (§4).
11. **Never treat `Info.user` as identity or authorization** — it is
    client-chosen text, not a verified claim (§9).
12. **Decide what happens to a user who loses their key** — there is no
    recovery path in `otsh` — before it happens in production, not after
    (§9).
13. **Keep libssh patched.** It is the transport; its vulnerabilities are
    yours (§9).
14. **Do not expect `exec` or `subsystem` to work, and do not add them
    without understanding why they were left out** — this server's
    request handling assumes a single interactive shell channel (§8).

## 11. Independent audit findings

Three independent reviewers audited this code with no stake in it, along three
lenses: memory and the C boundary, concurrency and lifecycle, and auth and
crypto. Between them they found ten confirmed defects the author had missed,
including two remote crashes. All are fixed; the details are kept here because the *class* of
mistake is more useful than the patch.

**Two were critical, both reachable by any client the default config accepts:**

| Was | Now |
| --- | --- |
| Terminal dimensions arrive as a client-chosen `uint32` and were never upper-bounded. `10000x10000` committed 1.5 GB; a 2e9-square pty overflowed the allocation size, `make` returned an empty slice, and the first draw panicked — **killing the process and every other session on it**. A `window-change` on an established session did it too. | Clamped at both layers (`MAX_PTY_COLS`/`MAX_PTY_ROWS` in `ssh`, `MAX_COLS`/`MAX_ROWS` in `tui`). Verified: 65535², 2³¹-1², and 2e9² pty requests all leave the server running. |
| `Program.pending` was unbounded. An unterminated `ESC [` followed by endless digits was never consumable, so nothing drained it, and `parse_csi` rescanned the whole buffer every frame. Measured **138% CPU on one connection at ~20 bytes/second**, memory climbing. | `MAX_INCOMPLETE` (256 bytes) forces a resync. Same attack now: **3% CPU, memory flat** (+48 KB across 2.4 MB of attack traffic). |

**Two more from the memory/C-boundary lens, both confirmed:**

- **`Session` was allocated with the caller's `context.allocator` and freed with
  the connection thread's.** Odin threads get `runtime.default_context()` unless
  told otherwise, so those are different allocators. Any consumer setting
  `context.allocator` — an arena, a tracking allocator, the ordinary idiom, and
  exactly what you would reach for to check the leak claims above — got a
  **SIGABRT from one unauthenticated TCP connection**. Per-connection state now
  comes from an explicit heap allocator on both sides.

  The first fix for this was wrong and worth recording: routing both sides
  through the caller's allocator still aborted, because an arena is neither
  thread-safe nor able to free individual objects. It also surfaced a second
  instance — moving `limiter_acquire` into the accept loop had put the limiter's
  map keys on the same cross-thread path. Both now name the heap allocator
  explicitly.

- **Overwriting half a double-width glyph corrupted the rest of the row,
  permanently.** `flush` advances the grid index by one per cell but the real
  cursor by each rune's width, which only stays in step while every wide lead
  has exactly one continuation cell. A box border or a fill landing on one column
  of a CJK label broke the pairing, shifted everything after it by a column, and
  — because `prev` then recorded those cells as correctly painted — an identical
  next frame emitted nothing to repair it. `set_cell` now blanks the orphaned
  half when a pair is broken. Three regression tests cover it, including the
  "modal over a CJK label" case that reaches it through ordinary drawing.

**Six more, confirmed and fixed:**

- `set_algorithms` ignored `ssh_bind_options_set`'s return. libssh rejects a list
  whose entries are all unknown and *silently keeps its own broader default* —
  so a typo in `Config.ciphers` downgraded the negotiated crypto with no
  indication. It now refuses to start.
- The host key was written by libssh under the process umask — `0666` under a
  permissive one, i.e. briefly world-**writable**, and a descriptor opened during
  that window survives the later `chmod`. The file is now created `O_EXCL` at
  `0600` before libssh writes into it. Verified under `umask 000`: the only mode
  ever observable is `0600`.
- `ids_equal("", "")` returned **true**, and empty ids are easy to produce (no
  identity secret, `none`/`password` auth). An app comparing against a record
  whose id was never populated would have admitted every anonymous client. Empty
  ids now never compare equal.
- A 32-byte all-zero identity secret was accepted. An all-zero HMAC key is a
  published key: every id becomes computable by anyone holding a fingerprint.
  Now refused.
- The identity secret was left in freed heap memory. Now zeroed before release.
- An existing host key of the wrong type was accepted, then failed key exchange
  for every client with **no log line anywhere** — a silent, total outage.
  `ensure_host_key` now checks the key's type against the advertised algorithms
  and explains the mismatch.

**Two corrections to this document, from measurement:**

- `max_auth_attempts` was described as bounding password guessing. It does not:
  the counter is per-`Session`, so reconnecting resets it — measured ~37
  guesses/second from one address. It also does not drop the connection. If you
  accept passwords, rate-limit them yourself.
- `"-"` was described as re-admitting SHA-1 and CBC. On libssh 0.12 it does not;
  it re-admits CTR ciphers and non-ETM MACs.

**Also tightened, from suspected findings:** mouse coordinates arrive as
unbounded attacker-controlled integers and are now clamped (`tui` clipped them,
but apps indexing arrays with them would not); `derive_id` called `free_all` on
the whole thread's temp arena and now scopes its scratch space; `kt_buf` was 32
bytes, which silently truncated 6 of 13 real key-type names including every
certificate type and FIDO2 security keys — now 64.

**One accepted limitation:**

- `gssapi-with-mic` is handled inside libssh and never reaches `allow()`, so
  `Config.methods` cannot deny it. On a Kerberos-joined host with a keytab,
  libssh can complete that exchange with no otsh policy applied. It is contained
  by the `s.authenticated && s.chan != nil && s.shell` gate in `session_thread`,
  which is load-bearing for exactly this reason — do not remove it. There is
  currently no way to express "deny GSSAPI" in `Config`.

**What the auditors verified as sound** (so you know what has real coverage):
the central claim that an unverified public key cannot authenticate or reach
application code — attacked three ways, including a hand-rolled client that
sends `PK_OK` and immediately tries to open a channel; HMAC parameter order and
truncation; the constant-time comparison; that the algorithm strings really do
land on the wire in both directions; that overriding the kex list does *not*
disable libssh's Terrapin countermeasure (it is appended unconditionally); that
`ssh_version` has the semantics the guard assumes; that session teardown leaks
nothing across 40 cycles; and that the one-thread-per-session invariant genuinely
holds, which is what makes the unsynchronised `Session` fields safe.

## 12. What has actually been checked

Not an audit. This records what was tested and what was not, so you can judge
the gap yourself rather than infer it.

**Checked, with results:**

| Area | Method | Result |
| --- | --- | --- |
| Input parser | ~45,000 fuzz iterations over random bytes, escape-shaped bytes, and every truncated prefix of valid sequences | No invariant violation: never over-consumes, never reports success without progress |
| Input delivery | End-to-end byte accounting over a real ssh client: pastes of 4 KiB–4 MiB followed by a keystroke | No lost, reordered or invented bytes; every payload delivered exactly (e.g. 1,048,577 sent, 1,048,577 seen by the app) |
| `key_name` | Fuzzed against undersized buffers with guard bytes | No write past the slice |
| Session lifecycle | 36 real SSH connections, then `leaks(1)` | **0 leaks, 0 bytes.** RSS flat from connection 12 to 36 |
| Auth path | Code review of `cb_auth_pubkey` | An unverified probe returns before identity capture and before the `Authenticator`; only a signature-verified key reaches app code |
| Transport | Live negotiation against OpenSSH | curve25519 + ed25519 + AES-GCM; `aes128-cbc` and SHA-1 kex refused |
| libssh version | Runtime guard | Refuses to start below 0.10.6 (the CVE-2023-48795 / Terrapin fix) |

**Fixed during that pass:**

- A failed session-thread creation leaked the `Session` and left the accepted
  socket open with nothing servicing it. Now dropped cleanly.
- `Server.warned_enum` was written from every session thread without
  synchronisation — a benign but real data race. Now an atomic exchange, still
  firing exactly once (verified across 9 rejected keys on 3 connections).

**Not checked:**

- No professional audit. Four adversarial passes have been made by people who
  volunteered for them (§11, §13), and their findings are fixed — but none was
  a paid engagement with a scope, a methodology and a report you could hold
  anyone to. Treat them as evidence that the obvious classes were hunted, not
  as sign-off. §13's "What this is not" lists what an audit would additionally
  have covered.
- No continuous sanitizer coverage. The suite passes under
  `-sanitize:address` and an ASan-built server has now served a full hostile
  session without a report (§13), but those are local runs on one machine —
  none of it is wired into CI, so nothing catches a regression between runs,
  and the leak numbers above still come from `leaks(1)` and RSS rather than
  from instrumented builds.
- No testing of libssh itself, and no independent verification of its
  protocol handling. Its CVEs are yours; keep the system library current and
  watch <https://www.libssh.org/security/>.
- No multi-day soak, and no packet-level protocol violation. §13 adds a
  hostile-client pass over a live channel, but nothing here has been run for
  days, and no test deliberately corrupts the SSH framing below the layer
  libssh parses.

## 13. Fourth review pass — methodology, findings, and limits

### What this is not

**This was not an audit, and nothing in this section may be cited as one.**
Read this part before the findings, because the findings are the part that
looks like assurance and is not.

This pass was one reviewer working against the source and a running server for
a matter of hours. It has no scope document agreed in advance, no independent
sign-off, no second reviewer checking its conclusions, and nobody's name or
liability attached to it. It found real defects, which is evidence that
defects were reachable by an afternoon of adversarial effort — not evidence
that the remaining ones are few. **A reviewer who finds bugs has demonstrated
the presence of bugs and nothing whatsoever about their absence.**

Specifically, a real audit would cover all of the following, and this pass
covered none of them:

- **A threat model someone signs.** There is no agreed statement of who the
  adversary is, what they are assumed to be able to do, and which properties
  are being claimed — so there is no way to say what "passing" would have
  meant. §9 is the author's own sketch, not a reviewed artefact.
- **Cryptographic implementation review of libssh.** Every claim on this page
  about ciphers, MACs, key exchange and signature verification is a claim about
  what libssh was *asked* to do and what it *reported* doing. Nothing here
  inspects libssh's own key handling, nonce management, constant-time
  properties or state machine. otsh is a few hundred lines of policy sitting on
  a large C library that does all of the actual cryptography, and that library
  was treated throughout as a trusted black box.
- **Supply chain.** No verification of the libssh binary being linked, its
  build provenance, the Odin toolchain, the dependency graph of anything in
  `deploy/`, or the integrity of this repository's own history. The identity
  and host-key files are examined as artefacts on disk; nothing checks how the
  software that writes them got onto the machine.
- **Side channels.** No timing analysis beyond reading `ids_equal` and
  reasoning about it (§4). No measurement of timing, cache, or
  power/electromagnetic behaviour anywhere in the auth path. The statement
  that a comparison is constant-time rests on `crypto.compare_constant_time`
  doing what its name says, which was not verified at the instruction level.
- **Formal verification, and liability.** Nothing here is proved. Nobody is
  answerable for what it missed.

The sentence from the top of this page still stands without qualification:
**`otsh` has not been professionally audited, and nobody should describe
network-facing code as "secure" on the strength of a review like this one.**
Four passes by unpaid reviewers do not add up to one audit; they add up to
four passes.

### Method

The instruction this pass was given, and followed, was to **prefer measurement
to reading** — because the previous rounds were repeatedly embarrassed by
confident prose that measurement later disproved (a libssh behaviour comment
that turned out backwards, and two "verified dead ends" that were not).

So the working method was: build a configurable probe server against the real
packages, drive it with a real OpenSSH client and with hand-written Python
clients (paramiko) that can violate what OpenSSH will not, sample the server's
threads while it misbehaved, and diff behaviour A/B by toggling the code path
under test. Every quantitative claim added to this page in this pass came off a
terminal, and every one is marked below as **measured** or **reasoned**.

That discipline caught one of this pass's own errors and is worth recording as
a caution. The first stalling-client experiment appeared to show three session
threads pinned for 60 seconds, and it would have been easy to write that up.
Checking *where* the threads actually were showed them idle in `poll`, not
blocked: the probe app drew a static screen, so the diff renderer emitted
almost nothing and the client's window never drained. The sessions had simply
stayed open as long as the clients held them, which is ordinary behaviour. The
finding below is the corrected version, taken after the probe was changed to
emit a genuinely different frame every tick, and confirmed by stack sample
rather than by inference from timing.

### What was examined, and what came of it

| # | Area | Method | Outcome |
| --- | --- | --- | --- |
| 1 | Algorithm lists: partial validity | **Measured** — configured lists with one misspelled name, read the server's KEXINIT off the wire | **Defect, fixed.** A single typo silently downgraded the negotiation (§5) |
| 2 | Algorithm lists: fail-closed on an all-unknown list | **Measured** — bogus list, server refused to start | Behaves as documented |
| 3 | `"-"` opt-out | **Measured** — all four fields set to `"-"`, proposal read off the wire | Broader than the default but not weak on libssh 0.12; this page's earlier description was wrong and is corrected (§5) |
| 4 | Terrapin countermeasure under an overridden kex list | **Measured** — proposal read off the wire | `kex-strict-s-v00@openssh.com` still advertised; not configurable away |
| 5 | libssh version floor | **Reasoned** — read `check_libssh_version` against `ssh_version` semantics | Unchanged from the previous pass, which measured it |
| 6 | Id derivation | **Measured** — compared against Python `hmac`/`hashlib` | Exactly `HMAC-SHA256(key=secret, msg=fingerprint)[:16]`; the three plausible wrong constructions all differ. Pinned as a test vector |
| 7 | `pseudonym` guards | **Measured** — unloaded secret, empty fingerprint, undersized destination, 4 KiB attacker-shaped fingerprint | All refused or handled; now covered by tests |
| 8 | `ids_equal` constant-time claim | **Reasoned** — read the early-return paths | Constant-time only given equal non-empty lengths; the page now says so precisely (§4) rather than claiming more |
| 9 | Mid-session re-authentication | **Measured** — authenticated with key A, opened a shell, then sent a second signed userauth with key B | Cannot mutate a running session's identity: the second attempt never reached the callback, no second `auth` audit line, `id` unchanged, libssh dropped the connection |
| 10 | Unverified pubkey probe | **Reasoned** — re-read `cb_auth_pubkey` against the previous passes' three attacks | No new path found; the probe still returns before identity capture and before the `Authenticator` |
| 11 | Client that stops reading | **Measured** — three stalling clients, thread stack sampling, A/B against the old code path | **Defect, fixed.** Session threads pinned indefinitely; `handshake_seconds` does not cover it (§7) |
| 12 | Per-session memory ceiling | **Measured** — RSS across 20 concurrent sessions in four conditions | ~0.55 MB idle, **~10.4 MB at the largest pty a client may request** — now documented (§7) |
| 13 | Memory safety under hostile input, with AddressSanitizer | **Measured** — 45 hostile-input classes over live channels, 122 sessions | **No ASan report from otsh code.** One report traced to the toolchain, not to otsh — see below |
| 14 | Test suite under AddressSanitizer | **Measured** | 80 tests, no report |
| 15 | Audit-log forgery | **Measured** — usernames and `$TERM` containing spaces, `=`, newline, CR, tab, control bytes, 400 bytes | No forged field or line; every hostile byte scrubbed to `?`. But an *application* that logs `Info.user` itself has no such protection (§9) |
| 16 | Version banner | **Measured** — read off the wire | Discloses the exact libssh version pre-authentication; not configurable (§8) |
| 17 | Startup failure paths | **Reasoned** — read `serve`'s early returns | **Defect, fixed.** The `Server`, its limiter map and the loaded identity secret were leaked on every startup-failure path, the secret un-zeroed |
| 18 | `copy_cstr`, the `*_buf`/`*_len` pairs, `peer_address` | **Reasoned** — line-by-line read of every `cstring` conversion and every length variable | No over-read found. `copy_cstr` tests `i < len(dst)` before `p[i]` and Odin short-circuits, so an attacker-length string truncates rather than over-reads; no `_len` can exceed its buffer or go negative; `peer_address`'s manual NUL scan is bounded by `len(dst)` regardless of what `inet_ntop` wrote |
| 19 | `audit.odin` fixed-buffer writers | **Reasoned** — worst case computed per event kind | No off-by-one. Longest possible line (`session_start`, every field at its cap) is 289 bytes + newline against `AUDIT_LINE_MAX` 320, and every writer funnels through one bounds-checked `audit_put_byte`, so `n` saturates rather than overflowing. `audit_stderr`'s one-byte holdback for the newline is exactly right |
| 20 | `tui` parsers indexing on attacker bytes | **Reasoned** — read `parse_csi`, `parse_sgr_mouse`, the UTF-8 path, the width table | Bounds-safe. Parsed CSI parameters can integer-overflow but are never used as an index; the width-table binary search is unreachable for control bytes, so an ESC can never enter the cell grid — which is what stops escape injection into another user's terminal in a multi-user app |
| 21 | Mouse coordinate clamping | **Reasoned** | **Hardened** — clamped to the package maximum, not the live screen (see below) |

### The three defects, and how to reproduce them

**1. One typo in an algorithm list silently downgraded the connection.**
`ciphers = "chacha20-poly1305@openssh.comTYPO,aes128-ctr"` started a server
that negotiated `aes128-ctr` — a non-AEAD cipher — with no diagnostic
anywhere. The same shape produced `hmac-sha1`, and an all-SHA-1 kex offer.
Cause: `ssh_bind_options_set` only fails when *every* name is unknown, so
`set_algorithms`'s existing fail-closed check could not see a partial drop.
Fixed by validating each name on its own against a throwaway bind. Reproduce
by setting any of the four `Config` algorithm fields to a list with one
misspelling: the server now refuses to start and names the entry. Regression
tests in `tests/crypto_config_test.odin`, including one asserting libssh's
accept-a-mixed-list behaviour, so the premise itself is pinned.

**2. An authenticated client that stopped reading pinned its session thread
indefinitely.** Measured with three such clients against `max_sessions = 3`:
at t+22s, 2368 of 2368 sampled frames were in `ssh::write` →
`channel_write_common` → `ssh_handle_packets` → `poll`, the sessions lasted
until the clients left at t+70s, and a fourth client was refused with
`limit=sessions` the whole time. `handshake_seconds` does not bound it — the
wait inside `ssh_channel_write` does not honour `SSH_OPTIONS_TIMEOUT`. Fixed
by giving libssh only what the peer has flow-control credit for and ending a
session whose window stays shut past `Limits.write_stall_seconds` (default 30).
Re-measured at an 8-second bound: sessions ended at ~16s and the slots came
back. Reproduce with any client that authenticates, requests a pty and never
reads; `tests/stall_test.odin` records the numbers and pins the limit's
defaults, since the socket behaviour itself needs a live server.

Two consequences of that fix are worth knowing. `ssh.write` may now return a
short count, so `tui.run` marks the screen for a full repaint whenever a frame
is only partly sent — otherwise its diff baseline would describe a screen the
terminal is not showing, the same failure mode as the wide-glyph orphan in
§11. And `tui`'s own alternate-screen enter/exit sequences are now retried
briefly rather than written once, because half of the exit sequence strands the
user's terminal.

**3. `Limits` convention vs. the stall bound — caught reviewing this pass's own
fix.** A separate read-through of the C boundary, done after the fix above
landed, found that the first version of it bundled two things together: setting
`write_stall_seconds` negative meant "no limit" by the convention every other
field follows, and that skipped the window check entirely — handing `write`
straight back to libssh's blocking path and restoring the exact thread pin the
limit exists to prevent. An operator writing `-1` to be generous with slow links
would have re-enabled the DoS. Now separated: `write` never blocks whatever the
setting, and the limit governs only whether a stalled session is eventually
disconnected. **Measured** both ways after the change — at `-1` the session
threads sit in `wait_readable` rather than in `ssh::write`, and at `8` they
still tear down at ~16s.

**4. Every startup-failure path in `serve` leaked, including the identity
secret.** A `serve` that returns `false` — bad algorithm list, unusable
identity secret, `ssh_bind_new` failure, `bind_listen` failure — dropped the
`Server`, its limiter map and its cloned keys on the floor, and handed the
32-byte HMAC key back to the allocator without zeroing it. Benign when the
process is about to exit, which is the common case; not benign for a caller
that treats `false` as recoverable, and the un-zeroed secret is the same class
of mistake §11 already records fixing once. Now released, and the secret
scrubbed, on every path before the accept loop takes ownership.

**Also hardened, from the same C-boundary read-through.** None of these was
shown to be reachable; each is a place where the code was relying on something
it did not check:

- `Pty.term` was documented as borrowing `Session.term_buf` but the struct
  literal in `cb_pty_request` never assigned it, so the public field was
  permanently `""`. A plain correctness bug — `term(s)` worked, `s.pty.term`
  did not.
- `copy_cstr` had no nil guard. Every one of its four call sites checks, so
  nothing was reachable; the fifth call site somebody adds would have been a
  NULL dereference on a connection thread.
- `take_input` returned libssh's byte count unclamped. It becomes a slice
  bound in every caller and `ssh.read` is public, so it is now
  `min(int(n), len(buf))` rather than trusting the library's contract.
- `ssh_event_new`'s result was passed straight to `ssh_event_add_session`
  without a nil check, while the teardown block guards `s.event != nil` —
  the inconsistency being the tell that nil was thought reachable.
- Mouse coordinates were clamped to `MAX_COLS`/`MAX_ROWS` rather than to the
  live screen. Those numbers come off the wire, not from the client's real
  terminal, so `ESC [ < 0 ; 999 ; 299 M` parsed to (998, 298) on an 80×24
  session. Nothing inside `tui` indexes by them, but `grid[m.y][m.x]` is the
  obvious thing for an app to write and it would have been out of bounds.
  `run` now narrows them to the live screen before any app sees them, and
  `parse_input`'s own comment says what its weaker bound does and does not
  mean.

### The AddressSanitizer result, stated carefully

The instruction was to extend the previous pass's ASan run to a *live session
under hostile input*, and that was done: an ASan-instrumented server took 45
classes of hostile input across 123 sessions — pty geometries from `0x0` to
`2³²-1`, a 48-step window-change storm, 300-byte usernames and `$TERM`s,
malformed and overlong and surrogate UTF-8, unterminated CSI/OSC/DCS
sequences, mouse coordinates at `2³²-1`, 4 MiB pastes, client-sent stderr
floods, oversized `env` requests, `exec`/`subsystem`/`x11` requests, 13
channels on one connection, 120 rapid connect/close cycles, 40 mid-frame RSTs,
and a stalling client — **with no AddressSanitizer report from otsh code.** The
server was checked to be alive after the suite and to still accept and serve a
brand-new client, rather than merely "not having crashed yet". The suite passes
under ASan too: 80 tests, no report.

That run produced exactly one ASan report, and it was **not an otsh defect**,
which is worth spelling out because it would be easy to present either way and
both would mislead. ASan flagged a stack-buffer-overflow in `tui::screen_clear`
on the first frame any app draws. It reduces to a 40-line Odin program
containing no otsh code: an 11-byte struct passed **by value** gets a 12-byte
store into its 11-byte incoming stack slot. Odin's own codegen, on
`dev-2026-07a` / arm64 macOS; the write lands in the callee's own frame
padding, which is why it has never caused an observable failure. A local
variable of the same type does not trigger it, and padding or aligning the type
to 12 bytes does not either.

`tui.Style` — `Color`, `Color`, `Attrs` — is exactly 11 bytes, so it hit this
on every call taking a `Style`. It now carries `#align(4)`, which rounds it to
12 and puts the store back in bounds. `Cell` is 16 bytes either way, so the
cell grid costs nothing extra. **This is a workaround for a toolchain issue,
not a fix for an otsh memory-safety bug** — but it matters, because until it
was applied ASan aborted on the first frame of every session and could not
reach anything else. Any future sanitizer work on this codebase depends on it,
and it is the reason the earlier claim that "an ASan-built `tracker` served a
full session without a report" should be treated as version-specific rather
than as a standing property.

### What this pass could not determine

Stated so the gaps are visible rather than implied:

- **Whether `ssh_channel_write`'s unbounded wait is intended libssh behaviour
  or a libssh bug.** The blocking was measured and the stack confirmed; no
  attempt was made to read libssh's source to establish which. The fix does not
  depend on the answer, but the upstream question is open.
- **Whether the write-stall bound has a false-positive rate on genuinely slow
  links.** 30 seconds was chosen to be generous and was verified not to disturb
  a local interactive session. Nothing tested it over a lossy or
  high-latency path, which is exactly where an honest client could be cut off.
- **Whether anything else in otsh trips the 11-byte-struct codegen issue.**
  `tui.Style` was found because it is on the hot path. `Color` is 5 bytes and
  also passed by value; no report was produced for it during these runs, but
  runs stop at the first error per code path and no exhaustive search was made.
- **Anything about libssh's internals**, per "What this is not" above.
- **Behaviour on Windows and FreeBSD.** Everything measured here ran on arm64
  macOS against libssh 0.12.0. The cross-platform type-checks still pass, but
  no measurement on this page was repeated on another platform.
- **Whether `max_auth_attempts` interacts safely with an `Authenticator` that
  returns inconsistently.** The accounting was read and looks correct; it was
  not driven with a deliberately flapping `Authenticator`.

---

See also: [architecture](architecture.md) for how the auth path is wired,
[ssh](ssh.md) for the API reference, and `examples/members` for the
authorization pattern this page recommends.
