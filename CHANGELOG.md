# Changelog

Notable changes to otsh, newest first, in the
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format.

## Versioning

otsh is `0.MINOR.PATCH`, read the ordinary pre-1.0 way:

- **MINOR** may break your build or change behaviour you relied on. Read the
  entries for every minor you skip before moving.
- **PATCH** is fixes and backwards-compatible additions only. Going from `0.1.0`
  to `0.1.1` must never require you to change your code.

There is no compatibility promise across minors before 1.0. What stands in for
one is this file: every removal is recorded under **Removed** with what it was,
why it went, and what to do instead. Anything needing more than a paragraph gets
a section in [docs/migrating.md](docs/migrating.md).

The number itself lives in `ssh/version.odin` — `ssh.VERSION_MAJOR`,
`ssh.VERSION_MINOR`, `ssh.VERSION_PATCH` and the string `ssh.VERSION` —
re-exported from `sshtui`, so an app that imports only `otsh:sshtui` can log or
assert it:

```odin
#assert(sshtui.VERSION_MAJOR == 0 && sshtui.VERSION_MINOR >= 1)
```

You pin otsh by checking out a tag: `-collection:otsh=` points the compiler at a
source tree, so the tag is the artefact. [docs/releasing.md](docs/releasing.md)
describes how one is made.

## Unreleased

Nothing yet.

## 0.1.0 — 2026-08-01

First tagged release. Nothing precedes it, so **Added** is the package set as it
stands rather than a delta.

The other sections are here anyway. **Fixed** and **Security** record defects
found and repaired before the tag, because the source, the tests and the docs
name them and they are why several parts of the code look the way they do.
**Removed** records four symbols no release ever shipped, because setting the
pattern for later removals costs one paragraph.

What this release is not: audited. Ten defects found by independent review were
fixed and documented, which is diligence and not a certificate — see
[docs/security.md](docs/security.md). No release process had ever been executed
before this one.

### Added

**The four packages.** `otsh:tui` (cell buffer, diffing renderer, input
decoding, the `App`/`Program` loop), `otsh:ssh` (bind, key exchange, auth, pty
and shell requests, then a byte stream), `otsh:sshtui` (one `tui.Program` per
connection), and `otsh:libssh` (bindings to libssh's server API, 1:1 with the C
functions). The same app runs over SSH or against your own terminal through
`sshtui.run_local`; app code never mentions SSH.

**Pseudonymous identity.** `Session.id` is a truncated HMAC of the server's
secret over the client key's fingerprint, so a leaked database cannot be
correlated with any other service that saw the same key. `ssh.pseudonym`,
`ssh.load_or_create_secret`, `ssh.ids_equal`, `Config.identity_secret`; off
unless you configure a secret, in which case `Info.id` is empty.

**Public keys are accepted at the SSH layer on purpose.** Rejecting one makes
the client offer its next, so a gating server enumerates the user's whole agent
— measured 4 of 4 keys learned when rejecting, 1 of 4 when accepting.
Authorisation belongs in the app; `examples/members` shows the shape.

**A resource limiter.** `ssh.Limits`: `max_sessions` (default 256),
`max_per_ip` (8), `handshake_seconds` (20) and `max_auth_attempts` (6), each
field 0 for the default and negative for unlimited. `max_auth_attempts`
deliberately does not drop the connection and does not bound guessing across
reconnects; `ssh/limits.odin` says so in the field's own comment.

**Modern algorithms only, by default.** curve25519, ed25519,
ChaCha20-Poly1305 and AES-GCM. `aes128-cbc` and SHA-1 key exchange are refused.

**Graceful shutdown.** `serve` handles SIGINT and SIGTERM by default and stops
cooperatively: the accept loop stops accepting, every session's next `read`
reports the connection finished, each app exits through its own teardown —
restoring the alternate screen and the cursor — and `serve` waits for the last
one. Adds `ssh.shutdown`, `ssh.shutting_down`, `Config.shutdown_seconds`
(0 uses `DEFAULT_SHUTDOWN_SECONDS` = 5, negative means do not wait) and
`Config.no_signal_handlers` for programs that own signal handling; previous
handlers are restored on return. `sshtui.Config` carries the same two fields.
Measured at ~0.55 s with 3, 5 and 8 concurrent clients, every terminal restored.
Before this, killing the process left every connected user in the alternate
screen with no cursor and no prompt.

