# Your first SSH app in ten minutes

This tutorial builds a real otsh app from an empty file to something you can
`ssh` into: a screen that shows you who just connected and how. It ends as
exactly [`examples/whoami/main.odin`](../examples/whoami/main.odin) — about
100 lines, the smallest genuinely useful app in this repository, and the one
[`getting-started.md`](./getting-started.md) recommends reading first. You
will build the same file the whole way through, in three steps, each ending
with something you can compile and connect to — so you always know the code
in front of you actually runs before the next idea gets added to it.

This assumes Odin and libssh are already installed and `./build.sh` works —
see [`getting-started.md`](./getting-started.md) if that's not yet true on
your machine; it covers installation, what `build.sh` does, and the
`--local` development loop this tutorial doesn't need. It leans on
[`tui.md`](./tui.md), [`sshtui.md`](./sshtui.md), and
[`security.md`](./security.md) throughout — where something is documented
there in full, this page links to it instead of restating it.

Work inside your otsh checkout, editing `examples/whoami/main.odin` directly,
and build with:

```sh
./build.sh examples/whoami
./whoami
```

Then, from another terminal:

```sh
ssh -p 2223 localhost
```

Port 2223 is arbitrary — the only requirement is that it not collide with the
other bundled examples (`tracker` is 2222, `members` is 2226, `guestbook` is
2228, and by the end of this tutorial's companion piece, `notes` is 2224).

## What you're building

`whoami` requires public-key authentication and shows you, in a box in the
middle of the screen, what the server learned about your connection: your
username, terminal type, how you authenticated, your key's type and
fingerprint, the screen size, and a couple of live counters. It also logs
every authentication attempt to stderr before deciding whether to let it
through — which is always, because rejecting a key is the wrong tool for
the job, and step 3 explains why.

## 1. A box that says hello

Every otsh app is the same three procs wired together with `sshtui.serve`:
`create` runs once, when a client finishes authenticating and asks for a
shell — handed an `sshtui.Info` describing the connection, it returns a
`tui.App`. `update` runs once per incoming `tui.Msg` (a keystroke, a resize,
a tick) and is where your model changes; `view` runs once per frame and is
where you paint. All three run on a thread private to that one connection.

Start with the smallest version that draws anything:

<!-- check:file -->
```odin
package main

import "core:os"
import "otsh:sshtui"
import "otsh:tui"

State :: struct {}

update :: proc(p: ^tui.Program, msg: tui.Msg) {
	#partial switch e in msg {
	case tui.Key:
		if e.kind == .Esc || (e.kind == .Rune && e.r == 'q') {
			tui.quit(p)
		}
	}
}

view :: proc(p: ^tui.Program, sc: ^tui.Screen) {
	tui.draw_box(sc, 2, 1, 30, 5, tui.Style{fg = tui.ansi(6)}, tui.BORDER_ROUND, " whoami ")
	tui.draw_text(sc, 4, 3, "hello, whoami", tui.Style{})
}

create :: proc(info: sshtui.Info) -> tui.App {
	return tui.App{data = new(State), update = update, view = view}
}

destroy :: proc(app: tui.App) {
	free(app.data)
}

main :: proc() {
	cfg := sshtui.Config {
		port          = 2223,
		host_key_path = "whoami_hostkey",
		create        = create,
		destroy       = destroy,
	}

	if !sshtui.serve(cfg) {
		os.exit(1)
	}
}
```

A few things worth sitting with before you add anything else.

**`view` paints a complete frame every tick.** There is no `erase`, no
"undraw the old thing," no diffing at the app level — the runtime clears the
whole cell grid before every call to `view` (`tui.md`, "The model"). Whatever
you don't draw this tick is not there. The diffing that keeps the actual
bytes sent over the wire small happens one layer down, inside `tui.Screen`
itself: `flush` compares the frame you just drew against the one it last
sent and only transmits the difference. You never have to think about that
part — from where you're sitting, drawing is always "describe the current
frame, in full," never "patch the previous one."

**`State` is an empty struct right now, and that's fine.** `tui.App.data` is
a `rawptr` — something has to own the memory it points at, so `create` calls
`new(State)` even though there's nothing in it yet, and `destroy`'s only job
is giving that memory back. Step 2 gives `State` a reason to exist.

**`sshtui.serve` blocks until the server stops**, and returns `false` when it
never started at all — a port already in use, a host key it can neither read
nor write, a libssh too old to be safe. It prints the reason itself; the one
thing `main` adds is the non-zero exit status, because without it a server
that never bound looks exactly like one that ran and shut down cleanly to
whatever launched it. Every `main` in this tutorial keeps that check, and so
does every bundled example.

**Checkpoint.** Build and connect:

```sh
./build.sh examples/whoami
./whoami
ssh -p 2223 localhost
```

The code above draws one rounded box titled " whoami " at a fixed position
near the top-left corner, containing the line "hello, whoami," and nothing
else. Press `q` or `Esc` and the connection ends cleanly — the runtime
restores the terminal (leaves the alternate screen, shows the cursor again)
on every exit path, so you land back at your prompt exactly as it was before
you connected.

## 2. Show what you're connected as

A box that says "hello" is the same for everyone. The interesting part of
`whoami` is that it's different for every connection, because `create` is
handed an `sshtui.Info` describing *this* one:

<!-- check:verbatim sshtui/sshtui.odin -->
```odin
Info :: struct {
	user:        string, // username the client offered — unverified, they pick it
	term:        string, // $TERM, e.g. "xterm-256color"
	// Pseudonymous account id, present when `identity_secret` is configured and
	// the client used a key. This is what you store and key your data on.
	id:          string,
	// Raw SHA256 fingerprint of the verified key. Prefer `id`; persisting this
	// makes your database correlatable with every other service that saw the
	// same key. Useful for showing the user which key they connected with.
	fingerprint: string,
	key_type:    string, // "ssh-ed25519" etc., else ""
	auth_method: string, // "none" | "password" | "publickey" | "local"
	remote_addr: string, // numeric peer address, no reverse DNS
	cols, rows:  int, // initial geometry; use Resize msgs after that
	local:       bool, // true when running via run_local
	session:     ^ssh.Session, // escape hatch; nil when local
}
```

Not every field here is equally trustworthy. `user` is whatever the client
typed after `ssh` — nothing in the protocol verifies it, so treat it as a
label the visitor chose, never as identity or authorization (`security.md`
§9 says the same about `term`). `fingerprint` and `key_type`, by contrast,
describe a key the client *proved possession of*: SSH public-key
authentication is two messages, a probe and a signed proof, and `otsh` only
fills these fields in once the signature has actually verified
(`security.md` §1). That makes them trustworthy as a record of what happened
during the handshake — not, on their own, an authorization decision, which
is what step 3 is about.

Whether `fingerprint` and `key_type` get populated at all depends on how the
client authenticated. If the server offers `none` or `password` alongside
`publickey`, an OpenSSH client tries `none` first, authenticates that way,
and never offers a key — both fields stay empty. `whoami` avoids that by
setting `methods = {.Publickey}` in its `Config`, which removes `none` and
`password` from what the server will accept, so a client has no path in
except offering a key. That's the one line this step adds to `main`.

Extend `State` to hold the `Info`, and `view` to show a handful of its
fields in a small table:

<!-- check:file -->
```odin
package main

import "core:fmt"
import "core:os"
import "otsh:sshtui"
import "otsh:tui"

State :: struct {
	info:  sshtui.Info,
	frame: u64,
}

update :: proc(p: ^tui.Program, msg: tui.Msg) {
	s := (^State)(p.app.data)
	#partial switch m in msg {
	case tui.Tick:
		s.frame = m.frame
	case tui.Key:
		if m.kind == .Esc || (m.kind == .Rune && (m.r == 'q' || m.ctrl && m.r == 'c')) {
			tui.quit(p)
		}
	}
}

view :: proc(p: ^tui.Program, sc: ^tui.Screen) {
	defer free_all(context.temp_allocator)
	s := (^State)(p.app.data)

	label := tui.Style{fg = tui.ansi(8)}
	value := tui.Style{fg = tui.ansi(15), attrs = {.Bold}}

	rows := [][2]string {
		{"user", s.info.user},
		{"term", s.info.term},
		{"auth", s.info.auth_method},
		{"key type", s.info.key_type},
		{"fingerprint", s.info.fingerprint},
		{"size", fmt.tprintf("%d×%d", sc.w, sc.h)},
		{"frames", fmt.tprintf("%d", s.frame)},
		{"sent", fmt.tprintf("%d bytes", p.bytes_out)},
	}

	w := min(sc.w - 4, 64)
	x := (sc.w - w) / 2
	y := max((sc.h - len(rows) - 4) / 2, 1)

	tui.draw_box(sc, x, y, w, len(rows) + 4, tui.Style{fg = tui.ansi(6)}, tui.BORDER_ROUND, " whoami ")
	for row, i in rows {
		tui.draw_text(sc, x + 3, y + 2 + i, row[0], label)
		tui.draw_text_clipped(sc, x + 16, y + 2 + i, w - 19, row[1], value)
	}
	tui.draw_text(sc, x + 3, y + len(rows) + 3, " q to quit ", label)
}

create :: proc(info: sshtui.Info) -> tui.App {
	s := new(State)
	s.info = info
	return tui.App{data = s, update = update, view = view}
}

destroy :: proc(app: tui.App) {
	free(app.data)
}

main :: proc() {
	cfg := sshtui.Config {
		port          = 2223,
		host_key_path = "whoami_hostkey",
		create        = create,
		destroy       = destroy,
		methods       = {.Publickey}, // no anonymous access
	}

	if !sshtui.serve(cfg) {
		os.exit(1)
	}
}
```

A handful of details are worth calling out.

`view` now calls `fmt.tprintf`, which allocates from `context.temp_allocator`
— an arena that gets reset by `free_all(context.temp_allocator)`. That reset
has to happen exactly once per frame, or the arena grows forever, one frame's
worth of throwaway strings at a time; `defer free_all(context.temp_allocator)`
at the top of `view` is how every app in this repository does it, and it's
worth adding as a habit the moment `tprintf` shows up, not after you notice
memory climbing.

The box position also changed: `w := min(sc.w - 4, 64)` caps the width so it
doesn't become absurdly wide on a large terminal, and `x`/`y` center it
against `sc.w`/`sc.h` instead of pinning it to a fixed corner — the same
formula `docs/cookbook.md` recipe 4 documents. `y` is wrapped in
`max(..., 1)` so it never goes negative on a terminal shorter than the
content; `draw_box`/`set_cell` bounds-check and silently drop out-of-range
cells rather than crash, so an unclamped `y` would just mean the top of the
box quietly fails to draw, which is worse than clamping.

`update` grew a `tui.Tick` case — `s.frame = m.frame` — so the "frames" row
has something live to show; `docs/cookbook.md` recipe 6 is worth reading
before you drive animation off `frame` instead of `Tick.dt`, because they're
not the same kind of number. The key check also grew a Ctrl+C case
alongside `q`/`Esc`: `docs/cookbook.md` recipe 12 explains that Ctrl+C
arrives here as an ordinary key (`Key{kind = .Rune, r = 'c', ctrl = true}`),
not a signal, because the client's terminal — not the server — is the one in
raw mode.

**Checkpoint.** Rebuild, restart the server, and reconnect:

```sh
./build.sh examples/whoami
./whoami
ssh -p 2223 localhost
```

You should see a centered box titled " whoami " containing eight rows —
`user`, `term`, `auth`, `key type`, `fingerprint`, `size`, `frames`, `sent` —
each showing this connection's own values, with a footer reading
" q to quit ". `auth` should read `publickey`, and `key type`/`fingerprint`
should both be populated, because `methods = {.Publickey}` just made sure a
key was the only way in. `frames` should be climbing on its own even if
you're not pressing anything, since `view` runs once per tick regardless of
input. `q`, `Esc`, or Ctrl+C all end the session.

## 3. The auth hook and the audit log

The last piece is the one the header comment on the finished file calls out
by name: an authentication hook, and an audit log. `sshtui.Config` has a
field for exactly this:

<!-- check:verbatim sshtui/sshtui.odin -->
```odin
authenticate:  ssh.Authenticator, // nil accepts everyone
```

An `Authenticator` is `#type proc(req: Auth_Request) -> bool`, called during
authentication — before your app exists, before `create` runs — once per key
the client offers. Here is what it's told:

<!-- check:verbatim ssh/server.odin -->
```odin
Auth_Request :: struct {
	user:        string,
	method:      Auth_Method,
	// .Password only. Unlike every other field here, this borrows libssh's own
	// buffer, which is zeroed and freed as soon as the callback returns — copy it
	// if you need it beyond the call.
	password:    string,
	fingerprint: string, // .Publickey only, e.g. "SHA256:0Cn7…" — signature verified
	key_type:    string, // .Publickey only, e.g. "ssh-ed25519"
	id:          string, // pseudonymous account id, when an identity secret is set
	remote_addr: string, // numeric peer address
}
```

Returning `true` lets the connection through to `create`; returning `false`
rejects it. It would be reasonable to guess that `whoami`'s hook rejects
connections whose fingerprint isn't on some list — that's not what it does,
and the reason why is important enough that it isn't repeated in full here.
The short version: an SSH client that holds several keys offers them one at a
time, and if the server rejects a key it simply tries the next one — so a
server that rejects unrecognized keys ends up learning *every* key the client
was willing to offer, before anyone has authenticated at all. Read
[`security.md`](./security.md) §2 for the full argument and the measurement
behind it; the short version above is not a substitute for it. `whoami`'s
hook accepts every key and only logs the attempt:

<!-- check:verbatim examples/whoami/main.odin -->
```odin
// Called during authentication, before the app exists. Return false to reject.
// A real app would look the fingerprint up in a database here.
//
// This prints the fingerprint because the whole point of the example is to show
// it to you. An audit trail you keep should not: `audit` below logs the
// pseudonymous id instead, which does not correlate with any other service.
gate :: proc(req: ssh.Auth_Request) -> bool {
	fmt.printfln("whoami: auth attempt user=%s method=%v key=%s", req.user, req.method, req.fingerprint)
	return true
}
```

A real app that wants to restrict who gets in should do it the way
[`examples/members`](../examples/members/main.odin) does: accept everyone at
the SSH layer, then decide inside the app using `Info.id` — a pseudonymous,
HMAC-derived identifier rather than the raw fingerprint (`security.md` §4).
`whoami` doesn't need that; it exists to show you the fingerprint, not to
demonstrate a pattern worth copying into a production auth hook.

The other new piece is the audit log — a machine-parseable record of listens,
accepts, auth attempts, and sessions, opt-in because every line carries the
client's numeric address:

<!-- check:verbatim sshtui/sshtui.odin -->
```odin
audit:         ssh.Audit_Sink,
```

`ssh.audit_stderr` is a ready-made sink that writes one line per event to
stderr. Wiring both in gives the finished `main`:

<!-- check:verbatim examples/whoami/main.odin -->
```odin
	cfg := sshtui.Config {
		port          = 2223,
		host_key_path = "whoami_hostkey",
		create        = create,
		destroy       = destroy,
		authenticate  = gate,
		methods       = {.Publickey}, // no anonymous access
		audit         = ssh.audit_stderr, // one parseable line per event
	}
```

Add the `gate` proc, add `import "otsh:ssh"` (needed now for
`ssh.Auth_Request` and `ssh.audit_stderr`), and wire both fields into
`Config`, and you have the complete file.

**Checkpoint.** Rebuild and run with the audit log redirected, exactly as the
file's own header comment suggests:

```sh
./build.sh examples/whoami
./whoami 2>audit.log
ssh -p 2223 localhost
```

Connecting should print a line to stdout like
`whoami: auth attempt user=... method=Publickey key=SHA256:...` — the
username you connected as, the method, and your key's fingerprint — and the
app itself should look exactly like the end of step 2. `audit.log` fills up
with the sink's own machine-parseable lines instead (`ssh/audit.odin`
documents the format) — two different views of the same connection, kept
separate on purpose: one for a human watching this terminal, one for a log
file you'd actually keep.

