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
- **libssh ≥ 0.10.** `brew install libssh` on macOS, `apt install libssh-dev`
  on Debian/Ubuntu. otsh does not vendor libssh — `otsh:libssh` is bindings
  against your system copy.
- **macOS, Linux or FreeBSD.** Windows has an experimental port that nobody
  has run yet — see [Platform support](#platform-support) immediately below
  before you rely on it.

`build.sh` looks for an `odin` binary via the `$ODIN` environment variable,
then on your `$PATH`. If neither resolves, it falls back to a hardcoded path
used by this checkout's development environment
(`/Users/souris/work/bench/odin/odin-lang/odin`) — that fallback only matters
if you're working in this exact repo instance; set `$ODIN` or put `odin` on
your `$PATH` anywhere else.

## Platform support

**macOS, Linux and FreeBSD are the supported platforms.** They are what the
library is developed and tested on, and what CI builds and runs the test suite
on.

**Windows support is experimental and has never been validated by a human on
real Windows.** Here is exactly what does and does not stand behind it:

- What exists: every package and example type-checks for `windows_amd64`
  (`odin check tui -collection:otsh=. -target:windows_amd64`, and the same for
  each of `libssh`, `ssh`, `sshtui` and every `examples/` directory), and CI
  runs that check on every push as a blocking step. A separate `windows-latest`
  job installs libssh through vcpkg, builds the packages and examples, and runs
  the test suite.
- What does not exist: anybody having run an otsh server, or the `--local`
  loop, on a Windows machine. The `windows-latest` job is marked
  `continue-on-error`, so at the time of writing it may never have been green.
  Treat "it compiles" as the whole of the evidence.

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
local := false
// ...
switch args[i] {
case "--local", "-l":
	local = true
// ...
}

if local {
	if !sshtui.run_local(cfg) {
		fmt.eprintln("tracker: stdin is not a terminal")
		os.exit(1)
	}
	return
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