**An opt-in audit log.** `Config.audit` takes an `ssh.Audit_Sink`; `nil` — the
zero value — records nothing, deliberately, because every line carries the
client's numeric address and keeping that is a decision the operator makes on
purpose. Seven event kinds (`listen`, `accept`, `reject` naming which limit
tripped, `kex_fail`, `auth` with every outcome, `session_start`, `session_end`
with a duration). `ssh.audit_stderr` writes one machine-parseable `key=value`
line per event with an RFC 3339 UTC timestamp, assembled in a stack buffer and
handed to a single `write` so concurrent lines cannot interleave; nothing in the
sink path allocates. The line grammar is a documented contract in
`ssh/audit.odin`, since log filters get written against it, and client-supplied
values are scrubbed and capped so a username cannot forge fields or whole lines.
Audit lines carry the pseudonymous id, never the fingerprint.

**A real Unicode width table.** `tui.rune_width` was a hand-picked list of
ranges that got whole scripts wrong — Hebrew and Thai combining marks counted as
one column. `docs/tools/gen_width.py` now derives 455 sorted, disjoint ranges
from Python's own `unicodedata` (no network, no vendored UCD) into
`tui/width_table.odin`. Still contextless, allocation-free, ASCII fast path,
`@(rodata)`. East Asian Width W/F map to 2 and A to 1, because terminals render
ambiguous narrow and the box-drawing block `draw_box` uses is ambiguous; Mn/Me/Cf
map to 0 except U+00AD. Verified against the generator over all 1,114,112 code
points with no disagreement.

**Windows support.** `tui/local_windows.odin` implements the local backend
against the console API (raw mode, virtual terminal input and output, UTF-8 code
pages restored on exit, geometry from `srWindow`); `ssh/net_windows.odin` and
`ssh/perm_windows.odin` hold the platform halves of `wait_readable`,
`peer_address` and the host-key permission handling; `libssh` gained the vcpkg
foreign import and a correctly-sized `socket_t`. Built and run on physical
Windows 11 hardware on 2026-07-31: four packages, five examples, 67 tests (the 4
Linux-only ones correctly skip), `tracker.exe` serving real openssh sessions
locally and across a network, the console backend under `--local`, and Ctrl+C
stopping the server with a connected client's terminal restored. Mouse reporting
is not supported on that backend; ACL handling for the host key is not
implemented, so the private-key permission guarantee is weaker there.
Concurrency, resize reflow, large pastes and the limiter are still unmeasured on
Windows.

**Terminal dimension clamps.** `ssh.MAX_PTY_COLS` / `MAX_PTY_ROWS` and
`tui.MAX_COLS` / `MAX_ROWS`, bounding a client-chosen `uint32`.

**Version constants.** `ssh.VERSION_MAJOR`, `VERSION_MINOR`, `VERSION_PATCH`,
`VERSION`, re-exported from `sshtui`. This file, and
[docs/releasing.md](docs/releasing.md).

**Deployment configs, in `deploy/`.** The limiter is per-process and per-IP, so
a spread-out flood walks straight past it and no code inside the process can fix
that. Ships a hardened systemd unit, a fail2ban filter written against the audit
line format with a stdlib-only test for it, and nftables/pf rate limits, plus
[docs/deploy.md](docs/deploy.md) — which closes by saying plainly that a real
volumetric flood needs upstream filtering. Each config was run against the real
tool (fail2ban 1.1.0, nft 1.1, systemd-analyze 257) and each found a bug review
had not.

**Five examples, two tutorials, and a generated docs site.** `whoami`,
`members`, `tracker`, `guestbook`, `stopwatch`; `docs/tools/gen_api.py` produces
the API reference from the sources and CI fails if it is stale; every screenshot
in the docs is a real capture from a real `ssh` client on a real pty.