## The complete `main.odin`

This is exactly what's in `examples/whoami/main.odin`:

<!-- check:verbatim examples/whoami/main.odin -->
```odin
// whoami — the smallest useful otsh app: shows who connected and how.
//
// Also demonstrates the auth hook and the audit log. This server requires
// public-key auth, so `info.fingerprint` is always populated.
//
//	./build.sh examples/whoami && ./whoami
//	ssh -p 2223 localhost
//
// Audit lines go to stderr, one per event, so `./whoami 2>audit.log` keeps the
// record separate from the app's own chatter on stdout.
package main

import "core:fmt"
import "core:os"
import "otsh:ssh"
import "otsh:sshtui"
import "otsh:tui"

State :: struct {
	info:  sshtui.Info,
	frame: u64,
}

update :: proc(p: ^tui.Program, msg: tui.Msg) {
	s := (^State)(p.app.data)
	#partial switch m in msg {
	case tui.Tick:
		s.frame = m.frame
	case tui.Key:
		if m.kind == .Esc || (m.kind == .Rune && (m.r == 'q' || m.ctrl && m.r == 'c')) {
			tui.quit(p)
		}
	}
}

view :: proc(p: ^tui.Program, sc: ^tui.Screen) {
	defer free_all(context.temp_allocator)
	s := (^State)(p.app.data)

	label := tui.Style{fg = tui.ansi(8)}
	value := tui.Style{fg = tui.ansi(15), attrs = {.Bold}}

	rows := [][2]string {
		{"user", s.info.user},
		{"term", s.info.term},
		{"auth", s.info.auth_method},
		{"key type", s.info.key_type},
		{"fingerprint", s.info.fingerprint},
		{"size", fmt.tprintf("%d×%d", sc.w, sc.h)},
		{"frames", fmt.tprintf("%d", s.frame)},
		{"sent", fmt.tprintf("%d bytes", p.bytes_out)},
	}

	w := min(sc.w - 4, 64)
	x := (sc.w - w) / 2
	y := max((sc.h - len(rows) - 4) / 2, 1)

	tui.draw_box(sc, x, y, w, len(rows) + 4, tui.Style{fg = tui.ansi(6)}, tui.BORDER_ROUND, " whoami ")
	for row, i in rows {
		tui.draw_text(sc, x + 3, y + 2 + i, row[0], label)
		tui.draw_text_clipped(sc, x + 16, y + 2 + i, w - 19, row[1], value)
	}
	tui.draw_text(sc, x + 3, y + len(rows) + 3, " q to quit ", label)
}

create :: proc(info: sshtui.Info) -> tui.App {
	s := new(State)
	s.info = info
	return tui.App{data = s, update = update, view = view}
}

destroy :: proc(app: tui.App) {
	free(app.data)
}

// Called during authentication, before the app exists. Return false to reject.
// A real app would look the fingerprint up in a database here.
//
// This prints the fingerprint because the whole point of the example is to show
// it to you. An audit trail you keep should not: `audit` below logs the
// pseudonymous id instead, which does not correlate with any other service.
gate :: proc(req: ssh.Auth_Request) -> bool {
	fmt.printfln("whoami: auth attempt user=%s method=%v key=%s", req.user, req.method, req.fingerprint)
	return true
}

main :: proc() {
	cfg := sshtui.Config {
		port          = 2223,
		host_key_path = "whoami_hostkey",
		create        = create,
		destroy       = destroy,
		authenticate  = gate,
		methods       = {.Publickey}, // no anonymous access
		audit         = ssh.audit_stderr, // one parseable line per event
	}

	// serve returns false when the server never came up — port in use, bad
	// host key, libssh too old — after printing why. Exiting 0 would hide it.
	if !sshtui.serve(cfg) {
		os.exit(1)
	}
}
```

## Where to go next

- [`tutorial-tui.md`](./tutorial-tui.md) — the same style of step-by-step
  build, but for `tui` alone: a stopwatch with no SSH, and the place to
  learn the drawing and input model in depth.
- [`tutorial-notes.md`](./tutorial-notes.md) — the next step up: multiple
  views behind one model, and per-user state that persists across
  reconnects, both driven by the `Info.id` this tutorial only named.
- [`cookbook.md`](./cookbook.md) — recipes for what almost every app needs
  past this one: a scrollable list, a text field, responsive layout, colors,
  mouse support.
- [`security.md`](./security.md) — the full identity and auth story this
  tutorial only sketched: why rejecting keys is harmful, what `Info.id`
  actually is, and what otsh has and hasn't had checked.
- [`sshtui.md`](./sshtui.md) and [`tui.md`](./tui.md) — full reference for
  everything used above.
