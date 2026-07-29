# Architecture

This page is for someone modifying `otsh` or debugging a session that misbehaves.
It explains why the code is shaped the way it is. For the public API of each
package, see `./ssh.md`, `./tui.md`, and `./sshtui.md`.

## Layering

```
                         app (your code)
                    create / update / view
                     /                  \
              sshtui.serve         tui.run_local
                     |                    |
             +-------+-------+            |
             |               |            |
        ssh.serve       tui.Backend  <----+---- tui
        Session,        (write / poll /        Program, Screen,
        Server,          size closures)         key parser
        read / write          ^
             |                |
        libssh (C)      tui/local.odin
        foreign import   (termios, stdin/stdout)
        "system:ssh"
```

`ssh/server.odin` imports `../libssh` and nothing else in this tree. `tui`'s
four files (`tui.odin`, `screen.odin`, `key.odin`, `local.odin`) import only
`core:*` packages — never `ssh`, never `libssh`. `sshtui/sshtui.odin` is the
only file that imports both `../ssh` and `../tui`.

That separation is not incidental. `tui.Backend` is a struct of three
closures — `write`, `poll`, `size` — and `tui.Program` only ever calls through
that struct. `sshtui` supplies one implementation backed by `ssh.write` /
`ssh.read` / `ssh.size`; `tui/local.odin` supplies another backed by
`posix.read`/`write`/`ioctl(TIOCGWINSZ)`. `tui` never learns which one it is
driving, which is why `sshtui.run_local` can run the identical `App` against a
real terminal with no SSH involved at all, and why `ssh` has no idea a
renderer exists — it moves bytes and nothing more.

## The central idea: no pty, no shell

A normal `sshd` answers a `pty-req` by allocating a real pseudo-terminal and
forking the user's login shell into it. `ssh/server.odin:cb_pty_request`
answers the same request by recording geometry and returning `ls.OK` —
nothing is allocated:

```odin
s.pty = Pty{cols = int(width), rows = int(height), px = ..., py = ..., present = true}
return ls.OK
```

From that point the channel itself is the terminal. Bytes the client sends
arrive in `cb_channel_data` — those are keystrokes. Bytes written with
`ssh.write` go out as ANSI escape sequences — those are the display.
`cb_window_change` sets `s.resized = true` — that message is this protocol's
`SIGWINCH`.

The consequence worth internalizing: raw mode is the client's job. The
client's own terminal enters raw mode locally because *it* asked for a pty.
This server never calls `tcsetattr`, never touches `termios`, and has no
reason to — there is no local tty to put in raw mode. The only termios code
in the repository is `tui/local.odin:local_enter_raw`/`local_exit_raw`, used
exclusively by the local backend, where there genuinely is a controlling
terminal to configure. Grepping the tree for `tcsetattr` or `termios` turns up
nothing under `ssh/` or `sshtui/` — by design, not by omission.

## Connection lifecycle

`ssh.serve` (`ssh/server.odin`) does the one-time setup, then loops on
accept:

1. `ls.threads_set_callbacks(ls.threads_get_pthread())` followed by `ls.init()`
   — in that order, because libssh needs its thread-safety hooks in place
   before any threaded use, and connections start their own threads
   immediately after accept.
