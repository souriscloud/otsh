# Security model

This page describes what `otsh` does at the SSH transport and identity layer,
what was measured, and what is left for the application and the operator.
It has not been audited. Nothing below should be read as a claim that a
server built with it is "secure" — that is not a property a library can
grant. It is a record of specific, checkable behaviour, plus an explicit
list of what is out of scope.

The source of truth is `ssh/server.odin`, `ssh/identity.odin`, and
`ssh/limits.odin`. Where this page and `README.md` disagree, this page
follows the source; one such disagreement is called out at the end.

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

> Rejecting a public key here does not only deny access — it makes the
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

## 5. Transport hardening

`ssh/server.odin` defines these defaults and applies them unless
overridden:

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
  and includes older, compatibility-oriented algorithms (the `Config.
  hostkey_algorithms` doc comment specifically mentions RSA/SHA-1-era
  support returning under `"-"`).

`ciphers` and `macs` each apply to both directions
(`Ciphers_C_S`/`Ciphers_S_C` and `Hmac_C_S`/`Hmac_S_C` respectively) —
there is no way to harden one direction and not the other.

## 6. Host key management

`ensure_host_key` generates an ed25519 key pair (`ls.pki_generate(.Ed25519,
0, &key)`) the first time `host_key_path` doesn't exist, exports the
private key unencrypted to that path via `ls.pki_export_privkey_file`, and
then calls `posix.chmod(cpath, {.IRUSR, .IWUSR})` — mode 0600 — immediately
after. Unlike the identity secret, this is not `O_EXCL`-atomic: the file is
first written by libssh under the process umask (commonly 0644) and then
chmod'd right after, so there is a brief window between "file exists" and
"file is 0600" rather than a guarantee of never being briefly wider. On
every subsequent start, an existing key is left alone and
`warn_if_world_readable` checks its mode and warns (with the exact `chmod`
command to run) if group or world bits are set.

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

```odin
DEFAULT_LIMITS :: Limits {
    max_sessions      = 256,
    max_per_ip        = 8,
    handshake_seconds = 20,
    max_auth_attempts = 6,
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
  attempts on that connection outright.

Every field follows one convention (`resolve_limits`): `0` takes the
default above, a negative value disables that specific limit, and a
positive value is used as given. The zero value of `Limits{}` is therefore
the hardened default, not an accidental free-for-all.

`limiter_acquire` runs in `session_thread` before `ls.handle_key_exchange`
— a connection that is over a limit is dropped without spending any crypto
work on it at all (`if !admitted { return }`). Measured: configuring
`max_per_ip = 3` and opening 12 simultaneous connections from one address
admitted exactly 3; the rest were refused at accept time.

Be clear about what this does not cover: `Limiter` tracks state
per-process, keyed by the numeric source address it sees. It has no view
across processes or machines, so it cannot stop a distributed flood — many
source addresses each safely under `max_per_ip` can still collectively
exceed what the host can serve. That has to be handled in front of `otsh`
(a load balancer, a firewall, a rate limiter that sees the whole picture),
not inside it.

## 8. Data handling

Per-session state lives in fixed-size fields on `Session`, filled by
`copy_cstr`, which stops at the destination length — an oversized value
from the client is silently truncated, not overflowed and not rejected:
`user_buf: [64]u8`, `term_buf: [32]u8`, `fp_buf: [96]u8`, `kt_buf: [32]u8`,
`id_buf: [ID_SIZE]u8`, `addr_buf: [64]u8`. Input from the channel goes into
`Session.input`, a `Ring` backed by `[MAX_INPUT]u8` where `MAX_INPUT :: 16
* 1024` — 16 KiB per session, not a growable buffer.

On teardown, `session_thread`'s deferred cleanup explicitly zeroes two of
those buffers — `s.fp_buf = {}` and `s.id_buf = {}` — with the reasoning
given directly in the comment: "the fingerprint and id are the user's
data; do not leave them in freed memory." The other buffers (username,
term, key type, address) are not zeroed, because none of them is treated
as sensitive in the same sense — they're connection metadata, not
credential-adjacent.

`peer_address` (in `ssh/limits.odin`) fills `Session.addr_buf` using
`posix.inet_ntop` on the socket's peer address — numeric only. There is no
reverse-DNS lookup anywhere in this path: doing one would hand every
connecting address to a DNS resolver and block the session thread while
waiting on it.

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
  `Info.id`.
- **TOFU is still TOFU** (§6): a user's first connection trusts the host
  key without independent verification unless you've published its
  fingerprint somewhere they'll actually check.
- **Distributed floods are not mitigated.** `Limiter` (§7) is
  per-process, per-source-address only.
- **There is no audit log and no session recording.** Nothing in `otsh`
  records who connected when, beyond whatever `on_connect`/`on_disconnect`
  hooks an application chooses to add itself.
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
   compatibility set behind `"-"`. Know what you are re-admitting (SHA-1,
   CBC, older key types) if you do (§5).
6. **Size `Limits` for your deployment** rather than taking the defaults on
   faith: `max_sessions`, `max_per_ip`, `handshake_seconds`,
   `max_auth_attempts`. Remember `0` = default, negative = unlimited (§7).
7. **Put a network-level limiter or WAF in front of it** if a
   distributed flood is in your threat model — `otsh`'s limiter cannot see
   across source addresses (§7).
8. **Use `ssh.ids_equal`, never `==`,** for any comparison against a
   stored id (§4).
9. **Never treat `Info.user` as identity or authorization** — it is
   client-chosen text, not a verified claim (§9).
10. **Decide what happens to a user who loses their key** — there is no
    recovery path in `otsh` — before it happens in production, not after
    (§9).
11. **Keep libssh patched.** It is the transport; its vulnerabilities are
    yours (§9).
12. **Do not expect `exec` or `subsystem` to work, and do not add them
    without understanding why they were left out** — this server's
    request handling assumes a single interactive shell channel (§8).

## 11. What has actually been checked

Not an audit. This records what was tested and what was not, so you can judge
the gap yourself rather than infer it.

**Checked, with results:**

| Area | Method | Result |
| --- | --- | --- |
| Input parser | ~45,000 fuzz iterations over random bytes, escape-shaped bytes, and every truncated prefix of valid sequences | No invariant violation: never over-consumes, never reports success without progress |
| Ring buffer | Randomised push/pop with wraparound, checking byte-for-byte ordering | No lost, reordered or invented bytes |
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

- No third-party review. Nobody with an adversarial mindset and no stake in
  this code has looked at it.
- No sanitizer run. AddressSanitizer would not link in this environment
  (Odin's bundled LLVM runtime versus the system clang), so the leak evidence
  above comes from `leaks(1)` and RSS, not from instrumented builds.
- No testing of libssh itself, and no independent verification of its
  protocol handling. Its CVEs are yours; keep the system library current and
  watch <https://www.libssh.org/security/>.
- No load, soak, or hostile-client testing beyond the limits above. Nothing
  has been run for days, or against a client deliberately violating the
  protocol at the packet level.

---

See also: [architecture](architecture.md) for how the auth path is wired,
[ssh](ssh.md) for the API reference, and `examples/members` for the
authorization pattern this page recommends.
