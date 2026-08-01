# Getting started

This page takes you from nothing to a running SSH-served TUI: build the
bundled examples, write your own app, iterate on it without an SSH client, and
link it into a project that lives outside this repo. It does not re-explain
*why* otsh works the way it does — see the [README](../README.md) for the
protocol trick, the auth model, and what is and is not hardened. Read that
before you expose anything here to the network.

## Requirements

- **Odin, nightly.** otsh uses `core:sys/posix`, which tracks Odin's nightly
  builds rather than a tagged release.
- **libssh ≥ 0.10.6.** `brew install libssh` on macOS, `apt install
  libssh-dev` on Debian/Ubuntu. The `.6` is not decoration: `ssh.serve` checks
  the runtime version before it binds anything and refuses to start below
  0.10.6, because that is the release carrying the fix for CVE-2023-48795
  (Terrapin). A 0.10.0 install compiles and then declines to run. otsh does
  not vendor libssh — `otsh:libssh` is bindings against your system copy.
- **clang.** Odin shells out to `clang` to link, and on Linux it is not
  optional: on a stock `ubuntu:24.04` carrying only `libssh-dev` and
  `pkg-config`, `./build.sh` stops at `sh: 1: clang: not found`, and adding
  `build-essential` does not fix it — gcc is not a substitute. `apt install
  clang`. On macOS the Command Line Tools already provide it.
