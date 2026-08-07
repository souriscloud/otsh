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

### Added

- **Static linking, so a binary can ship to a machine that has no libssh** —
  `otsh build --static` and `otsh build --fully-static`, with
  `otsh flags --static` printing the same for a Makefile or an IDE. The
  motivating case is distributing an executable to hosts whose packages you do
  not control, or into a scratch container: a `FROM scratch` image containing
  nothing but a fully static `examples/tracker` was built, run, and connected
  to with a real ssh client over a pty from the host — a frame rendered and `q`
  quit cleanly.

  **This is a security trade, not a free win.** A statically linked libssh
  means the next libssh CVE requires rebuilding and redeploying your binary,
  where a dynamic one is fixed by the system package manager and a restart. The
  version really is frozen in — a static binary carries libssh's own
  `SSH-2.0-libssh_0.12.2` banner, a dynamic one carries none of it. It also
  changes what the 0.10.6 Terrapin floor means: `check_libssh_version` still
  fires, but it now tests a version fixed at link time rather than whatever the
  host has installed, so the floor becomes a build-time assertion instead of a
  runtime guard. The dynamic build remains the default and is unchanged.

  What each platform can actually do, all measured rather than assumed:

  | Platform | libssh from an archive | Nothing dynamic at all |
  | --- | --- | --- |
  | macOS | yes | **impossible** — Apple ships no static libc |
  | Linux, glibc | yes | yes, if libssh was built without GSSAPI |
  | Linux, musl | yes, after building libssh yourself | yes |

  - **macOS cannot link a fully static executable**, and `--fully-static` says
    so and exits rather than shipping a flag that fails confusingly: there is
    no `libSystem.a` or `libc.a` anywhere in the SDK and clang stops at
    `ld: library 'crt0.o' not found`. `--static` there drops libssh and
    OpenSSL, leaving only libSystem, zlib and Kerberos — all part of macOS.
    `examples/tracker` goes from 654,792 to 5,363,960 bytes.
  - **Debian's own `libssh.a` cannot be fully statically linked**, because it
    is built with GSSAPI and MIT Kerberos ships no static libraries at all on
    Debian or Ubuntu — `libkrb5-dev` contains not one `.a` file. otsh inspects
    the archive for `gss_acquire_cred` rather than guessing, and names the fix.
    `--static` works there (7,940,088 bytes, no libssh); `--fully-static` needs
    a libssh built with `-DWITH_GSSAPI=OFF` (8,379,912 bytes).
  - **Alpine ships no static libssh at all** — `libssh-dev` contains exactly
    `usr/lib/libssh.so`, and `libssh2-static` is a different library — so otsh
    reports that instead of handing the linker a broken command line. With
    libssh built from source it produces a genuinely static musl binary
    (16,194,256 bytes, 4,923,784 stripped; `ldd` says "not a dynamic
    executable").
  - **glibc's static-NSS warnings do not affect an otsh server.** A `-static`
    glibc link warns about `getaddrinfo` and `getpwnam`; the resulting binary
    was run and driven through a real ssh session anyway. otsh binds a numeric
    address and only calls `getpeername`/`inet_ntop` on an accepted socket, so
    no NSS backend is ever loaded. The caveat still applies to app code that
    resolves hostnames.

  [docs/static-linking.md](docs/static-linking.md) has the per-platform
  measurements, the sizes, the cmake line for building libssh as an archive,
  and the two traps in doing it by hand.

### Changed

- **The `otsh` command is now a compiled Odin program, not bash.** The
  ~900-line script at the repository root did not merely degrade off bash —
  it did not run at all: a stock Alpine container answered every subcommand
  with `env: can't execute 'bash'`, a Debian with bash removed said the same,
  and FreeBSD's base system has no bash to find either. macOS's own
  `/bin/bash` is a 3.2 whose heredoc parsing had already cost this project one
  real bug: bash 3.2 ends a `$( )` command substitution at the first `)`
  sitting at the start of a line *inside* the heredoc body, and the old
  script's scaffold template closed its `#assert(` block on exactly such a
  line — reproduced before it was worked around, not guessed at.

  The tool now lives in `cmd/otsh`, compiled Odin; `otsh` at the repository
  root is a small POSIX `#!/bin/sh` bootstrap that resolves its own real
  location through a symlink, builds `cmd/otsh` into a binary named after the
  OS and architecture it is on — `bin/otsh-linux-arm64`, say — the first time
  any command runs, printing `otsh: building the otsh tool (cmd/otsh ->
  bin/otsh-linux-arm64)...` to stderr while it does, and execs the result,
  which is instant on every call after the first. Naming the binary per OS
  and architecture means a checkout
  bind-mounted into a container builds its Linux tool beside the host's macOS
  one instead of dying on "exec format error". On a machine with no Odin
  compiler anywhere, the bootstrap answers `doctor`, `help` and `version`
  itself, in portable sh — the same three-failure checklist `otsh doctor`
  always printed on a bare machine — and every other command gets the same
  "odin compiler not found" message `otsh build` gave before, with the same
  use-odin/`ODIN=` hints.

  Every command, message and exit code is a port of the script it replaces,
  verified with a golden-output diff between the two. The one deliberate
  behaviour change: `otsh new` used to scaffold a project with no compiler
  present; now, since it is itself part of the compiled tool, it needs one —
  a scaffold nothing could build was of limited use anyway, and the error
  names exactly what to install. The `build.sh` that `otsh new` scaffolds
  into new projects is `#!/bin/sh` too, like this repository's own
  `build.sh` and `test.sh`.

  Every `v*` tag now also builds the tool natively on four runners —
  `ubuntu-latest`, `ubuntu-24.04-arm`, `macos-latest` (plus an untested
  `darwin-amd64` cross-build; no Intel Mac runner exists to test it on), and
  `windows-latest` — and attaches `otsh-linux-amd64`, `otsh-linux-arm64`,
  `otsh-darwin-arm64`, `otsh-darwin-amd64` and `otsh-windows-amd64.exe` to a
  pre-release CI creates itself. The tool binary links against nothing but
  the OS — no libssh — because libssh is a dependency of the apps it builds,
  not of the tool.

  Verified in containers: on **Debian 12 with bash removed** and on **Alpine
  3.22, which never had bash**, `otsh doctor`, `otsh new`, `otsh build` and
  `otsh run` all worked, and a real `openssh` client over a pty connected to
  the scaffolded app and rendered a frame. That Alpine run was also the first
  time an otsh app was built and served on musl — one scaffold app, one
  session; the test suite itself has not been run there.

- **`libssh/libssh.odin` names its library through a constant** —
  `LIB :: #config(OTSH_LIBSSH, …)`, consumed as `foreign import lib {LIB}` —
  so `-define:OTSH_LIBSSH=system:/path/to/libssh.a` can replace it. The default
  is exactly what it was, `system:ssh` on unix-likes and `system:ssh.lib` on
  Windows, and the dynamic build is byte-for-byte the build it always was.

  The braced form is load-bearing: `foreign import` takes a string *literal*,
  so `foreign import lib LIB` is a syntax error and only
  `foreign import lib {LIB}` accepts a compile-time constant. The define
  carries a path rather than being a boolean because there is no portable
  location for a `libssh.a`. `system:` followed by an absolute path is passed
  to the linker verbatim as an input file, which is the point — adding
  `libssh.a` through `-extra-linker-flags` alone does nothing, because every
  linker tested resolves the `-lssh` that `system:ssh` emits to the shared
  library regardless of an archive also being on the command line.

- **`otsh help` no longer runs itself.** The `install` line described putting
  `` `otsh` `` on your `$PATH`, inside an unquoted heredoc — so the backticks
  were command substitution and the shell recursively invoked whatever `otsh`
  was on `$PATH`, splicing a second copy of the help text into the middle of
  the first, while `$PATH` expanded to the reader's actual path. Both are now
  escaped, the way the neighbouring `` \`odin build\` `` always was.

- **`otsh build` folds a caller's `-extra-linker-flags:` into its own** rather
  than passing both. Odin accepts only one and rejects a second with
  `Previous flag set: 'extra-linker-flags'`, so
  `otsh build ~/app -extra-linker-flags:"-lmylib"` previously could not work at
  all. It now does, which is what lets somebody add the one library their
  distribution's libssh happens to need without giving up everything otsh
  resolved for them.

- **`otsh`, one executable at the repository root, so starting a project is a
  command rather than a build script you write yourself.** Getting to "hello
  world" used to mean cloning the repo and then hand-writing an `odin build`
  line carrying `-collection:otsh=` and `-extra-linker-flags:"-L… -Wl,-rpath,…"`
  — ceremony that has to be exactly right before anything works at all, and
  that every new project pays again.

  ```sh
  ln -s "$PWD/otsh" ~/.local/bin/otsh    # once
  otsh new ~/src/myapp                   # scaffold
  otsh run ~/src/myapp                   # build and serve
  ```

  Subcommands: `new`, `build`, `run`, `test`, `flags`, `doctor`, `version`,
  `help`. The first bare word is always the package directory and anything
  starting with a dash goes to the compiler, so `otsh build ~/src/myapp
  -o:speed` and `otsh test -define:ODIN_TEST_NAMES=…` both work.

  - **It resolves its own real location**, walking the symlink chain by hand
    rather than trusting `$0` or `readlink -f` (a GNU extension macOS did not
    carry for most of its life). That is what makes a symlink on `$PATH` work:
    the collection has to name the checkout, not `~/.local/bin`. Verified
    through a two-hop chain, from a working directory that was neither the
    repo nor the project.
  - **`otsh new` writes a project that builds and serves with no editing**: a
    `main.odin` with the three procs, a `--local` flag and a `#assert` pinning
    the otsh minor it was generated against; its own `build.sh`, which records
    the checkout and honours `OTSH_ROOT`; and a `.gitignore` covering
    `*hostkey`, `*_secret` and the binary.
  - **`otsh build` leaves the binary in the project directory** and `otsh run`
    starts it from there, because `Config.host_key_path` is relative — a
    server started from wherever you were standing scatters host keys, and a
    host key that moves is a mismatch warning on every returning client.
  - **`otsh flags` prints the two flags and nothing else**, so a Makefile, a
    `justfile`, an IDE or your own script can use them instead of this tool.
    Paste them; `$(otsh flags)` would word-split the linker flags.
  - **`otsh doctor` reports odin, libssh against the 0.10.6 floor, and clang**
    as a checklist with the install line for whatever is missing, and exits
    non-zero. Measured on a bare `ubuntu:24.04`, where it found a bug in its
    own first draft: an empty `/usr/local/lib` — present on a machine with no
    libssh at all — was being reported as "found", so it now looks for the
    library file rather than the directory.

  This is ergonomics, not a new distribution model. `-collection:otsh=` still
  points at a source tree, nothing is installed system-wide, and pinning is
  still checking out a tag — see "Pinning and upgrading otsh" in
  [docs/getting-started.md](docs/getting-started.md), which is unchanged.

### Changed

- **`build.sh` and `test.sh` are now thin wrappers around `otsh`.** Same
  command line, same defaults, same output locations, same exit codes —
  `./build.sh` still drops the binary in your current directory and
  `./test.sh` still runs the suite in `tests/`. What changed is that the
  compiler resolution and the libssh discovery, including the Windows
  `/LIBPATH:` branch, now live in exactly one file instead of being copied
  into each script. `./otsh build path/to/app` is the same build with the
  binary left beside its source instead.

## 0.3.0 — 2026-08-06

### Changed

- **`ssh.DEFAULT_HOST` is now `"::"`, not `"0.0.0.0"`.** A server that does not
  set `Config.host` binds the IPv6 wildcard, which on a dual-stack kernel
  serves IPv4 and IPv6 from one socket. `localhost` resolves to `::1` before
  `127.0.0.1` on both macOS and Linux, so an IPv4-only server made every
  `ssh localhost` try IPv6 first, get refused and retry — one wasted round trip
  per connection — and was unreachable from an IPv6-only client at all.
  Measured on Linux with a 50 ms one-way delay on `lo`: `localhost` connects in
  206.66 ms against `0.0.0.0` and 104.09 ms against `::`, and `::1` goes from
  "connection refused" to 107.70 ms. On loopback with no added delay the saving
  is about 0.03 ms — real and invisible. It does **not** fix a slow connect
  caused by a dropped SYN; measured with an `ip6tables … -j DROP` rule in
  place, both binds take over two minutes, because a dropped packet never
  reaches a listener.

  Where a dual-stack socket is not available, `serve` rebinds on the new
  `ssh.DEFAULT_HOST_IPV4` (`"0.0.0.0"`) and says why on stderr. Both cases are
  measured, in Docker: a `"::"` bind that fails outright (no `AF_INET6` at
  all), and one that succeeds but that the kernel made IPv6-only, which would
  refuse every IPv4 client — Linux with `net.ipv6.bindv6only=1`, and FreeBSD's
  and Windows' default. libssh never sets `IPV6_V6ONLY` itself, so `serve`
  reads it back off the listening socket. The fallback applies only to the
  default: an explicit `Config.host` is bound exactly as written.

  **If you need the old behaviour**, set `Config.host = ssh.DEFAULT_HOST_IPV4`.
  Do that deliberately if anything in front of your server — firewall, rate
  limiter, fail2ban action — is written for IPv4 only, because such a control
  does not partly cover the v6 half, it does not cover it at all, and it fails
  silently. The artifacts in `deploy/` are paired for both families already.

- The peer address of an IPv4 client is reported as a dotted quad on a
  dual-stack listener too. `getpeername` returns the IPv4-mapped
  `::ffff:127.0.0.1` there; `ssh.remote_addr`, `Auth_Request.remote_addr`, the
  audit log and the per-address limiter all see `127.0.0.1`, exactly as on an
  IPv4-only bind, so `deploy/fail2ban`'s `addr=<HOST>` and any existing ban
  rule keep matching what they always matched.

- The startup line brackets an IPv6 bind address (`listening on [::]:2222`
  rather than `:::2222`) and the `ssh …` hint after it names `localhost` when
  the bind address is a wildcard, since neither wildcard is a host you can
  connect to.

### Added

- `ssh.DEFAULT_HOST_IPV4` — the IPv4 wildcard the default bind falls back to.

### Documentation

- A **from-zero concepts page** (`docs/concepts.md`): what a terminal is, what
  ANSI escapes are, raw mode, the SSH channel, why answering `pty-req` without
  allocating a pty works, and the update/view model. Somebody who has never
  written a TUI can start there.
- Two more tutorials — a first app in ten minutes (`docs/tutorial-first-app.md`)
  and a persistent per-user notes app (`docs/tutorial-notes.md`), the latter
  shipping as `examples/notes`. Four tutorials now, each ending in something
  that runs.
- **IDE-style code view on the docs site.** Hovering, focusing or tapping a
  known symbol in any code block shows its signature, doc summary and package;
  clicking navigates to its reference entry; symbols from Odin's standard
  library link to `pkg.odin-lang.org`. Generated source pages carry per-line
  anchors, so every `tui/screen.odin:356` is a working go-to-definition link.
  Only identifiers that resolve with certainty are linked — 86% of tokens are
  deliberately left plain, because a wrong tooltip is worse than none.
- `docs/bindings.md` (maintaining the C interop layer), `docs/compatibility.md`
  (the measured Odin and libssh support matrix), `docs/releasing.md`,
  `docs/migrating.md`, and a `deploy/` guide verified against a live systemd,
  journald, fail2ban and nftables stack.
- Two new gates, because documentation here is cited as evidence:
  `docs/tools/check_examples.py` requires every fenced Odin block to compile,
  match verbatim the file it cites, or carry a written reason for being
  skipped (201 blocks, 0 unannotated); `docs/tools/gen_symbols.py --check`
  verifies every symbol link on every page resolves. Both run in `check.sh`.
- The site publishes to GitHub Pages from a workflow, and a terminfo-pushing
  terminal (Ghostty's `ssh-terminfo`) making connections feel slow is
  explained in `docs/getting-started.md` — otsh refuses `exec`, so the install
  can never succeed and is retried forever unless the host is cached.

## 0.2.0 — 2026-08-01

A security-review release. `ssh.write` changes its contract, which is why this
is a minor rather than a patch: it may now return a short count instead of
blocking until every byte is gone. Apps built on `sshtui`/`tui` are unaffected
— `tui.run` already handles short writes — but code calling `ssh.write`
directly and ignoring the return value should check it.

### Added

- `Limits.write_stall_seconds` (default 30): how long a client may leave its
  flow-control window shut — i.e. simply stop reading — before its session is
  torn down. `0` takes the default. Unlike every other field, a negative value
  disables only the *disconnect*: `ssh.write` never blocks whatever this is set
  to, so a stalled client keeps its slot but not a wedged thread.

### Fixed

- **An algorithm list with one misspelled name silently downgraded the
  connection.** libssh only rejects a list when *every* name in it is unknown,
  so `ciphers = "chacha20-poly1305@openssh.comTYPO,aes128-ctr"` started a
  server that negotiated `aes128-ctr` — a non-AEAD cipher — with no diagnostic
  anywhere. The same shape produced `hmac-sha1`, and an all-SHA-1 key-exchange
  offer. `set_algorithms` now validates every name individually and refuses to
  start, naming the offender. A name missing from otsh's own defaults is a
  warning rather than a fatal error, since those lists are strong by
  construction and some libssh builds legitimately lack an entry.
- **A client that stopped reading pinned its session thread indefinitely.**
  `handshake_seconds` did not cover it: the wait inside `ssh_channel_write`
  does not honour `SSH_OPTIONS_TIMEOUT`. Three such clients held every session
  slot until they chose to leave, refusing service to everyone else, at a cost
  to them of one idle socket each. Bounded by `write_stall_seconds` above.
- **`serve` leaked on every startup-failure path**, including handing the
  loaded 32-byte identity secret back to the allocator without zeroing it.
- `Pty.term` was documented as borrowing `Session.term_buf` but never
  assigned, so the public field was always `""`. `ssh.term()` was unaffected.
- Mouse coordinates reaching an app are now clamped to the live screen, not
  just to `MAX_COLS`/`MAX_ROWS`. The wire values are independent of the
  client's real geometry, so `ESC [ < 0 ; 999 ; 299 M` reached an app as
  (998, 298) on an 80x24 session — out of bounds for any app indexing a grid
  sized to its own screen.
- Defensive: `copy_cstr` guards a nil `cstring`, `take_input` clamps libssh's
  returned byte count to the destination, and a nil `ssh_event_new` result is
  handled rather than passed on.
- `tui.run` no longer lets a partly-sent frame corrupt its diff baseline, and
  retries the alternate-screen enter/exit sequences rather than writing them
  once.

### Changed

- **`ssh.write` may now return a short count** instead of blocking until the
  whole slice is sent. `tui` handles this; a `Handler` calling `ssh.write`
  directly must not assume everything was written.
- `tui.Style` is now `#align(4)`, making it 12 bytes rather than 11. `Cell` is
  16 bytes either way, so the cell grid is unaffected. This works around an
  Odin codegen issue — an 11-byte struct passed by value gets a 12-byte store
  into its stack slot — that made AddressSanitizer abort on the first frame of
  every session and so masked everything behind it. See docs/security.md §13.

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