**`check.sh`.** Runs everything CI runs and counts failures. It exists because
ad-hoc verification was lying: a `./build.sh >/dev/null && for ex in ...` chain
followed by an unconditional `echo "all examples build"` prints success even
when the first command failed and the loop never ran, which is how a broken
default build target survived several "verified" runs.

### Changed

**The input path takes exactly one route.** No `channel_data_function` is
registered; `ssh.read` is the only consumer, draining libssh's own per-channel
buffer with `ssh_channel_read_nonblocking` before it ever waits on the socket.
Backpressure is SSH's own — libssh widens the client's window only as `read`
consumes — which caps buffered input at about 2 MiB per session. Client
"stderr" extended data is drained and discarded so it cannot pin the shared
transport window. `Session` fell from 17,184 bytes to 792 (measured, darwin
arm64); at `max_sessions` = 256 that is ~200 KB rather than ~4.4 MB. See
**Removed** below for the symbols this took with it.

**`libssh.threads_get_default` replaces `threads_get_pthread`.** `callbacks.h`
declares `ssh_threads_get_pthread` on every platform, but a Windows libssh only
defines `ssh_threads_get_default` and `ssh_threads_get_noop`, so every example
died at `LNK2019` there. On unix `ssh_threads_get_default` returns the same
pthread callbacks, so POSIX behaviour is unchanged. Affects you only if you use
`otsh:libssh` directly.

**`tui.run` compares against the size the screen actually took.** It used to
compare the backend's raw geometry against the clamped screen size, so a backend
reporting anything past `MAX_COLS`/`MAX_ROWS` never satisfied the test —
measured 120 `Resize` messages in 120 frames, each naming 5000x5000 while the
grid was 1000x300. Apps compute their layout from that message.

**`ids_equal("", "")` is false.** Empty ids are easy to produce, and an app
comparing against a never-populated record used to admit every anonymous client.

**The host key is created `O_EXCL` 0600.** It used to be written under the
process umask — 0666 under a permissive one, briefly world-*writable* — and
chmod'd afterwards, which does not help: a descriptor opened in that window
survives the chmod.

**`set_algorithms` fails closed.** It ignored `ssh_bind_options_set`'s return,
and libssh rejects a fully-unknown list while silently keeping its own broader
default, so a typo in `Config.ciphers` downgraded the crypto with no indication.

**The limiter acquires in the accept loop**, so an over-limit connection no
longer costs a thread and a `Session` first.

**The listening banner is ASCII on Windows.** A Windows console decodes what it
is written with the console output code page, where the arrow arrived as
mojibake; a server that may never draw a frame should not mutate the parent
shell's code page for one glyph.

**macOS and Windows CI run on demand, weekly, and on `v*` tags** rather than on
every push. The first real CI run cost 47 billed minutes — GitHub bills macOS at
10x and Windows at 2x on a private repo, and 72% of it was vcpkg rebuilding
libssh and OpenSSL from source. Linux still carries every push with the full
test suite and both the Windows and FreeBSD cross-type-checks, so a regression
on those platforms is still caught at 1x. Routine pushes cost about 3 billed
minutes.

### Removed

**`ssh.MAX_INPUT`, `ssh.Ring`, `ssh.ring_push`, `ssh.ring_pop`.** The per-session
input ring is gone, along with the constant that sized it. Nothing replaces
them: `ssh.read` was always the supported way to get bytes out of a session, and
it still is.

They existed because input used to be copied out of a libssh callback into a
fixed-size ring living inline in every `Session`. That design was wrong in a way
that permanently deafened sessions (see **Fixed**), and the fix was to delete the
second buffer rather than resize it. `MAX_INPUT` also went from 16 KiB to 4 KiB
in between, which is a detail only visible in older checkouts.

Migration: delete any use. If you sized a buffer with `MAX_INPUT`, pick your own
number — `ssh.read` fills whatever slice you give it. The ring type and its two
procedures were only ever useful for driving that ring, which no longer exists.
The longer version is in [docs/migrating.md](docs/migrating.md).