- **macOS, Linux, Windows or FreeBSD.** macOS, Linux and Windows have all been
  built and run; FreeBSD has not — see [Platform
  support](#platform-support) immediately below before you rely on that one.

`build.sh` and `test.sh` resolve the compiler in this order: `$ODIN` if it is
set; then a gitignored `.odin-path` file next to the script, if what it
contains resolves to an executable; then `odin` on your `$PATH`. `.odin-path`
exists for machines where the compiler is not on `$PATH`, and is never
committed. A path in it that does not resolve is skipped rather than obeyed,
so one checkout seen by two machines at once — a worktree bind-mounted into a
container, say — still builds on the machine the file was not written on.

## Platform support

Four platforms get mentioned around here and they are not equally real. In
descending order of evidence: **macOS is developed on, Linux and Windows have
both been built and run, FreeBSD only type-checks.** The rest of
this section is the evidence for each, stated as what was run rather than as
what is expected to work — the FreeBSD bug in the next paragraph is what an
unmeasured "supported" is worth.

### Linux — built, tested and run

Verified on 2026-07-30 in a container, top to bottom:

- **Ubuntu 24.04.4 LTS** (the `ubuntu:24.04` image, which is what CI's
  `ubuntu-latest` resolves to), **libssh 0.10.6** (`libssh-dev`
  0.10.6-2ubuntu0.4), **Odin dev-2026-07-nightly:819fdc7** (the prebuilt
  `dev-2026-07a` release), **clang 18.1.3**, client **OpenSSH_9.6p1**. Run on
  `aarch64`; `./build.sh`, every example and the whole test suite were also
  run on `x86_64` with the same distro, libssh and Odin.
- `./build.sh`, `./build.sh` for each of the five `examples/`, and `./test.sh`
  (71 tests) all pass, unmodified — the same three commands CI's Linux job
  runs. So do the Windows and FreeBSD cross-type-checks.
- Actually run, not just built: `examples/tracker` served over a real
  `openssh` connection from a pty, rendering frames, reacting to keystrokes,
  reflowing on a window-change, and shutting down cleanly on `q`; eight
  concurrent sessions; five clients `SIGKILL`ed mid-frame without taking the
  server with them; a ninth connection refused by `Limits.max_per_ip` and
  audited as `limit=per_ip`; `examples/stopwatch` and `tracker --local` driven
  through `tui/local.odin`'s raw mode on a local pty.
- The Linux-only paths specifically: `ssh/net_posix.odin`'s `poll` and its
  `peer_address` (`getpeername`/`inet_ntop`), read back out of the audit log
  as `addr=127.0.0.1` over IPv4 and `addr=::1` over IPv6;
  `ssh/perm_posix.odin` creating the host key and identity secret `0600` and
  warning about them at `0644` and `0640`; `tui/local.odin`'s `TIOCGWINSZ`,
  which is a different number on Linux than on the BSDs and which reported
  every pty size it was given rather than falling back to 80x24.
- The test suite also passes under `-sanitize:address`, and a `tracker` built
  with ASan served a full session without a single report.

Not verified on Linux: any distro other than Ubuntu 24.04, musl/Alpine, a
non-container host, systemd (`deploy/otsh.service`), and live journald/fail2ban
— `deploy/fail2ban/test_filter.py` passes, but that checks the filter against
the audit-line contract, not against a running fail2ban.

### FreeBSD — type-checks only

Nobody has built or run otsh on FreeBSD, and the cost of that showed up here:
`tui/local.odin`'s `TIOCGWINSZ` was written as "the macOS value on Darwin, the
Linux value everywhere else", which handed FreeBSD `0x5413` when its kernel
wants the BSD encoding `0x40087468` (Odin's own
`core/sys/freebsd/constants.odin` says so). Every local-terminal app on
FreeBSD would have silently rendered at the 80x24 fallback forever. The
constant is now keyed off Linux being the exception, and CI cross-type-checks
every package and example for `freebsd_amd64` — but type-checking is not
running, and no FreeBSD claim here is stronger than that.

### Windows — built, tested and run

Verified on 2026-07-31 on a physical desktop, top to bottom:

- **Windows 11 Pro 10.0.26200** (`AMD64`), **libssh 0.12.0** (vcpkg
  `libssh[core,pcap,server]:x64-windows`, over **OpenSSL 3.6.3**), **Odin
  dev-2026-07-nightly:819fdc7** (the prebuilt `dev-2026-07a` release — the same
  compiler commit as the Linux run above), linking with the **MSVC** linker
  from Visual Studio 2026 Community. Clients: **OpenSSH_10.2p1** on macOS
  across the network, and the OpenSSH client Windows 11 itself ships.
- `./build.sh`, `./build.sh` for each of the five `examples/`, and `./test.sh`
  all pass under Git Bash, unmodified — the same three commands CI's Windows
  job runs, through the same `uname -s` → `MINGW64_NT` branch. The suite
  reports **67 tests**, not 71: the four in `tests/linux_test.odin` are
  `#+build !windows` and correctly do not run. Odin finds the MSVC linker by
  itself, so nothing has to run `vcvars64.bat` first.
- Actually run, not just built: `examples/tracker` served real `openssh`
  sessions from a pty — drawing the `issues` frame, cycling the filter on `f`,
  moving the cursor with the arrow keys, and exiting cleanly on `q` — both to a
  client on the machine itself and to one across the network. `examples/whoami`
  emitted a full audit trail (`listen`, `accept`, `auth` publickey, on to
  `session_start` and `session_end`) in which every line carried a correct
  **non-loopback** peer address, which is precisely what
  `ssh/net_windows.odin`'s `getpeername` and hand-bound `inet_ntop` exist to
  produce. `tracker --local` drove `tui/local_windows.odin` in a real console:
  raw single-key input, VT escape sequences honoured rather than printed, UTF-8
  box-drawing intact, and the frame sized from `srWindow`. Ctrl+C at the server
  console shut it down gracefully — `otsh: stopped; all sessions closed
  cleanly` — with a connected client's terminal restored (alt screen left,
  cursor shown, mouse reporting off) before the connection closed.

Four bugs surfaced the moment any of this was first executed, all fixed here:
`build.sh` passed an extensionless `-out:`, which Odin rejects on Windows;
`ssh/server.odin` called `ssh_threads_get_pthread`, which a Windows libssh
declares but never defines, so every example failed to link with `LNK2019`;
four tests wrote to a hardcoded `/tmp`, which on Windows is a `C:\tmp` that
does not exist; and the startup banner's `→` was mojibake in any console whose
output code page is not UTF-8.

Still unverified on Windows, and stated so rather than assumed: concurrent
sessions under load, window-resize reflow, large pastes, the connection
limiter, and `examples/` other than `tracker` and `whoami`, which were built
but not run.

