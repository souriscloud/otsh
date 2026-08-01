# Compatibility

otsh has exactly two external dependencies: the **Odin compiler** and
**libssh**. Neither is vendored, both move on their own schedule, and a break
in either one breaks every build. This page is the contract for both — which
versions are supported, which were actually tested and how, and what a
maintainer should check before moving a pin.

Everything here is stated as what was run. Where something was assumed rather
than measured it says so, and [What was not
measured](#what-was-not-measured) collects the gaps in one place. The rule
this page tries to keep: **a version number with no command behind it is a
rumour.**

## The short version

| | Supported | Evidence |
| --- | --- | --- |
| Odin | `dev-2026-03` or newer; **`dev-2026-07a` is the pin** | Bisected in containers, `dev-2026-02` fails and `dev-2026-03` passes |
| libssh | `0.10.6` ≤ v ≤ `0.12.2` | Four versions built, tested and made to serve a live `ssh` session |
| Platforms | macOS, Linux, Windows run; FreeBSD type-checks only | See [Platforms](#platforms) |

CI builds every blocking job against the pinned Odin. A separate
`odin-master` job tracks Odin's `master` branch, runs weekly, and is
`continue-on-error: true` — it is a smoke alarm, not a gate.

## Odin

### The pin

`.github/workflows/ci.yml` sets `ODIN_RELEASE: dev-2026-07a` and every
blocking job installs exactly that. It is not `latest` and not a branch.

`dev-2026-07a` contains the compiler commit `dev-2026-07-nightly:819fdc7`, and
that same commit is behind every platform claim in this repo — the Linux
container runs below, the Windows 11 hardware run recorded in
[Getting started](getting-started.md), and the machine otsh is developed on.
One compiler, three platforms, all green.

Odin's tagged releases are snapshots of the same nightly line, so pinning to a
release costs nothing: otsh needs recent `core:` packages, not an unreleased
compiler.

One trap worth knowing if you edit those steps: `laytan/setup-odin` downloads
release assets through the GitHub API and **requires `token` to be set to use
releases at all**. Every pinned step passes `token: ${{ secrets.GITHUB_TOKEN }}`
for that reason and no other — it is a read of a public asset, which the
workflow's `permissions: contents: read` already allows. Drop the token and
every pinned job fails at "Install Odin". The unpinned `odin-master` job does
not need it, because compiling from source is a plain `git clone`.

### Installing the pinned compiler

```sh
# Linux x86_64 — swap arm64/macos as needed; see the release page for names.
curl -fsSLO https://github.com/odin-lang/Odin/releases/download/dev-2026-07a/odin-linux-amd64-dev-2026-07a.tar.gz
tar -xzf odin-linux-amd64-dev-2026-07a.tar.gz
./odin-linux-amd64-nightly+2026-07-10/odin version
```

`build.sh` and `test.sh` find the compiler through `$ODIN`, then a gitignored
`.odin-path` file, then `$PATH` — so an unpacked tarball anywhere on disk
works without installing it:

```sh
echo "$PWD/odin-linux-amd64-nightly+2026-07-10/odin" > .odin-path
```

macOS users can `brew install odin`, but Homebrew tracks its own version and is
not what CI uses. If a build breaks, check the compiler first.

### The floor: `dev-2026-03`, bisected

Measured, not estimated. Each row is `./build.sh`, `./test.sh` and both
cross-type-checks in a `debian:12` container (libssh 0.10.6, `linux/arm64`),
against that release's official prebuilt `odin-linux-arm64` tarball:

| Odin release | `odin version` reports | Result |
| --- | --- | --- |
| `dev-2026-01` | `dev-2026-01-nightly` | **fails to compile** |
| `dev-2026-02` | `dev-2026-02-nightly` | **fails to compile** |
| `dev-2026-03` | `dev-2026-03-nightly` | builds, 71 tests pass, both cross-checks pass |
| `dev-2026-05` | `dev--nightly:` | builds, 71 tests pass, both cross-checks pass |
| `dev-2026-07a` | `dev-2026-07-nightly:819fdc7` | builds (6/6 targets), 71 tests pass, both cross-checks pass |

So the floor is `dev-2026-03`. It is a real boundary with four separate causes,
not an off-by-one — `dev-2026-02` reports all of these at once:

- `os.read_entire_file_from_path` is not declared (`ssh/identity.odin:40`)
- `crypto.zero_explicit` is not declared (`ssh/identity.odin:44`)
- `crypto.is_zero_constant_time` is not declared (`ssh/identity.odin:57`)
- `Illegal compound literal, int cannot be used as a compound literal with fields`
  at `ssh/identity.odin:115` and `ssh/server.odin:458` — both are
  `os.open(path, {.Write, .Create, .Excl}, {.Read_User, .Write_User})`, which
  needs the `core:os` that takes bit sets for flags and mode. The older one
  took plain `int`s.

Worth recording because it contradicts the obvious guess: **the blocker is
`core:os` and `core:crypto`, not `core:sys/posix`.** `core:sys/posix` is the
package usually blamed for otsh needing a recent compiler, and it is not what
fails first. Nothing in the `dev-2026-02` error output comes from it.

The bisect is coarse — monthly releases, not commits. The true boundary is
somewhere in the commits between the `dev-2026-02` and `dev-2026-03` tags.
`dev-2026-03` is the oldest release that is *known* to work, which is the only
kind of floor worth publishing.

### The compile-time check, and why it is written oddly

`libssh/libssh.odin` carries `MIN_ODIN_VERSION :: "dev-2026-03"` and an
`#assert`. Odin has no numeric version constant — `ODIN_VERSION` is a string
— but releases are dated, so lexicographic comparison orders them correctly
(`"dev-2026-03" < "dev-2026-07" < "dev-2027-01"`). `#assert` does evaluate
constant string comparison, slicing and `len` at compile time; all three were
verified before being relied on.

The assert is guarded rather than absolute:

```odin
ODIN_VERSION_IS_DATED :: len(ODIN_VERSION) >= 11 && ODIN_VERSION[:4] == "dev-"
#assert(!ODIN_VERSION_IS_DATED || ODIN_VERSION >= MIN_ODIN_VERSION, "...")
```

because **`ODIN_VERSION` is not reliable across official releases.** Measured
by unpacking each prebuilt `linux-arm64` tarball and printing the constant:

| Release | `odin version` | `ODIN_VERSION` |
| --- | --- | --- |
| `dev-2025-10` | `dev-2025-10-nightly` | `"dev-2025-10"` |
| `dev-2025-12a` | `dev-2025-12-nightly` | `"dev-2025-12"` |
| `dev-2026-01` | `dev-2026-01-nightly` | `"dev-2026-01"` |
| `dev-2026-05` | `dev--nightly:` | `"dev-"` |
| `dev-2026-07a` | `dev-2026-07-nightly:819fdc7` | `"dev-2026-07"` |

`dev-2026-05` shipped without its version baked in. An unguarded assert would
reject that compiler outright even though it builds otsh and passes the whole
suite — which it does, per the table above. So the check **fails open**: a
version string it cannot parse is allowed through, and the user gets the raw
`core:` errors exactly as they would with no check at all. Nothing is lost in
that case, and the common case gets one clear line instead of a dozen.

Two consequences to know about:

- The assert lives in `otsh:libssh`, so it reaches anything that imports
  `ssh` or `sshtui`. **A `tui`-only build does not get it** — `otsh:tui` has
  no dependency on the bindings, by design.
- It assumes Odin keeps the `dev-YYYY-MM` naming. If upstream switches to
  semantic versioning the comparison becomes meaningless, and the guard will
  most likely stop matching and quietly disable the check rather than
  misfire — but it would need revisiting.

## libssh

### The floor: 0.10.6, and it is enforced at runtime

`libssh/libssh.odin` sets `MIN_MAJOR/MIN_MINOR/MIN_MICRO` to `0.10.6`, and
`ssh.serve` checks the **runtime** library version before binding anything.
Below the floor it refuses to start.

0.10.6 is the release carrying the fix for **CVE-2023-48795 ("Terrapin")**, a
prefix-truncation attack against the SSH transport, together with the
strict-kex extension that makes the fix effective. A server that negotiates
without it can have handshake messages silently removed by a MITM. This is why
the check is a refusal rather than a warning.

The floor is a floor, not an endorsement. Being above 0.10.6 does not mean you
are patched against everything — libssh is a separate project with its own
advisories. Track [libssh's security page](https://www.libssh.org/security/)
and keep the system copy current.

### Tested versions

All rows below: Odin `dev-2026-07a`, `linux/arm64` in Docker, unless noted.
"Live session" means `examples/tracker` was started and a real OpenSSH client
connected to it **over a pty** — not merely that the binary linked.

| libssh | Where it came from | Build | `./test.sh` | Live session |
| --- | --- | --- | --- | --- |
| **0.10.6** | `debian:12`, `libssh-dev 0.10.6-0+deb12u2` | 6/6 targets | 71 pass | **yes** |
| **0.10.6** | `ubuntu:24.04`, `libssh-dev 0.10.6-2ubuntu0.4` | 6/6 targets | 71 pass | yes — recorded in [Getting started](getting-started.md) |
| **0.11.2** | `debian:13`, `libssh-dev 0.11.2-1+deb13u1` | 6/6 targets | 71 pass | **yes** |
| **0.12.0** | macOS, Homebrew, `arm64` | 6/6 targets | 71 pass | this is the development machine |
| **0.12.0** | Windows 11, vcpkg, `x64` | 6/6 targets | 67 pass (4 are `#+build !windows`) | yes — hardware run, [Getting started](getting-started.md) |
| **0.12.1** | `alpine:edge` (**musl**, Alpine 3.24.0_alpha20260127) | ok | 71 pass | **yes** |
| **0.12.2** | built from source on `debian:13`, `cmake -DWITH_SERVER=ON` | 6/6 targets | 71 pass | **yes** |

The live sessions were driven by a script that forks a pty, runs the system
`ssh` client against port 2222, and checks three things: that a full frame
comes back, that the app reacts to a keystroke (`f` cycles the tracker's
filter), and that a `TIOCSWINSZ` resize produces a reflow. On 0.10.6, 0.11.2,
0.12.1 and 0.12.2 alike it received ~21.7 KB per session, redrew on `f`,
reflowed on resize, and exited cleanly on `q`. `ldd` was checked each time to
confirm the binary had resolved to the intended libssh — for 0.12.2 that is
`/usr/local/lib/libssh.so.4`, the from-source build, not the distro's 0.11.2
sitting in the same container.

**musl works.** The Alpine row is the first time otsh has been built and run
against musl rather than glibc, and it needed no changes: Odin's prebuilt
`linux-arm64` release runs on Alpine as-is, `./build.sh` links through
`clang`/`lld` against `apk`'s libssh 0.12.1, all 71 tests pass, and `tracker`
served a full pty session. Note this supersedes the "not verified: musl/Alpine"
line in [Getting started](getting-started.md) — one container, one
architecture, but it was actually run.

**No version-specific behaviour was found.** The same 71 tests pass and the
same session works across 0.10.6, 0.11.2 and 0.12.2. That is consistent with
earlier work in this repo, which measured the `ssh_event_dopoll` handshake
deadlock identically on 0.10.6, 0.11.2 and 0.12.2 — the bug and its fix are
version-independent.

`TESTED_MAX_MAJOR/MINOR/MICRO` in `libssh/libssh.odin` records `0.12.2` as the
newest tested. Nothing enforces it and no version is refused for being above
it; it exists so "tested up to" has a number attached.

## The struct-layout assumption

This is the most dangerous compatibility surface in the package and it gets its
own section.

`libssh/libssh.odin` mirrors `ssh_server_callbacks_struct` and
`ssh_channel_callbacks_struct` from `libssh/callbacks.h` field for field. Odin
cannot see the C header, so the layout is a hand-copied assumption. **If libssh
ever inserted or reordered a field, otsh would silently wire the wrong
callback** — no compile error, no link error, just a function called with the
wrong arguments.

### What was measured

A C program was compiled against each version's real headers and printed
`offsetof` for every field otsh names, plus `sizeof`. The Odin side printed
`offset_of` for the same fields. Results, in bytes, `linux/arm64`, 8-byte
pointers:

**`ssh_server_callbacks_struct`**

| Field | 0.10.6 | 0.11.2 | 0.12.1 | 0.12.2 | otsh |
| --- | --- | --- | --- | --- | --- |
| `size` | 0 | 0 | 0 | 0 | 0 |
| `userdata` | 8 | 8 | 8 | 8 | 8 |
| `auth_password_function` | 16 | 16 | 16 | 16 | 16 |
| `auth_none_function` | 24 | 24 | 24 | 24 | 24 |
| `auth_gssapi_mic_function` | 32 | 32 | 32 | 32 | 32 |
| `auth_pubkey_function` | 40 | 40 | 40 | 40 | 40 |
| `service_request_function` | 48 | 48 | 48 | 48 | 48 |
| `channel_open_request_session_function` | 56 | 56 | 56 | 56 | 56 |
| `gssapi_select_oid_function` | 64 | 64 | 64 | 64 | 64 |
| `gssapi_accept_sec_ctx_function` | 72 | 72 | 72 | 72 | 72 |
| `gssapi_verify_mic_function` | 80 | 80 | 80 | 80 | 80 |
| `channel_open_request_direct_tcpip_function` | — | — | 88 | 88 | 88 |
| `auth_kbdint_function` | — | — | 96 | 96 | 96 |
| **`sizeof`** | **88** | **88** | **104** | **104** | **104** |

**`ssh_channel_callbacks_struct`**

| Field | 0.10.6 | 0.11.2 | 0.12.1 | 0.12.2 | otsh |
| --- | --- | --- | --- | --- | --- |
| `size` | 0 | 0 | 0 | 0 | 0 |
| `userdata` | 8 | 8 | 8 | 8 | 8 |
| `channel_data_function` | 16 | 16 | 16 | 16 | 16 |
| `channel_eof_function` | 24 | 24 | 24 | 24 | 24 |
| `channel_close_function` | 32 | 32 | 32 | 32 | 32 |
| `channel_signal_function` | 40 | 40 | 40 | 40 | 40 |
| `channel_exit_status_function` | 48 | 48 | 48 | 48 | 48 |
| `channel_exit_signal_function` | 56 | 56 | 56 | 56 | 56 |
| `channel_pty_request_function` | 64 | 64 | 64 | 64 | 64 |
| `channel_shell_request_function` | 72 | 72 | 72 | 72 | 72 |
| `channel_auth_agent_req_function` | 80 | 80 | 80 | 80 | 80 |
| `channel_x11_req_function` | 88 | 88 | 88 | 88 | 88 |
| `channel_pty_window_change_function` | 96 | 96 | 96 | 96 | 96 |
| `channel_exec_request_function` | 104 | 104 | 104 | 104 | 104 |
| `channel_env_request_function` | 112 | 112 | 112 | 112 | 112 |
| `channel_subsystem_request_function` | 120 | 120 | 120 | 120 | 120 |
| `channel_write_wontblock_function` | 128 | 128 | 128 | 128 | 128 |
| `channel_open_response_function` | — | 136 | 136 | 136 | 136 |
| `channel_request_response_function` | — | 144 | 144 | 144 | 144 |
| **`sizeof`** | **136** | **152** | **152** | **152** | **152** |

### What that means

**No field was ever reordered or inserted.** Across 0.10 → 0.11 → 0.12, every
change is a pure append at the end of the struct:

- 0.11 appended `channel_open_response_function` and
  `channel_request_response_function` to the **channel** struct.
- 0.12 appended `channel_open_request_direct_tcpip_function` and
  `auth_kbdint_function` to the **server** struct.

Every field otsh actually installs a callback into sits at an identical offset
in all four versions. The bindings match the 0.12 shape, which makes otsh's
structs a **superset** of what 0.10.6 and 0.11.2 define.

That superset is safe, and the mechanism is worth stating precisely because it
is the whole reason the `size` member exists. otsh sets
`size = size_of(...)` — 104 and 152 — which on 0.10.6 is *larger* than
libssh's own struct. libssh guards every call with:

```c
#define ssh_callbacks_exists(p,c) (\
  (p != NULL) && ( (char *)&((p)-> c) < (char *)(p) + (p)->size ) && \
  ((p)-> c != NULL) \
  )
```

(verbatim from `/usr/include/libssh/callbacks.h`, 0.10.6). libssh bound-checks
each field against the size **the caller declared**, and only ever reads fields
it knows about. A caller declaring a larger size is therefore fine: the extra
trailing slots are never touched. The dangerous direction is a caller declaring
a *smaller* size, which silently disables callbacks past the boundary — which
is exactly what would happen if someone "fixed" these structs by trimming them
to match an older header. Do not do that.

### The part that is still an assumption

The append-only pattern is libssh's evident practice and it is what the `size`
member is designed for, but it is **not a documented ABI guarantee**. Nothing
stops a future release from inserting a field. Re-run the check on upgrade;
see below.

## Platforms

In descending order of evidence. [Getting
started](getting-started.md#platform-support) has the full detail; this is the
compatibility summary.

| Platform | Status | Evidence |
| --- | --- | --- |
| **macOS** (arm64) | built, tested, run | The development machine. libssh 0.12.0 via Homebrew |
| **Linux** (glibc, arm64 + x86_64) | built, tested, run | Containers above; live `ssh` sessions on 0.10.6, 0.11.2, 0.12.2 |
| **Windows 11** (x64) | built, tested, run | Hardware run 2026-07-31: vcpkg libssh 0.12.0, 67 tests, live openssh sessions. The hosted CI job has never executed |
| **Linux** (musl/Alpine, arm64) | built, tested, run | `alpine:edge`, libssh 0.12.1, 71 tests, live `ssh` session |
| **FreeBSD** | **type-checks only** | `odin check` for `freebsd_amd64` in CI. Nobody has built or run it |

FreeBSD deserves the emphasis. Type-checking is not running, and it has already
been shown to be insufficient here: `tui/local.odin`'s `TIOCGWINSZ` held the
Linux value on FreeBSD for the whole life of the file, which would have made
every local-terminal app render at the 80x24 fallback. It type-checked
perfectly the entire time.

## What was not measured

Stated plainly so nobody reads a gap as a guarantee.

- **Odin below `dev-2026-03` is not merely unsupported, it is known broken**,
  with the four errors listed above. There is no fallback for a user who
  needs an older compiler.
- **The Odin bisect is monthly, not per-commit.** The true floor is some
  commit between the `dev-2026-02` and `dev-2026-03` tags.
- **`dev-2025-09` and `dev-2025-11` were not tested at all.** Those releases
  ship `.zip` rather than `.tar.gz` and the probe harness did not locate the
  binary inside them. They are far below the floor, so nothing turns on it.
- **libssh above 0.12.2 is untested.** Nothing refuses it and nothing promises
  it.
- **libssh 0.11.0/0.11.1/0.11.3–0.11.5 and 0.12.0 on Linux were not built.**
  0.11.2 and 0.12.2 stand in for the 0.11 and 0.12 lines; 0.12.0 is covered on
  macOS and Windows but not Linux.
- **The struct-layout tables are `linux/arm64` only.** Every field is a
  pointer or a `size_t`, so the layout is the same on any LP64 target, but it
  was not re-derived on x86_64, on macOS, or on Windows (LLP64 — where
  `size_t` is still 8 bytes, so the same reasoning holds, but again: not
  re-derived).
- **One unexplained test-suite failure.** During a run with two containers
  building concurrently, `./test.sh` on `debian:13`/0.11.2 exited non-zero
  while the parallel `debian:12` run passed. The log was lost to a harness bug
  and the failure did not reproduce: the same image passed 3/3 solo re-runs,
  1/1 solo live run, and 1/1 in a second deliberate two-container attempt.
  Most likely resource exhaustion from running two LLVM builds at once on one
  laptop, but that is a hypothesis, not a measurement. Recorded rather than
  swept up, because it is the only red result in this whole exercise.

## Upgrading a dependency

A checklist for whoever moves a pin. All of it is runnable from the repo.

### Moving the Odin pin

1. Check the canary first. The `odin-master` job in CI has been building
   against Odin's `master` weekly. If it is red, read it before upgrading —
   it is telling you what will break.
2. Get the new compiler, point `.odin-path` at it, and run **`./check.sh`**.
   That is the whole gate: 6 builds, 80 tests, 3 doc checks and the bindings
   check. It must be green.
3. Update `ODIN_RELEASE` in `.github/workflows/ci.yml`.
4. If the new release is *older* than the floor, or if you want to re-derive
   the floor, bisect it. The method: a container, the prebuilt tarball, and
   `./build.sh && ./test.sh`. Nothing else is needed —
   `.odin-path` is skipped automatically when the path in it does not resolve,
   which is what lets the worktree be bind-mounted into a container that has
   its own compiler.
5. If the floor moves, update **both** `MIN_ODIN_VERSION` in
   `libssh/libssh.odin` **and** the literal in the `#assert` message just below
   it — Odin will not accept a concatenated constant there, so the version
   appears twice on purpose.
6. Re-run `python3 docs/tools/gen_api.py` if any public doc comment changed,
   and update the tables on this page.

### Moving the libssh floor or testing a new libssh

1. **Re-derive the struct layouts.** This is the step that matters and the one
   easiest to skip. Compile a small C program against the new headers that
   prints `offsetof` for every field named in `Server_Callbacks` and
   `Channel_Callbacks`, and compare it to Odin's `offset_of` for the same
   fields. Any change that is *not* a pure append at the end of the struct
   means the bindings must be updated before anything is shipped — and a
   reorder produces no error of any kind, so this check is the only thing
   standing between you and a callback wired to the wrong function.
2. Confirm the `ssh_callbacks_exists` macro still bound-checks against
   `(p)->size`. If libssh ever changed that mechanism, the superset trick in
   `libssh/libssh.odin` stops being safe.
3. Build and run `./test.sh` against the new library. Check `ldd`/`otool -L`
   on the output binary to confirm it resolved to the library you meant to
   test, not another copy on the system.
4. **Actually serve a session.** Linking is not running. Start
   `examples/tracker`, connect with a real `ssh` client, and confirm a frame
   is drawn, a keystroke is answered and a resize reflows. The handshake
   deadlock this repo already fixed was invisible to the test suite and only
   appeared under a real client.
5. Update `TESTED_MAX_*` in `libssh/libssh.odin` and the matrix on this page.
6. Raising `MIN_*` is a security decision, not a convenience one. The current
   floor exists for Terrapin; document the advisory behind any new floor.

### When CI goes red and nothing changed

Almost always the answer is that something *did* change and it was not in this
repo. In order of likelihood: the `odin-master` canary found a real upstream
break; a runner image bumped its vcpkg commit and invalidated the Windows
binary cache; or a distro moved `libssh-dev` to a new version. The pinned jobs
are specifically designed so that the first of these cannot take the build
down — if a blocking job goes red, the cause is in the repo or in the runner
image, not in Odin's `master`.