### Fixed

**A one-in-three handshake hang.** Server callbacks were installed after
`ssh_handle_key_exchange`. The client's SERVICE_REQUEST routinely arrives
coalesced with its NEWKEYS, so key exchange parses it, and libssh's message
queue only answers a service request when server callbacks are already set —
otherwise it appends the message to a list nothing drains. No SERVICE_ACCEPT was
sent, the client waited forever, and the connection died at `handshake_seconds`
with nothing logged. Coalescing is timing-dependent, so it presented as an
intermittent hang under CPU load. Installing callbacks and auth methods before
key exchange, as every libssh server example does, fixes it: 12 of 30
connections stalled before, 0 of 30 after, and a minimal C reproducer showed the
same on libssh 0.10.6, 0.11.2 and 0.12.2 alike.

**A large paste permanently deafened a session.** Pasting about 1 MiB into any
otsh app stopped it acting on input forever, while it kept repainting so the
session looked alive. It needed no hostility, only one paste of a log file.
libssh appends all CHANNEL_DATA to the channel's internal buffer and only
re-offers it to a `channel_data_function` when the *next* packet arrives; a
paste is a burst followed by silence, so whatever the ring declined sat there
with nothing to release it. Measured before: 1,048,577 bytes sent, 549,951
stranded, the quit key unseen after 60 s. After the input-path rewrite: 256 KiB
heard in 0.00 s, 512 KiB in 0.31 s, 1 MiB in ~4.7 s over 5 of 5 runs, 4 MiB in
13.4 s, every byte complete and in order, with typing latency 55–80 ms during a
concurrent 1 MiB paste.

**Two remotely reachable crashes**, both by any client the default config
accepts. Terminal dimensions arrive as a client-chosen `uint32` and were never
bounded: 10000x10000 committed 1.5 GB, and a 2e9-square pty overflowed the
allocation size so `make` returned an empty slice and the first draw panicked,
killing the process and every other session on it — a `window-change` on an
established session did it too. Separately, `Program.pending` was unbounded: an
unterminated `ESC [` followed by endless digits was never consumable, so nothing
drained it and the CSI parser rescanned the whole buffer every frame — 138% CPU
on one connection at ~20 bytes/second, memory climbing. Now 3% and flat.

**A `SIGABRT` for any app that set `context.allocator`.** `Session` was
allocated with the caller's allocator on the accept thread and freed with the
connection thread's, which is `runtime.default_context()`. An arena, a tracking
allocator, the ordinary Odin idiom — one unauthenticated TCP connection aborted
the process. Verified with an arena-backed server: crashed on connection 1
before, survives 6 now. Both sides name the heap allocator explicitly.

**Wide glyphs corrupted the row, permanently, in two ways.** Overwriting half a
double-width glyph left the other half orphaned; `flush` advances the grid index
by one per cell but the cursor by each rune's width, so the row shifted by a
column and `prev` then recorded the damage as correct — the next identical frame
emitted nothing to repair it. A box border over a CJK label did it. Separately,
`set_cell` placed a double-width glyph in the last column without its
continuation cell, reachable from ordinary drawing since `draw_text` places a
rune whenever `col < s.w`; reproduced at every screen width from 1 to 6. Both
fixed, both covered by tests.

**FreeBSD got the Linux `TIOCGWINSZ`.** `0x40087468 when Darwin else 0x5413` is
right for the two platforms it names and wrong for the third the docs claim,
where the BSD encoding applies. Every local-terminal app on FreeBSD would have
rendered at the 80x24 fallback, silently. Linux is the exception in that `when`
now, and `tests/linux_test.odin` opens a real pty and reads the size back so a
wrong value fails loudly instead of quietly falling back.

**`ssh.read` dropped the client's final keystrokes** when EOF arrived in the
same poll; the buffer is drained before the disconnect is reported.