To build on Windows you need libssh from vcpkg (`vcpkg install
libssh:x64-windows`, which produces `ssh.lib`) and `ssh.dll` on your `%PATH%`
at run time — there is no rpath equivalent, so a binary that links fine will
still refuse to start without it. `build.sh` and `test.sh` detect Git Bash and
pass `/LIBPATH:` instead of `-L`/`-rpath`.

Caveats specific to the Windows build, all of them accepted deliberately:

- **The local backend is a different implementation.** `tui/local_windows.odin`
  uses the console API where `tui/local.odin` uses `termios`: raw mode clears
  `ENABLE_LINE_INPUT`/`ENABLE_ECHO_INPUT`/`ENABLE_PROCESSED_INPUT` and sets
  `ENABLE_VIRTUAL_TERMINAL_INPUT`, so keystrokes arrive as the same escape
  sequences `tui/key.odin` already parses; output gets
  `ENABLE_VIRTUAL_TERMINAL_PROCESSING`; both console code pages are set to
  UTF-8 and restored on exit. The public API (`Local`, `local_backend`,
  `local_enter_raw`, `local_exit_raw`) is identical on both platforms.
- **Mouse reporting does not work on the local backend on Windows.**
  `Program.mouse` is ignored there. Over SSH it is unaffected — mouse events
  come from the client's terminal, not from this process's console.
- **Polling fidelity.** `WaitForSingleObject` wakes for any console input
  record, but `ReadFile` in virtual-terminal-input mode only returns once it has
  bytes, so records that translate to nothing — key-up, focus changes, lone
  modifier keys — are drained first and reported as an empty poll. A key-down
  that produces no escape sequence and is not a plain modifier (a dead key, an
  IME composition) can still leave `ReadFile` blocking until the next real
  keystroke. That costs late frames, not input.
- **The private-key permission guarantee is weaker on Windows.** On POSIX the
  host key and the identity secret are created `0600` with `O_EXCL`, verified
  afterwards, and warned about if they are group- or world-readable.
  `ssh/perm_windows.odin` implements none of that: Windows decides access by
  ACL, and there is no ACL code here. Both files inherit whatever the parent
  directory's ACL gives them, `warn_if_world_readable` never warns, and nothing
  tightens the mode after libssh writes the key. Keep them in a directory only
  the service account can read and treat that as the whole of the protection.

### Validating CI locally

Everything above is evidence about otsh. `.github/workflows/ci.yml` is a
separate claim — a workflow file that has never run is a prediction — so it
gets checked before it is pushed. Both tools run in containers; neither is
installed on the host.

**Lint it.** `actionlint` parses the YAML, type-checks every `${{ }}`
expression, validates the `runs-on` labels and `if:` conditions, and runs
`shellcheck` over every `run:` block. No output means no findings:

```sh
docker run --rm -v "$PWD":/repo --workdir /repo rhysd/actionlint:latest -color
```

**Run it.** `act` executes jobs in Docker. No `act` image is publicly
pullable, so build a small one (use `act_Linux_x86_64.tar.gz` on an Intel
host):

```sh
printf 'FROM alpine:3.20\nRUN apk add --no-cache curl git bash docker-cli\nRUN curl -fsSL https://github.com/nektos/act/releases/download/v0.2.89/act_Linux_arm64.tar.gz | tar -xz -C /usr/local/bin act\nENTRYPOINT ["/usr/local/bin/act"]\n' | docker build -t local/act -
```

Then, from the repository root — `-j docs` takes about a minute, `-j build
--matrix os:ubuntu-latest` a few more because it builds Odin from source:

```sh
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$PWD":"$PWD" --workdir "$PWD" \
  local/act \
  -P ubuntu-latest=catthehacker/ubuntu:act-latest \
  --env PATH="$(docker run --rm catthehacker/ubuntu:act-latest printenv PATH)" \
  -j docs
```

Two details in that invocation are worth an hour each if you have to rederive
them:

- **The repository is mounted at the same absolute path it has on the host.**
  `act` runs inside a container but drives the host's Docker daemon, so the
  host resolves every bind mount `act` asks for. Mounted at `/repo`, `act`
  would tell the host to mount `/repo`, which is not there.