2. `ensure_host_key` creates the ed25519 host key on first run.
3. `ls.bind_new` / `ls.bind_options_set` / `ls.bind_listen` build the
   listening socket; `set_algorithms` applies the hardened KEX/cipher/MAC
   allow-lists (or `cfg`'s overrides).
4. The accept loop calls `ls.bind_accept`, which blocks until a TCP connection
   arrives. Each accepted connection gets a fresh heap-allocated `Session`
   (`new(Session)`) and its own OS thread:
   `thread.create_and_start_with_poly_data(s, session_thread, self_cleanup = true)`.
   The accept loop does not wait for that thread — it goes straight back to
   `ls.bind_accept`.

Everything from here happens on `session_thread`, one call per connection:

1. `peer_address` resolves the numeric remote IP; `limiter_acquire` reserves a
   slot or the function returns immediately (dropped before any handshake
   cost is paid).
2. If `handshake_seconds > 0`, `ls.options_set(s.sess, .Timeout, &t)` sets
   libssh's own socket timeout, so a client that opens a socket and says
   nothing cannot pin this thread forever.
3. `ls.handle_key_exchange(s.sess)` negotiates ciphers and proves the server
   owns the host key.
4. `s.server_cb` (an `ls.Server_Callbacks`) is built and registered with
   `ls.set_server_callbacks`; `ls.set_auth_methods` advertises whichever
   methods `Server.methods` allows.
5. `s.event = ls.event_new()`; `ls.event_add_session(s.event, s.sess)`.
6. A pump loop drives authentication and channel setup:
   `for i := 0; i < 200 && !(s.authenticated && s.chan != nil && s.shell); i += 1 { ls.event_dopoll(s.event, 100) }`.
   Every libssh callback for this connection — `cb_auth_none`,
   `cb_auth_password`, `cb_auth_pubkey`, `cb_channel_open`, `cb_pty_request`,
   `cb_shell_request`, and so on — fires from inside these `event_dopoll`
   calls, on this thread.
7. Once authenticated with an open channel and a shell request, `Handler` (the
   caller-supplied `s.server.handler`) runs and owns the session until it
   returns.
8. `ls.channel_request_send_exit_status(s.chan, 0)`, then the `defer` block
   from step 1 runs: send channel EOF, close and free the channel, remove and
   free the event, disconnect the session, zero `fp_buf`/`id_buf`, free the
   libssh session, `free(s)`, and release the limiter slot.

Because every callback for a given connection fires inside that connection's
own `event_dopoll` call, on that connection's own thread, nothing in the
session path (`Session` fields, the ring buffer, the pty geometry) needs a
lock. The only cross-thread shared state in the whole package is `Limiter`
(see Concurrency, below).

## The C callback boundary

Every libssh callback is declared `proc "c"` — no implicit Odin context. Two
of them cross back into ordinary Odin deliberately: `allow` (which calls the
user's `Authenticator`) and `derive_id` (which calls `pseudonym`, using
`context.temp_allocator` for hex encoding) both do
`context = runtime.default_context()` before doing anything that needs an
allocator, and `derive_id` immediately `defer free_all(context.temp_allocator)`
to avoid growing that arena forever on a long-lived thread. No other callback
touches an allocator, which is why `Session` carries fixed-size buffers
instead of strings: `user_buf: [64]u8`, `term_buf: [32]u8`, `fp_buf: [96]u8`,
`kt_buf: [32]u8`, `id_buf: [ID_SIZE]u8` (32 bytes), `addr_buf: [64]u8`. Procs
like `copy_cstr`, `ring_push`, `set_user`, and the accessors (`user`, `term`,
`fingerprint`, `key_type`, `id`, `remote_addr`) are all `proc "contextless"` —
they cannot allocate even if they wanted to.

`ls.Server_Callbacks` and `ls.Channel_Callbacks` (`libssh/libssh.odin`) are
laid out to match `libssh/callbacks.h` field-for-field, in order — libssh
reads this struct directly as C, so an Odin field reorder would silently wire
the wrong function to the wrong event. Slots this codebase does not use
(`auth_gssapi_mic_function`, `channel_signal_function`,
`channel_subsystem_request_function`, and others) are typed `rawptr` and left
at their Odin zero value, which is a nil function pointer libssh treats as
"not implemented." The leading `size: c.size_t` field on both structs is
libssh's forward-compatibility guard — the C library normally sets it via the
`ssh_callbacks_init()` macro and rejects the struct if it is zero; here it is
set explicitly (`size = size_of(ls.Server_Callbacks)` / `size_of(ls.Channel_Callbacks)`)
in `ssh/server.odin:session_thread` and `cb_channel_open`.

## Input flow and backpressure

Every session owns a `Ring` (`ssh/server.odin`): a fixed `data: [MAX_INPUT]u8`
with `start`/`count` cursors, where `MAX_INPUT :: 4 * 1024` (4 KiB).
`cb_channel_data` is the only writer:

```odin
bytes := ([^]u8)(data)[:length]
return c.int(ring_push(&s.input, bytes))
```

The return value is not a status code — libssh's channel-data callback
contract is that the return value is the number of bytes the callback
actually consumed. `ring_push` returns `min(len(src), MAX_INPUT - r.count)`,
so once the ring is full it returns less than `length`. libssh keeps whatever
was not consumed buffered on its side and re-offers it on a later call. That
one return value is the entire flow-control mechanism — there is no explicit
"pause reading" call anywhere in this codebase.

## The blocking problem

This is the least obvious thing in the codebase, and worth documenting
carefully.

`ssh_event_dopoll`'s `timeout_ms` argument looks like it should block for up
to that long when there is nothing to do. It does not. Measured directly:
100% of calls returned in under 5 ms regardless of the timeout passed, and a
naive loop that called `event_dopoll` on a fixed interval and nothing else spun at
roughly 22,600 frames per second (67,939 frames measured over 3 seconds) —
burning a full core per connection for a session that is sitting idle.

The fix has two parts:

**(a) `ssh.read` waits on the socket itself.** (`ssh/server.odin:read`.) It
first drains anything already queued in the ring buffer or already buffered
inside libssh (one `event_dopoll(s.event, 0)` call, timeout zero, used purely
to let libssh parse whatever is already on the wire). Only if that comes up
empty does it get the raw file descriptor with `ls.get_fd(s.sess)` and call
`posix.poll` on it directly, for up to `timeout_ms`. `poll(2)` genuinely
blocks the OS thread until the socket is readable or the timeout elapses.
Once `poll` says data is ready, `event_dopoll(s.event, 0)` is called once
more — this time purely to let libssh parse the bytes it can now read and
feed them to `cb_channel_data` — and the ring is drained. libssh's event loop
does the protocol parsing; this code does the actual waiting.

**(b) `tui.run` paces frames independent of how `poll` behaves.**
(`tui/tui.odin:run`.) Each iteration records `frame_start`, calls
`p.backend.poll(..., int(budget / time.Millisecond))`, does its work, and
before looping again: `if spent := time.tick_since(frame_start); spent < budget { time.sleep(budget - spent) }`.
This matters because `poll` returns immediately whenever there is already
buffered input — a fast typist, a pasted block, or (before fix (a)) a
backend that never blocks at all. Without this second layer, a burst of
input would make frames run back-to-back with no ceiling on rate. `budget` is
derived from `p.fps` (default 30): `time.Duration(int(time.Second) / p.fps)`.

After both fixes, a session runs at roughly 29 fps (slightly under the 30 fps
target, since dispatch/view/flush/write consume part of every frame's
budget), and four concurrent animated sessions cost roughly 3.7% of one core
in total.

## The render pipeline

`app.view` paints a complete frame into `Screen.cur` every tick — nothing is
incremental at the app level, and `screen_clear` resets every cell (and
`cursor_visible`) before each call to `view`. `flush` (`tui/screen.odin`)
is where the incrementality actually happens: it walks `cur` against `prev`
cell by cell and emits only the escape sequences needed to reconcile them.

Three things make that diff cheap to walk and cheap to transmit:

**Run extension.** When `flush` finds a changed cell, it does not emit one
`move_to` per cell — it keeps scanning right, absorbing unchanged cells into
the same run, up to a gap of 4: `gap += 1; if gap > 4 { break }`, reset to 0
on every actually-changed cell. Below that threshold, re-printing a few
unchanged cells is fewer bytes than the `\x1b[y;xH` needed to jump over them,
so the code deliberately does not jump.

**SGR only on change.** `put_style` (which emits `\x1b[0;...m`) is only
called when `!style_valid || cell.style != last_style`. A long run of
same-styled text — most of a UI — costs one style code, not one per
character.

**Wide glyphs.** `set_cell` marks the right half of a double-width character
with `WIDE_CONT :: rune(-1)` and `rune_width`. Two rules follow directly from
that: a run must never *start* on a continuation cell — if the first changed
cell found is `WIDE_CONT`, `flush` backs the cursor position up by one column
(`x -= 1; i -= 1`) to include the lead glyph, because printing half a wide
character is meaningless. And inside a run, a `WIDE_CONT` cell is absorbed
into `prev` but never itself printed (`continue` before `put_rune`) — the
lead glyph already advanced the cursor two columns, tracked via
`cx += max(w, 1)`.

**Full redraw after resize.** `screen_resize` sets `s.full_redraw = true`
whenever dimensions change (and on first init). `flush` checks that flag,
emits `\x1b[0m\x1b[2J`, and zeroes every cell of `prev` — which makes every
cell of the new frame count as "changed" on the very next diff pass, so the
whole screen repaints through the ordinary run-extension path rather than a
special code path.

Verified on a 100×30 session: first paint 6.3 KB, idle throughput about
530 B/s (only the one animated element differs frame to frame), one keypress
about 230 B. A naive full repaint of the same 100×30 grid would cost roughly
6 KB every frame — at 30 fps that is 180 KB/s, versus ~530 B/s at idle here.

## Input parsing

`parse_input` (`tui/key.odin`) decodes one event from the front of whatever
bytes have arrived, returning `ok = false` when the buffer holds an
incomplete sequence. It has to reconcile several competing conventions in one
byte stream:

- **UTF-8.** `utf8_len` reads the leading byte's high bits to find the
  expected sequence length; if the buffer does not yet have that many bytes,
  parsing returns `ok = false` and waits for more.
- **C0 controls as Ctrl+letter.** Bytes below `0x20` map to
  `Key{kind = .Rune, r = rune('a' + b - 1), ctrl = true}` — `0x01` becomes
  Ctrl+a, `0x1a` becomes Ctrl+z. `0x0d`/`0x0a` are Enter, `0x09` is Tab,
  `0x7f`/`0x08` are Backspace, and `0x00` is Ctrl+Space, handled as special
  cases ahead of the general C0 rule.
- **CSI** (`ESC [ params final`, `parse_csi`) covers arrows, Home/End, and the
  `~`-terminated codes for Insert/Delete/PageUp/PageDown/F1–F12.
  `apply_mods` decodes the modifier parameter (`mod - 1` as a 3-bit field:
  shift/alt/ctrl).
- **SS3** (`ESC O final`, `parse_ss3`) — arrows in application-cursor mode on
  some terminals, and F1–F4 on nearly all of them.
- **SGR mouse** (`ESC [ < b ; x ; y M`/`m`, `parse_sgr_mouse`) — button,
  column, row, and press/release/motion/wheel, decoded from bit flags on `b`.

**The lone-ESC ambiguity.** A single `0x1b` byte is inherently ambiguous: it
might be a complete standalone Escape keypress, or the first byte of a
still-arriving CSI/SS3 sequence. `parse_input` returns `ok = false` for a
lone `0x1b`, which is the correct call in isolation but would wait forever
for a keypress that never grows a second byte. `dispatch_input`
(`tui/tui.odin`) resolves it with a frame-count timeout: `Program.stalls`
increments once per frame that produced no new bytes while `pending` is still
non-empty, and once `stalls >= 2` a pending lone `0x1b` is reported as
`Key{kind = .Esc}` and dropped. Two stalled frames at the configured fps is
the resolution window — the standard terminal-library answer to the standard
problem.

## Terminal setup and teardown

`tui.run` brackets the whole program with escape sequences, emitted once on
entry and reversed once on exit (`tui/tui.odin`):

Entry: `\x1b[?1049h` (enter the alternate screen, so the user's scrollback is
untouched), `\x1b[?25l` (hide the cursor — `view` opts back in per-frame via
`set_cursor`), `\x1b[?7l` (disable autowrap), `\x1b[2J` (clear). If
`p.mouse`, then `\x1b[?1000h\x1b[?1002h\x1b[?1006h` (SGR mouse reporting,
button + motion tracking).

Autowrap is disabled specifically because `flush`'s cursor tracking
(`cx`, `cy`) assumes that writing a cell advances the cursor by exactly that
cell's width and nothing else. A terminal with autowrap enabled that gets a
character written into its bottom-right cell will wrap and typically scroll
the whole view — which would desynchronize `flush`'s idea of the cursor
position from the terminal's actual one, corrupting every diff after it.
Disabling autowrap makes writing the last cell of the screen a no-op for
cursor position instead.

Exit (deferred, so it runs even if the app panics its way out of the loop):
if `p.mouse`, disable mouse reporting first (`\x1b[?1006l\x1b[?1002l\x1b[?1000l`),
then re-enable autowrap (`\x1b[?7h`), show the cursor (`\x1b[?25h`), reset
attributes (`\x1b[0m`), and finally leave the alternate screen (`\x1b[?1049l`)
— restoring the client's terminal to exactly the state it was in before
connecting.

## Concurrency and memory ownership

One OS thread per connection, created in `ssh.serve`'s accept loop and
running `session_thread` end to end. `Session` is heap-allocated by the
accept loop (`new(Session)`) and freed by that same connection's own thread,
in `session_thread`'s `defer` block (`free(s)`) — never by the accept loop,
never by another connection's thread.

The only shared mutable state anywhere in the `ssh` package is `Limiter`
(`ssh/limits.odin`), and it is the only place with a mutex: `mu: sync.Mutex`
guards `total` (the process-wide session count) and `per_ip` (a
`map[string]int`). `limiter_acquire`/`limiter_release` lock around every read
and write of both. The map keys are cloned on insert
(`strings_clone(addr)`) because the `addr` string handed in points into a
`Session`'s own `addr_buf`, which is freed when that session tears down — a
borrowed key would dangle. On release, an IP's count that drops to zero is
removed with `delete_key` and the cloned key string is `delete`d, so the map
does not grow without bound across the lifetime of a long-running process
that has seen many distinct source addresses.

`sshtui.on_session` calls the app's `create` and `destroy` once per
connection, on that connection's thread — which means `create`/`destroy` run
concurrently across every simultaneously-connected client. Neither `ssh` nor
`sshtui` provides any locking for whatever the app itself shares across
connections (a global leaderboard, a shared inventory count, and so on) — if
an app keeps state outside the per-connection `Model`, that state needs its
own synchronization; nothing here provides it for free.

## Known rough edges

**`exec` and `subsystem` are refused by design, not by oversight.**
`cb_exec_request` (`ssh/server.odin`) unconditionally returns `ls.ERROR` —
"this server only speaks TUI." Subsystem requests are refused differently:
`channel_subsystem_request_function` is never set on
`Channel_Callbacks` in `cb_channel_open` (it stays a nil `rawptr`), so libssh
itself answers "not supported" without this code being involved at all.

**The auth/channel-setup pump loop is bounded by iteration count, not
time**, and given the blocking-problem finding above, that distinction
matters. `session_thread`'s loop —
`for i := 0; i < 200 && !(...); i += 1 { ls.event_dopoll(s.event, 100) }` —
calls `event_dopoll` with a 100 ms timeout that, as established, does not
actually wait 100 ms. So this loop is not "up to 20 seconds of polling"; it
can run all 200 iterations in a handful of milliseconds if the client is slow
to respond, then give up. The actual backstop against a client that opens a
connection and never authenticates is the `handshake_seconds` /
`SSH_OPTIONS_TIMEOUT` socket timeout set earlier in `session_thread`, not this
loop's iteration count. If a connection appears to hang or spin briefly
before the shell starts, this is the loop to look at — it predates the
`poll(2)`-based fix in `ssh.read` and does not use it.

**libssh's threading callbacks are set before `ssh_init`.**
`ls.threads_set_callbacks(ls.threads_get_pthread())` runs before `ls.init()`
in `ssh.serve` — deliberately, since connection threads start immediately
after `serve`'s accept loop begins, and libssh needs its thread-safety hooks
already installed before any concurrent use touches its internal state.
Reordering this would not fail loudly; it would show up as sporadic
corruption once real concurrent connections arrive.

**`Session` is about 4.8 KB, almost entirely the 4 KiB `Ring`.** The rest of
the struct (six fixed identity/address buffers, the two libssh callback
structs, `Pty`, assorted ints and bools) adds a few hundred bytes on top.
That is negligible at the default `max_sessions = 256` (roughly 1 MB of ring
buffers at full occupancy), but worth knowing before raising that limit or
setting it negative to disable it — thousands of idle connections cost real,
linearly-scaling memory, before the app's own per-connection `Model` is even
counted. The ring was 16 KiB, which put `Session` at 17 KB; since it is
drained every frame and the flow control above makes an oversized paste
arrive across several frames instead of being dropped, the extra 12 KiB per
connection bought nothing. `tests/ssh_test.odin:session_stays_small` holds
the size down so a new field cannot quietly give it back.