**A closed console window on Windows killed the process before the drain.**
MSDN's `HandlerRoutine` contract says a handler returning TRUE for
CTRL_CLOSE/LOGOFF/SHUTDOWN causes the system to terminate the process
immediately — so clients were left in the alternate screen, the exact outcome
graceful shutdown exists to prevent. Those three events now park the handler
thread until the drain completes, bounded at 4.5 s to stay under the ~5000 ms
the OS lends. Ctrl+C through this handler was verified on real hardware; the
close/logoff/shutdown path is modelled on the documented contract and has not
been run.

**Four bugs the first real Windows run found**, none of which type-checking
could have caught: `build.sh` passed an extensionless `-out:`, which Odin rejects
on Windows, so not one example had ever produced a binary; `ssh_threads_get_pthread`
does not exist in a Windows libssh; four tests wrote to a hardcoded
`/tmp/otsh_test_secret`, which is `C:\tmp` there; and the banner's arrow was
mojibake under the console code page.

**A failed session-thread creation leaked the `Session`** and left the accepted
socket open with nothing servicing it. **`Server.warned_enum` was written from
every session thread without synchronisation**; it is an atomic exchange now and
still fires exactly once.

**Mouse coordinates are clamped** — unbounded on the wire, and `tui` clipped
them but apps indexing with them would not — to the last valid zero-based cell
rather than to `MAX_COLS`/`MAX_ROWS`, which was off by one against the stated
guarantee.

**`kt_buf` grew from 32 to 64 bytes.** At 32 it silently truncated 6 of 13 real
key-type names, including every certificate type and FIDO2 keys.

**Example and tooling fixes.** `tracker` summed every session's `dt` into the
shared board, aging its "just changed" marker N times too fast with N sessions;
`tracker` and `guestbook` now refuse at a cap instead of growing a shared board
without bound; `stopwatch` re-clamps its scroll state on `Resize`; `whoami`,
`guestbook` and `members` discarded `sshtui.serve`'s return, so a failed bind or
a too-old libssh printed its error and exited 0. `./build.sh` with no arguments
had a default target that no longer existed — the first command in the docs
failed. `build.sh` and `test.sh` no longer hardcode a personal compiler path,
and no longer obey a `.odin-path` that does not resolve, which broke a checkout
bind-mounted into a container. Three local-geometry tests serialise their
process-wide stdout swap, which was 1 failure in 15 Linux CI runs and looked
exactly like the wrong-`TIOCGWINSZ` bug the file exists to detect.

### Security

**libssh 0.10.6 is the floor**, checked at runtime rather than compile time
since the loaded library need not be the one the bindings were built against.
That is where the fix for CVE-2023-48795 (Terrapin) landed; `ssh.serve` refuses
to start below it.

**An all-zero 32-byte identity secret is refused.** An all-zero HMAC key makes
every id computable from a fingerprint. The secret is also zeroed before its
memory is freed.

**An existing host key of the wrong type** failed key exchange for every client
with no log line anywhere; `ensure_host_key` diagnoses it.

**Adversarial testing, and what it did and did not cover.** About 45,000 fuzz
iterations over `tui.parse_input` (random bytes, escape-shaped bytes, and every
truncated prefix of a valid sequence), `key_name` fuzzed against undersized
buffers with guard bytes, a model terminal asserting `flush`'s output
cell-for-cell against an independent implementation over randomized drawing, and
`tui.run` driven by a scripted hostile backend replaying payloads thrown at a
live server. 36 real connections then `leaks(1)` reports 0 leaks and 0 bytes,
with RSS flat from connection 12; clean under ASan on Linux. Three independent
reviewers audited the code along separate lenses (memory and the C boundary,
concurrency and lifecycle, auth and crypto) and found ten confirmed defects, all
fixed above. One of them separately confirmed by mechanical diff that all 34
callback struct fields, every enum value and all 40 bound function signatures
match the C headers.

This is diligence, not an audit. Nobody should call network-facing code secure
without a professional one. [docs/security.md](docs/security.md) records the
threat model, exactly what was and was not checked, and what is left to the
operator.