- **The `--env PATH=...` line works around a bug in `act`, not in the
  workflow.** `actions/setup-python` prepends its own entries to `PATH`, and
  `act` then drops the runner image's `node` directory, so the action's *post*
  step dies with `exec: "node": executable file not found`. Real runners invoke
  `node` by absolute path and never reach this. Handing the job the image's own
  `PATH` back makes it green.

A green local run says the YAML parses, the expressions and conditions
evaluate, the steps are ordered correctly, the three third-party actions
resolve and execute, and the Linux job's commands do what they claim. It says
nothing about:

- **The `macos-latest` and `windows-latest` jobs.** `act` has no image for
  either and skips them (`Skipping unsupported platform`). What the Windows job
  does has since been reproduced by hand on a real Windows 11 machine — vcpkg
  libssh, then `./build.sh` and `./test.sh` under Git Bash, all green (see
  [Platform support](#platform-support)) — but the job itself, on a
  GitHub-hosted `windows-latest` runner, still has not been observed running.
- **`actions/checkout`.** `act` does not clone; it copies the working tree in,
  gitignored files and all.
- **The GitHub-hosted runner images.** `catthehacker/ubuntu:act-latest` is a
  leaner Ubuntu 24.04 than GitHub's, so a step that quietly leans on
  preinstalled software can pass in one and fail in the other. It cuts both
  ways here: that image ships no LLVM, and `setup-odin` only found one because
  the job's own `clang` install had already pulled in LLVM 18.
- **Architecture.** On an Apple Silicon host these jobs run `arm64`, while
  GitHub's `ubuntu-latest` is `x86_64`. Forcing
  `--container-architecture linux/amd64` does not help: the runner image's
  `git-lfs` segfaults under emulation while cloning Odin, long before the job
  reaches anything of otsh's.
- **Anything that only exists on GitHub:** caches, secrets, `GITHUB_TOKEN`
  scopes, branch filters and matrix fan-out across real runners.

One thing to expect when you run the build job: `./test.sh` fails roughly one
run in fifteen on Linux, always as
`otsh_tests.local_size_reads_the_pty ... size fell back to 80x24`. That is not
`act` and not `TIOCGWINSZ` — the three `tests/linux_test.odin` size tests each
point the *process-wide* `STDOUT_FILENO` at their own fd, and Odin's test
runner runs them on four threads, so one test's `/dev/null` can land under
another's `ioctl`. It reproduces in a bare `ubuntu:24.04` container (1 failure
in 15) and disappears at `-define:ODIN_TEST_THREADS=1` (0 in 15).

## Build and run the examples

`build.sh` builds one app against the otsh source tree and drops the binary,
named after the source directory, in your current directory:

```sh
./build.sh                     # examples/tracker  -> ./tracker
./build.sh examples/whoami     # examples/whoami -> ./whoami
./build.sh examples/members    # examples/members -> ./members
```

Run any of them and connect with a normal `ssh` client — no special client,
no extra flags, no configuration on the connecting side.

### tracker — a full app

```sh
./build.sh
./tracker
ssh -p 2222 localhost
```

A shared issue tracker. Everyone connected sees the same board: open an
issue, close it, file a new one, and every other session sees the change on
its next frame. It exercises most of the library at once — a scrolling list
with a viewport, a split detail pane, a full-screen view, a text-input form,
mouse wheel support, `dt`-driven animation, resize handling, key-derived
identity via `identity_secret`, and shared mutable state behind a
`sync.Mutex`.

The issues it ships with are otsh's own; the closed ones are bugs that were
really found and fixed while building this library.

Everything in `examples/tracker/main.odin` above the "wiring" section at the
bottom is plain TUI code with no idea SSH exists — which is why the same file
also runs with `./tracker --local`.

### whoami — the minimal app

```sh
./build.sh examples/whoami
./whoami
ssh -p 2223 localhost
```

The smallest useful otsh app — one box showing who connected and how. It
requires public-key auth (`methods = {.Publickey}`), so `info.fingerprint`
and `info.key_type` are always populated, and it wires an `authenticate` hook
(`gate`) that logs every attempt and accepts it. Read this one first; it's the
whole surface area in about 90 lines.

### members — key-driven identity

```sh
./build.sh examples/members
./members
ssh -p 2226 localhost      # first connection enrols you
```

Shows the pattern the README argues for: accept every key at the SSH layer
(no `authenticate` hook at all), then decide who gets in *inside the app* by
looking up `info.id` in a roster. Reconnect with the same key and you're
recognised; connect with a different key and you enrol as a new member. This
is what `identity_secret` and `Info.id` are for — see "First-run artifacts"
below.

## Writing your first app

An otsh app is a directory with one `main.odin`, three procs
(`create`, `update`, `view`), and a `destroy` to free what `create`
allocated. Make a new directory anywhere — it does not need to live inside
this repo:

```sh
mkdir -p ~/src/greeter
```

`~/src/greeter/main.odin`:

```odin
package main

import "core:fmt"
import "otsh:sshtui"
import "otsh:tui"

Model :: struct {
	who:   string,
	count: int,
}

// Runs once per keystroke/tick/resize, on that connection's own thread.
update :: proc(p: ^tui.Program, msg: tui.Msg) {
	m := (^Model)(p.app.data)
	#partial switch k in msg {
	case tui.Key:
		#partial switch k.kind {
		case .Up:
			m.count += 1
		case .Down:
			m.count -= 1
		case .Esc:
			tui.quit(p)
		case .Rune:
			if k.r == 'q' {
				tui.quit(p)
			}
		}
	}
}

// Runs once per frame. Paints the whole screen; nothing is incremental here —
// the diff renderer in tui figures out what actually changed to send.
view :: proc(p: ^tui.Program, s: ^tui.Screen) {
	defer free_all(context.temp_allocator)
	m := (^Model)(p.app.data)
	tui.draw_box(s, 2, 1, 34, 5, tui.Style{fg = tui.ansi(6)}, tui.BORDER_ROUND, " greeter ")
	tui.draw_text(s, 4, 2, fmt.tprintf("hello, %s", m.who), tui.Style{fg = tui.ansi(15)})
	tui.draw_text(
		s,
		4,
		3,
		fmt.tprintf("count: %d  (up/down to change, esc to quit)", m.count),
		tui.Style{attrs = {.Bold}},
	)
}

// Called once per connection, on that connection's own thread, before the
// first frame. info.user is whatever the client typed after `ssh` — never
// treat it as verified identity.
create :: proc(info: sshtui.Info) -> tui.App {
	m := new(Model)
	m.who = info.user == "" ? "guest" : info.user
	return tui.App{data = m, update = update, view = view}
}

// Called after the connection's loop ends. Free whatever create allocated.
destroy :: proc(app: tui.App) {
	free(app.data)
}

main :: proc() {
	sshtui.serve(
		sshtui.Config{
			port          = 2300,
			host_key_path = "greeter_hostkey",
			create        = create,
			destroy       = destroy,
		},
	)
}
```

Build it with `build.sh` from the otsh repo, pointing at your app's
directory:

```sh
cd /path/to/otsh
./build.sh ~/src/greeter
./greeter
ssh -p 2300 localhost
```

## The `--local` development loop

`sshtui.run_local(cfg)` runs the identical `tui.App` — same `create`, same
`update`, same `view` — against your own terminal instead of an SSH channel.
It puts your terminal into raw mode itself (there is no SSH client to do it
for you this time), reads `$USER`/`$TERM` to fill in `Info`, and drives the
same `tui.run` loop as the SSH path. Nothing about your app code changes; the
`tui.Backend` underneath is the only thing that's different.

This is worth wiring into every app you write, because the iteration loop it
replaces is slow: no SSH client to launch, no host key to generate or trust,
no separate process to background, no `Ctrl+C` racing a stuck connection —
just run the binary in the terminal you already have open.

`examples/tracker/main.odin` wires it behind a flag:

```odin
for arg in os.args[1:] {
	if arg == "--local" || arg == "-l" {
		if !sshtui.run_local(cfg) {
			fmt.eprintln("tracker: stdin is not a terminal")
			os.exit(1)
		}
		return
	}
}
if !sshtui.serve(cfg) {
	os.exit(1)
}
```

The same `sshtui.Config` value — `cfg` — feeds both `run_local` and `serve`.
Try it:

```sh
./build.sh
./tracker --local
```

## Using otsh from a project outside this repo

Nothing about otsh needs to be vendored or installed system-wide. Point the
Odin compiler at this checkout with `-collection:otsh=`, and tell the linker
where your system's libssh lives:

```sh
odin build /path/to/yourapp \
  -out:yourapp \
  -collection:otsh=/path/to/otsh \
  -extra-linker-flags:"-L$(pkg-config --variable=libdir libssh) -Wl,-rpath,$(pkg-config --variable=libdir libssh)"
```

`-collection:otsh=` is what makes `import "otsh:sshtui"` / `"otsh:tui"` /
`"otsh:ssh"` resolve — it's a source import, not a linked library, so there is
no separate build step for otsh itself. The `-extra-linker-flags` are needed
because libssh is not always on the default linker search path (notably on
Homebrew/macOS); without `-rpath` the binary links but fails to find
`libssh.dylib`/`.so` at runtime.

That is measured on Linux too, not only inferred from macOS: with libssh moved
to `/opt/libssh/lib` and its `.pc` file pointing there, `build.sh` produced a
binary with `RUNPATH=/opt/libssh/lib` that starts with no `LD_LIBRARY_PATH` at
all, while the same link without `-rpath` produced one that dies with
`error while loading shared libraries: libssh.so.4`. On a distro that keeps
libssh in the default multiarch libdir the flag is a no-op, which is why it
takes a non-default prefix to see it working.

`./build.sh path/to/yourapp` (run from inside this repo) passes exactly these
two flags for you, using `pkg-config` when it's available and falling back to
`/opt/homebrew/opt/libssh/lib` or `/usr/local/lib` otherwise.

## First-run artifacts

The first time an app runs, `sshtui.serve` (via `ssh.serve` /
`ensure_host_key`) generates an ed25519 host key at `host_key_path` if
nothing exists there yet, and writes it `chmod 600`. This is the SSH
equivalent of a TLS certificate: it's what makes the encrypted channel
provably the same server on the next connection.

**Keep it stable across restarts.** The first time a client connects, its
`ssh` pins that key's fingerprint in `~/.ssh/known_hosts`. Regenerate or lose
the file and every returning client sees a host-key-mismatch warning (or a
hard refusal, depending on their config) instead of connecting cleanly.
Delete it only if you mean to force everyone to re-trust the server.

If you set `identity_secret` in the `Config` (as `examples/members` does),
the same thing happens for that file: it's generated on first run — 32 random
bytes, written `chmod 600` with `O_EXCL` so a race can't clobber an existing
one — and printed once as "back this up". Losing it doesn't expose anything;
`Info.id` is `HMAC-SHA256(secret, fingerprint)`, so losing the secret just
re-pseudonymises every user — everyone looks new on their next connection.
Back it up the same way you'd back up the host key.

Both files being group- or world-readable triggers a startup warning
(`warn_if_world_readable`); it doesn't stop the server, so don't rely on the
warning catching a misconfigured deploy for you.

## Where to go next

- [`./tui.md`](./tui.md) — drawing and input: `Screen`, `Style`, `Msg`, the
  key/mouse event model.
- [`./ssh.md`](./ssh.md) — the server API underneath sshtui: `ssh.Config`,
  `Session`, `Authenticator`, `Limits`.
- [`./sshtui.md`](./sshtui.md) — reference for the glue layer covered here:
  `Config`, `Info`, `serve`, `run_local`.
- [`./security.md`](./security.md) — auth semantics and key privacy in more
  depth than the README: the two-message handshake, why rejecting keys
  harvests them, `identity_secret`.
- [`./architecture.md`](./architecture.md) — internals: threading model, the
  diff renderer, the blocking/polling strategy.
- [`./cookbook.md`](./cookbook.md) — recipes for common app patterns.
