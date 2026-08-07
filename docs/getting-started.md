# Getting started

This page takes you from nothing to a running SSH-served TUI: build the
bundled examples, write your own app, iterate on it without an SSH client, and
link it into a project that lives outside this repo. It does not re-explain
*why* otsh works the way it does — see the [README](../README.md) for the
protocol trick, the auth model, and what is and is not hardened. Read that
before you expose anything here to the network.

In a hurry: `./otsh new ~/src/myapp && ./otsh run ~/src/myapp` scaffolds a
project outside this repo and starts it. [Quick start](#quick-start-the-otsh-command)
is that path in full; every flag it passes is written out in [Using otsh from
a project outside this repo](#using-otsh-from-a-project-outside-this-repo) for
anyone who would rather drive the compiler themselves.

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
  support](#platform-support) below before you rely on that one.

`./otsh doctor` checks all of the above and tells you which one is missing,
as a checklist rather than as a compiler backtrace:

```
otsh doctor — /path/to/otsh

  ok    odin      /usr/local/bin/odin  (dev-2026-07-nightly:819fdc7)
  ok    libssh    0.12.2  (>= 0.10.6)  /opt/homebrew/opt/libssh/lib
  ok    clang     /usr/bin/clang
  ok    otsh      0.3.0  (libssh, ssh, tui, sshtui)

all good
```

It exits non-zero when something is actually broken, so it is usable in a
setup script. On a stock `ubuntu:24.04` with nothing installed it reports three
failures — odin, libssh and clang — each with the line that fixes it; after
`apt install libssh-dev pkg-config clang` only the compiler is still missing.
Both of those were run in a container, and the second is how the libssh check
came to be written the way it is: an empty `/usr/local/lib`, which that image
has and which is where the search falls back to, was reported as "found" until
the check started looking for the library *file* rather than the directory.

### If your Odin lives somewhere custom

Usually you do not have to do anything. When the compiler is not on `$PATH`,
otsh looks where Odin actually ends up when it is built from source or a
nightly is unpacked — `$ODIN_ROOT`, `~/odin`, `~/.odin`, `~/src/Odin`,
`~/Odin`, `~/dev/Odin`, `/usr/local/odin`, `/opt/odin` — and uses the first one
that answers `odin version`. That search runs only after everything explicit
has come up empty, so it can never override a choice you made.

If yours is somewhere else, tell otsh once:

```sh
otsh use-odin ~/src/Odin/odin      # checked, then remembered for every project
otsh use-odin                      # show what is set and what it resolves to
otsh use-odin --unset              # forget it
```

That writes `$XDG_CONFIG_HOME/otsh/odin-path` (`~/.config/otsh/odin-path` by
default) — a setting that belongs to **you**, not to a checkout. It survives
re-cloning otsh, and it applies to every otsh checkout you have, which matters
as soon as you pin one version per project. The path is verified before it is
written: something that is not the Odin compiler is refused rather than saved
and discovered on your next build.

The full resolution order, most specific first:

| | |
| --- | --- |
| `$ODIN` | one invocation — `ODIN=/path/to/odin otsh build .` |
| `.odin-path` next to `otsh` | that one checkout; gitignored, for people working on otsh itself |
| `$XDG_CONFIG_HOME/otsh/odin-path` | you, everywhere — what `otsh use-odin` writes |
| `odin` | your `$PATH` |

Each file is used only if what it names actually resolves, so a stale entry is
skipped rather than obeyed — one checkout seen by two machines at once, a
worktree bind-mounted into a container say, still builds on the machine the
file was not written on. `otsh`, `build.sh` and `test.sh` all resolve through
the same code: the latter two are wrappers around the first.

## Quick start: the `otsh` command

`otsh`, at the root of this repository, is the whole toolchain: it knows where
the collection is and where libssh lives, so nothing has to be typed twice.

```sh
git clone https://github.com/souriscloud/otsh
otsh/otsh doctor              # is this machine ready?
otsh/otsh new ~/src/myapp     # a project that builds and serves as-is
otsh/otsh run ~/src/myapp     # build it and start it
```

Then, from another terminal — or another machine:

```sh
ssh -p 2222 localhost
```

Put it on your `$PATH` once and stop typing the path to the checkout:

```sh
otsh/otsh install          # symlinks itself somewhere on your $PATH
```

It picks a directory already on your `$PATH` if there is a writable one, and
otherwise `~/.local/bin`, telling you the exact line to add for your shell —
`fish_add_path` for fish, a `PATH` export for bash and zsh. `otsh install
--uninstall` removes it. It refuses to overwrite anything that is not its own
symlink.

**Symlink it — do not copy it.** The script resolves its own real location
through the symlink and points `-collection:otsh=` at the checkout it finds
there. A copy sitting in `~/.local/bin` has no `ssh/`, `tui/` or `sshtui/` next
to it, and nothing will build. Nothing about how otsh is distributed changes
here: your app still compiles against a directory of source, and pinning it is
still [checking out a tag](#pinning-and-upgrading-otsh).

| command | what it does |
| --- | --- |
| `otsh new path/to/app [--port N]` | scaffold a runnable project — picks a free port unless you name one |
| `otsh build path/to/app [flags]` | build it; the binary lands **in that directory**, named after it |
| `otsh run path/to/app [args]` | build, then run it from that directory; args after it go to your program |
| `otsh test [path/to/pkg] [flags]` | run a package's tests (default: otsh's own suite) |
| `otsh flags` | print the two compiler flags, for a Makefile, a justfile or an IDE |
| `otsh doctor` | check odin, libssh against the 0.10.6 floor, and clang |
| `otsh version` | version, checkout path, and the commit that checkout is on |

The first bare word is always the package directory; anything starting with a
dash is passed straight to the compiler, so `otsh build ~/src/myapp -o:speed`
and `otsh test -define:ODIN_TEST_NAMES=…` both do the obvious thing.

The binary landing *in* the project directory rather than in your current one
is deliberate, and `otsh run` starting it from there is the same decision:
`Config.host_key_path` is a relative path, so a server started from wherever
you happened to be standing scatters host keys around your filesystem — and a
host key that moves is a host key mismatch on every client that already
connected once.

`./build.sh` and `./test.sh` still exist and still behave exactly as they
always have, including dropping the binary in your *current* directory; they
are now thin wrappers around `otsh build` and `otsh test`. Use whichever you
have the habit of.

### What `otsh new` writes

Three files, and nothing you have to edit before it runs:

| file | |
| --- | --- |
| `main.odin` | the three procs and a config — a box showing who connected, the terminal size, and a keypress count. It also wires `--local` |
| `build.sh` | the project's own build script. It records the checkout it was generated against and delegates to `otsh build`; `OTSH_ROOT=/elsewhere ./build.sh` overrides that without editing the file, and an `otsh` on `$PATH` is the fallback if the recorded checkout is gone |
| `.gitignore` | `*hostkey`, `*_secret`, `*.pem` and the build output — the two secrets are generated on first run, and committing a host key lets anyone impersonate your server |

`main.odin` opens with a `#assert` on `sshtui.VERSION_MINOR` pinning the otsh
minor it was generated against, so pointing the project at an older checkout is
a compile error with a sentence attached rather than a puzzle. See [Assert the
version you need](#assert-the-version-you-need).

Once it exists, the project stands on its own — `cd ~/src/myapp && ./build.sh
&& ./myapp` needs nothing else, and `otsh` never has to be run from inside its
own repository.

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

A second hardware session on 2026-08-01 (same machine, same toolchain,
re-provisioned from scratch) went after the console-control paths in
`ssh/signal_windows.odin` specifically:

- **Closing the server's console window is verified.** The server ran in its
  own real console; posting `WM_CLOSE` to that console's window — what
  clicking its X does, and something `GenerateConsoleCtrlEvent` cannot
  produce — delivered a genuine `CTRL_CLOSE_EVENT`. A connected macOS OpenSSH
  client received the full restore sequence (mouse reporting off, autowrap
  back, cursor shown, alternate screen left) *before* the connection closed,
  and the ssh client exited cleanly instead of hanging. The server printed
  `otsh: stopped; all sessions closed cleanly` and exited 132–255 ms after
  the close across runs. The ~5 s grace the blocking handler bets on was
  measured on the same machine with a probe whose handler never returns: the
  OS killed it 4980–5018 ms after the event, so `CLOSE_WAIT_MS = 4500` keeps
  real margin.
- **A fifth bug surfaced there and is fixed.** A server whose ancestor was
  created with `CREATE_NEW_PROCESS_GROUP` — which is how PowerShell's
  `Start-Process`, cmd's `start`, and most service wrappers launch things —
  inherits an "ignore Ctrl+C" flag that gates `CTRL_C_EVENT` delivery before
  any installed handler is consulted. Such a server ignored Ctrl+C entirely:
  no drain, no exit, an unstoppable process, observed for 20 s before being
  force-killed. `set_stop_handler` now clears the flag
  (`SetConsoleCtrlHandler(NULL, FALSE)`) when it installs the console
  handler; the same launch then drained and restored the connected client's
  terminal in 164 ms.

Still unverified on Windows, and stated so rather than assumed: the
`CTRL_LOGOFF_EVENT` and `CTRL_SHUTDOWN_EVENT` arms of the console handler,
which cannot be tested without logging out or rebooting the machine —
`ssh/signal_windows.odin` says exactly this; concurrent sessions under load;
window-resize reflow; large pastes; the connection limiter; and `examples/`
other than `tracker` and `whoami`, which were built but not run.

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
separate claim, and an unrun workflow file is a prediction rather than a
result — so it was validated locally before it was ever pushed. It has since
run for real (first push, 2026-08-01: all four jobs green, Windows included),
but the local check is still the cheaper place to catch a mistake, and it is
the only way to exercise the file without spending runner minutes. Both tools
run in containers; neither is installed on the host.

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

`./otsh run` builds one and starts it:

```sh
./otsh run examples/tracker    # then: ssh -p 2222 localhost
```

`build.sh` does the build alone, dropping the binary — named after the source
directory — in your current directory:

```sh
./build.sh                     # examples/tracker  -> ./tracker
./build.sh examples/whoami     # examples/whoami -> ./whoami
./build.sh examples/members    # examples/members -> ./members
```

The commands below use `build.sh` because the ports and the run steps are
worth seeing separately. Run any of them and connect with a normal `ssh`
client — no special client, no extra flags, no configuration on the connecting
side.

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
whole surface area in about 100 lines.

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
allocated. `./otsh new ~/src/greeter` writes exactly that shape and you can
skip to running it; the rest of this section builds the same thing by hand,
because the file is short enough to be worth reading once.

Make a new directory anywhere — it does not need to live inside this repo:

```sh
mkdir -p ~/src/greeter
```

`~/src/greeter/main.odin`:

<!-- check:file -->
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

Build and run it from anywhere:

```sh
otsh run ~/src/greeter
ssh -p 2300 localhost
```

or, if you would rather keep the two steps apart and have the binary land in
the directory you are standing in, `build.sh` from the otsh repo still does
that:

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

<!-- check:verbatim examples/tracker/main.odin -->
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

Nothing about otsh needs to be vendored or installed system-wide, and your
project does not need to live anywhere near this checkout.

```sh
otsh build /path/to/yourapp     # -> /path/to/yourapp/yourapp
```

That is the whole of it, from any directory. What follows is what those two
words expand to, because a wrapper you cannot see through is a wrapper you
cannot debug — and because a Makefile, a `justfile`, an IDE build
configuration or your own script has every right to drive the compiler
directly.

### The two flags, and getting them out

```sh
$ otsh flags
-collection:otsh=/path/to/otsh
-extra-linker-flags:"-L/opt/homebrew/opt/libssh/lib -Wl,-rpath,/opt/homebrew/opt/libssh/lib"
```

Paste those into an ordinary `odin build`, exactly as printed — the quotes are
part of it:

```sh
odin build /path/to/yourapp \
  -out:yourapp \
  -collection:otsh=/path/to/otsh \
  -extra-linker-flags:"-L/opt/homebrew/opt/libssh/lib -Wl,-rpath,/opt/homebrew/opt/libssh/lib"
```

Paste, do not substitute: `odin build . $(otsh flags)` is wrong, because the
linker flags contain a space and the shell splits them into two arguments —
`Unknown flag: 'Wl,-rpath,…'` is what that looks like when it happens.

If you do want it in a script, `eval` re-parses the quoting and works:

```sh
eval "odin build . -out:yourapp $(otsh flags | tr '\n' ' ')"
```

In a Makefile the same idea, with `$$` so make passes the `$` through:

```make
yourapp:
	eval "odin build . -out:yourapp $$(otsh flags | tr '\n' ' ')"
```

Deriving the library path yourself instead, which is what `otsh` does when
`pkg-config` is present:

```sh
odin build /path/to/yourapp \
  -out:yourapp \
  -collection:otsh=/path/to/otsh \
  -extra-linker-flags:"-L$(pkg-config --variable=libdir libssh) -Wl,-rpath,$(pkg-config --variable=libdir libssh)"
```

### Why each flag is there

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

`otsh build`, `otsh run`, the `build.sh` that `otsh new` generates, and this
repo's own `./build.sh` all pass exactly these two flags, using `pkg-config`
when it's available and falling back to `/opt/homebrew/opt/libssh/lib` or
`/usr/local/lib` otherwise. On Windows the second flag is spelled
`/LIBPATH:C:/vcpkg/installed/x64-windows/lib` instead — the MSVC linker has no
`-L` and no rpath at all, which is why `ssh.dll` has to be on `%PATH%` at run
time there.

## Pinning and upgrading otsh

There is no package manager here, and that shapes the whole answer.
`-collection:otsh=` points the compiler at a *directory of source*, so **the
version of otsh your app uses is whatever commit that directory is sitting
on**. Nothing is installed, nothing is vendored into your binary as a
prebuilt artifact, and there is no otsh shared library to keep in step —
`import "otsh:sshtui"` compiles otsh's source into your executable every
time you build. The only real shared library in the picture is libssh, and
that one is your system's.

Two consequences worth being explicit about:

- **There is no ABI to break.** You never have a binary compiled against one
  otsh running with another. An incompatible change is always a *compile*
  error, in front of you, before anything ships.
- **A running server does not pick up an upgrade.** Upgrading is rebuild and
  restart, always. Nothing hot-reloads.

The `otsh` command does not change any of this — it is ergonomics on top of
the same two compiler flags. What it does add is a way to see which checkout
you are actually building against, which matters most when `otsh` is a symlink
on your `$PATH` and the checkout is out of sight:

```sh
$ otsh version
otsh 0.3.0
  source   /path/to/otsh
  commit   v0.3.0-1-g9789806
```

The commit line is the honest answer: a tag you checked out and then pulled
past is no longer that tag, and `git describe` says so.

### Pin by checking out a tag

```sh
git clone https://github.com/souriscloud/otsh
cd otsh && git checkout v0.3.0        # the tag is the artifact
```

Then build your app against that path as shown above. For a project you want
reproducible, a submodule pinned to the tag records the exact commit for you:

```sh
git submodule add https://github.com/souriscloud/otsh vendor/otsh
git -C vendor/otsh checkout v0.3.0
git commit -am "pin otsh v0.3.0"
```

If several of your apps share one otsh checkout, upgrading it upgrades all of
them at once. That is fine until it isn't — give an app its own checkout when
you want to move it on its own schedule.

### Assert the version you need

`ssh.VERSION_MAJOR` / `_MINOR` / `_PATCH` and the string `ssh.VERSION` are
compile-time constants, re-exported from `sshtui` so an app that imports only
that package can reach them. Asserting turns "pointed at the wrong checkout"
into a clear build failure instead of a confusing one:

<!-- check:decls -->
```odin
import "otsh:sshtui"

#assert(sshtui.VERSION_MAJOR == 0 && sshtui.VERSION_MINOR >= 3,
        "this app needs otsh >= 0.3.0")
```

`otsh new` writes this line into every project it scaffolds, pinned to the
minor of the checkout it was generated from, so a new project starts with the
guard already in place. Built against a v0.2.0 checkout it produces:

```
Error: Compile time assertion: sshtui.VERSION_MAJOR == 0 && sshtui.VERSION_MINOR >= 3
       ("this app needs otsh >= 0.3.0")
```

### The upgrade itself

1. `git fetch --tags` in your otsh checkout, then `git checkout vX.Y.Z` for the tag you want.
2. Read [CHANGELOG.md](../CHANGELOG.md) for every version between the one you
   were on and the one you are moving to. otsh is `0.MINOR.PATCH`: a **minor**
   may break you, a **patch** may not. Anything needing more than a paragraph
   gets a section in [migrating.md](./migrating.md).
3. Rebuild your app. There is no separate otsh build step. Compile errors are
   the whole of the mechanical risk — if it compiles, no API you used has
   changed shape.
4. Run your own tests, then restart the service.

Behaviour changes are the part a compiler cannot catch for you, which is why
the changelog spells them out. 0.3.0 is the current example: the default bind
address changed, so a server that never set `Config.host` began answering IPv6
clients as well as IPv4. Nothing about that fails to compile — it is a
deployment fact, and it matters if a firewall or ban action in front of your
process only knows about IPv4.

Restarting is safe to do under load. `serve` handles `SIGTERM`, so a
`systemctl restart` stops accepting, tells each connected session its input has
finished, lets every app restore its client's terminal, and exits — measured at
about half a second with sessions attached. See "Shutdown" in
[ssh.md](./ssh.md).

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

## If connecting feels slow, it is probably your terminal, not the server

Some terminal emulators push their own terminfo to a host the first time you
`ssh` to it, so that curses programs like `nano` or `btop` render correctly
there. Ghostty does this — `shell-integration-features` includes
`ssh-terminfo`, which wraps `ssh` in a shell function that runs roughly:

<!-- check:skip Ghostty's own shell-integration source, not otsh code -->
```sh
infocmp -0 -x xterm-ghostty |
  ssh -o ControlMaster=yes -o ControlPersist=60s "$@" '
      infocmp xterm-ghostty >/dev/null 2>&1 && exit 0
      command -v tic >/dev/null 2>&1 || exit 1
      mkdir -p ~/.terminfo && tic -x - && exit 0'
```

That needs to **run a command** on the far end. An otsh server refuses `exec`
by design — it only ever speaks TUI, so `cb_exec_request` returns an error and
no program is ever run — which means `tic` cannot succeed. The emulator only
caches hosts where the install *worked*, so against otsh it retries on every
single connection, forever, and each attempt is time you wait before your app
appears. The giveaway is a line like `Setting up xterm-ghostty terminfo on
…` followed by `Warning: Failed to install terminfo.`

Confirm it in one line — bypass the wrapper and compare:

```sh
time command ssh -p 2222 localhost    # plain ssh, no shell-integration wrapper
```

The fix is to tell the emulator this host is already done, which keeps the
feature working everywhere else. For Ghostty:

```sh
ghostty +ssh-cache --add=user@yourhost    # skip terminfo for this host only
ghostty +ssh-cache                        # list; --remove= to undo
```

Nothing is lost by skipping it. Terminfo exists so a *shell* on the remote can
drive your terminal; an otsh app writes ANSI escapes straight down the channel
and never consults a terminfo database — that is the same reason the server
never allocates a pty. `TERM` still arrives and is readable as `Info.term`;
otsh simply does not need a local entry for it to render.

Turning the feature off globally would also work and is the wrong trade: you
would lose correct terminfo on every ordinary server you ssh into.

## Where to go next

- [`./concepts.md`](./concepts.md) — if any of the above felt like magic:
  what a terminal actually is, what ANSI escapes are, and why answering
  `pty-req` without allocating a pty works. No otsh knowledge assumed.
- The tutorials, in rising order of scope:
  [a first app in ten minutes](./tutorial-first-app.md),
  [a stopwatch with no SSH involved](./tutorial-tui.md),
  [a shared guestbook](./tutorial-guestbook.md),
  [a multi-view notes app](./tutorial-notes.md). Each builds a complete
  program that ships in `examples/`.
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
- [`./static-linking.md`](./static-linking.md) — shipping a binary to a machine
  that has no libssh installed, or into a scratch container: what each platform
  can and cannot do, `otsh build --static`, and why a statically linked libssh
  makes the next libssh CVE your redeploy.
