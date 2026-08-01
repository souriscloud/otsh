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

From that point the channel itself is the terminal. Bytes the client sends are
parsed by libssh into the channel's own buffer and drained from there by
`ssh.read`/`take_input` with `ssh_channel_read_nonblocking` (see the input-path
comment at the top of `ssh/server.odin`) — those are keystrokes. Bytes written
with `ssh.write` go out as ANSI escape sequences — those are the display.
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

1. `ls.threads_set_callbacks(ls.threads_get_default())` followed by `ls.init()`
   — in that order, because libssh needs its thread-safety hooks in place
   before any threaded use, and connections start their own threads
   immediately after accept.
2. `ensure_host_key` creates the ed25519 host key on first run.
3. `ls.bind_new` / `ls.bind_options_set` / `ls.bind_listen` build the
   listening socket; `set_algorithms` applies the hardened KEX/cipher/MAC
   allow-lists (or `cfg`'s overrides).
4. The accept loop waits in `wait_readable(listen_fd, ACCEPT_POLL_MS)` — a
   200 ms `poll(2)` on the listening socket — rather than in
   `ssh_bind_accept`, which has no timeout of its own and would leave a stop
   request unnoticed until the next client happened to connect. Only once the
   socket is readable does it call `ls.bind_accept`, which cannot block: a
   connection is already pending.
5. Still on the accept loop, before any thread is committed: `peer_address`
   resolves the numeric remote IP into `s.addr_buf`, an `.Accept` audit event
   is emitted, and `limiter_acquire` reserves a slot. A connection over a
   limit is audited as `.Reject`, disconnected and freed right there — no
   thread and no handshake are ever spent on it.
6. An accepted connection gets its own OS thread:
   `thread.create_and_start_with_poly_data(s, session_thread, self_cleanup = true)`.
   The accept loop does not wait for that thread — it goes straight back to
   `wait_readable`. (If thread creation fails, the loop releases the slot and
   drops the connection itself.)

Everything from here happens on `session_thread`, one call per connection.
The `Session` and its limiter slot already exist; this thread owns releasing
them.

1. If `handshake_seconds > 0`, `ls.options_set(s.sess, .Timeout, &t)` sets
   libssh's own socket timeout, so a client that opens a socket and says
   nothing cannot pin this thread forever.
2. `s.server_cb` (an `ls.Server_Callbacks`) is built and registered with
   `ls.set_server_callbacks`; `ls.set_auth_methods` advertises whichever
   methods `Server.methods` allows.
3. `ls.handle_key_exchange(s.sess)` negotiates ciphers and proves the server
   owns the host key. It comes *after* step 2, not before — that ordering is
   the fix for a one-in-three handshake hang, described at length under Known
   rough edges below.
4. `s.event = ls.event_new()`; `ls.event_add_session(s.event, s.sess)`.
5. A pump loop drives authentication and channel setup:
   `for i := 0; i < 200 && !(s.authenticated && s.chan != nil && s.shell); i += 1 { ls.event_dopoll(s.event, 100) }`.
   Every libssh callback for this connection — `cb_auth_none`,
   `cb_auth_password`, `cb_auth_pubkey`, `cb_channel_open`, `cb_pty_request`,
   `cb_shell_request`, and so on — fires from inside these `event_dopoll`
   calls, on this thread.
6. Once authenticated with an open channel and a shell request, `Handler` (the
   caller-supplied `s.server.handler`) runs and owns the session until it
   returns.
7. `ls.channel_request_send_exit_status(s.chan, 0)`, then the deferred
   `.Session_End` audit event (declared last, so it runs first, while
   `addr_buf` and `id_buf` still hold anything), then the thread's `defer`
   block in the order it is written: release the limiter slot, send channel
   EOF, close and free the channel, remove and free the event, disconnect the
   session, zero `fp_buf`/`id_buf`, free the libssh session, `free(s)`. The
   slot goes back first, which means capacity is restored before the teardown
   work rather than after it.

Because every callback for a given connection fires inside that connection's
own `event_dopoll` call, on that connection's own thread, nothing in the
session path (`Session` fields, the pty geometry) needs a lock. The only
cross-thread shared state in the whole package is `Limiter` (see Concurrency,
below).

**Shutdown runs that same path backwards.** `serve`'s signal handlers do the
one thing a `proc "c"` handler may safely do — an atomic store into
`signal_requested` — and the polling accept loop notices it within
`ACCEPT_POLL_MS`, so nothing needs to be interrupted. The loop then breaks,
`serve` sets `Server.draining`, and every session's next `ssh.read` reports the
connection as finished; each app's own loop unwinds on that, restores the
client's terminal on the way out, and returns through its `Handler`, which
frees the session and releases its slot. `drain_sessions` polls the limiter's
`total` until it reaches zero, bounded by `Config.shutdown_seconds`
(`DEFAULT_SHUTDOWN_SECONDS`, 5). Measured: `SIGTERM` with 3 live `tracker`
sessions completed in 0.55 s with all 3 terminals restored. The header comment
in `ssh/shutdown.odin` and the Shutdown section of `./ssh.md` have the full
story.

## The C callback boundary

Every libssh callback is declared `proc "c"` — no implicit Odin context. Two
of them cross back into ordinary Odin deliberately: `allow` (which calls the
user's `Authenticator` and the audit sink) and `derive_id` (which calls
`pseudonym`), and both do `context = runtime.default_context()` first.
`derive_id` needs one only because the crypto calls underneath it are ordinary
Odin procs: `pseudonym` writes its hex straight into the session's fixed
`id_buf` and returns a string viewing it, allocating nothing, so there is no
arena to free afterwards. No other callback touches an allocator, which is why
`Session` carries fixed-size buffers instead of strings: `user_buf: [64]u8`,
`term_buf: [32]u8`, `fp_buf: [96]u8`, `kt_buf: [64]u8`, `id_buf: [ID_SIZE]u8`
(32 bytes), `addr_buf: [64]u8`. Procs like `copy_cstr`, `set_user`, and the
accessors (`user`, `term`, `fingerprint`, `key_type`, `id`, `remote_addr`) are
all `proc "contextless"` — they cannot allocate even if they wanted to.

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

Input takes exactly one path. libssh parses each CHANNEL_DATA packet into the
channel's own internal buffer (`channel->stdout_buffer` in libssh's
`channels.c`), and `ssh.read` is the only consumer, draining it with
`ssh_channel_read_nonblocking` (`take_input` in `ssh/server.odin`). No
`channel_data_function` is registered, deliberately — see the comment block
above `take_input` and the history below.

Flow control needs no code on this side. libssh only extends the client's
transport window as this side consumes: `grow_window` (libssh `channels.c`)
runs inside every channel read, credits the client with what has been
consumed, and refuses to let it get more than `WINDOW_DEFAULT` — 2 MiB —
ahead of consumption. A client flooding faster than the app reads parks at
most ~2 MiB in libssh's buffer and then blocks in its own `write(2)`, which
is SSH's own backpressure doing its job.

**History — this used to take two paths, and that was the release-blocking
"large paste deafens the session" defect.** A `channel_data_function` copied
bytes into a fixed 4 KiB per-session ring and returned less than offered when
the ring was full, on the belief that libssh re-offers the remainder by
itself. It does not: the callback runs only from libssh's `channel_rcv_data`,
i.e. when the *next* CHANNEL_DATA packet arrives. A paste is one burst
followed by silence, so the tail of a big one sat in the channel buffer with
nothing to release it. Measured on `tracker` before the fix: paste 1 MiB,
~550 KB stranded (`ssh_channel_poll` reports it precisely), and the quit key
— queued behind the stranded bytes — never acted on in 60 s while the screen
kept repainting. 256 KiB happened to drain during the burst itself and
recovered, which made the defect look like a size threshold when it was
really a race between arrival and consumption.

Two half-fixes are worth recording because both *look* right:

- Keeping the callback and also draining the leftover from `read`. Not sound:
  `ssh_channel_read_nonblocking` pumps the packet machinery internally, which
  can fire the callback mid-drain and hand it ring space the drain had
  already counted — measured 42 KB of a 1 MiB paste silently lost exactly
  that way. Two consumers of one buffer cannot be sequenced from out here.
- An earlier attempt at removing the callback was recorded as failing with
  the bytes still stranded. That observation did not survive instrumentation:
  with a byte-accounting probe app, every payload from 4 KiB to 4 MiB now
  arrives complete and in order (e.g. 1,048,577 bytes sent, 1,048,577
  delivered), and the stranded count drains to zero. The earlier attempt most
  likely drained only after `poll(2)` reported the socket readable — after a
  burst nothing more arrives, so a drain gated on readability never runs.
  `read` drains *before* it waits; that ordering is load-bearing.

After a multi-megabyte paste the app still has to chew through the backlog at
its own pace (one 4 KiB `read` per frame — ~120 KB/s at 30 fps), so the
session catches up within seconds rather than instantly; the window cap
bounds that catch-up at roughly 17 s worst case. The end-to-end regression
test is a paste harness — a real `ssh` client on a pty, a fast burst *with*
the client draining output, silence, then one quit key — because a burst
without draining stalls the client's own stdin and proves nothing.

## The blocking problem

This is the least obvious thing in the codebase, and worth documenting
carefully.

`ssh_event_dopoll`'s `timeout_ms` argument looks like it should block for up
to that long when there is nothing to do. On an established session with an
open channel — which is where every measurement below was taken, and where the
frame loop lives — it does not. Measured directly: 100% of calls returned in
under 5 ms regardless of the timeout passed, and a naive loop that called
`event_dopoll` on a fixed interval and nothing else spun at roughly 22,600
frames per second (67,939 frames measured over 3 seconds) — burning a full
core per connection for a session that is sitting idle.

The fix has two parts:

**(a) `ssh.read` waits on the socket itself.** (`ssh/server.odin:read`.) It
first drains anything libssh already holds for the channel (`take_input`,
which never blocks), pumping the protocol once with `event_dopoll(s.event, 0)`
if the first drain comes up empty. Only if there is still nothing does it get
the raw file descriptor with `ls.get_fd(s.sess)` and wait on it directly with
`wait_readable(fd, timeout_ms)` — `posix.poll` in `ssh/net_posix.odin`,
`WSAPoll` in `ssh/net_windows.odin`, the package's one platform split. That
call genuinely blocks the OS thread until the socket is readable or the
timeout elapses. Once it says data is ready, `event_dopoll(s.event, 0)` is
called once more — purely to let libssh
parse the bytes it can now read — and `take_input` drains the result.
libssh's event loop does the protocol parsing; this code does the actual
waiting. Draining *before* waiting is what keeps the tail of a large paste
flowing after the client goes quiet (see Input flow above).

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
and write of both, and they genuinely do run on different threads: a slot is
taken by the accept loop and released by that connection's own thread, and
`drain_sessions` reads `total` under the same lock from `serve`'s thread while
shutting down. The map keys are cloned on insert
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

**A very large paste replays at the app's own read rate, so the session takes
seconds to catch up.** The paste wedge that used to live at the top of this
list is fixed — input now takes a single path and a 1 MiB paste followed by
one `q` delivers every byte, in order, with the quit acted on ~4.7 s later
(measured; 4 MiB caught up in ~13 s, and the 2 MiB transport window bounds
the worst case at roughly 17 s). See "Input flow and backpressure" for the
mechanism, the measurements, and the two half-fixes that looked right and
were not. What remains is the catch-up latency itself: an app consumes one
4 KiB read per frame, so a monster paste means seconds of replay before new
keystrokes — including `ctrl+c`, which is just a byte in the same queue — get
acted on. Killing the ssh client is always available and tears the session
down through the normal path.

**Server callbacks must be installed before key exchange — this was a real
one-in-three hang.** `session_thread` sets `ssh_set_server_callbacks` and
`ssh_set_auth_methods` *before* `ssh_handle_key_exchange`, matching every
libssh server example. The ordering looks arbitrary and is not documented by
libssh; it is load-bearing.

The client's `SERVICE_REQUEST` routinely shares a TCP segment with its
`NEWKEYS`, so `handle_key_exchange` parses it as part of finishing kex. What
libssh then does with it depends entirely on whether server callbacks exist
yet, in `ssh_message_queue` (`src/messages.c`):

```c
if (session->server_callbacks != NULL) {
    ssh_message_reply_default(message);   /* -> SERVICE_ACCEPT */
    SSH_MESSAGE_FREE(message);
    return;
}
...
ssh_list_append(session->ssh_message_list, message);   /* queued, never answered */
```

With the callbacks installed later, the request took the second path: appended
to a list that nothing in this design ever drains. No `SERVICE_ACCEPT` was
sent, the client waited for a reply that would never come, and the connection
died at `handshake_seconds` with no error logged anywhere. Because it depended
on how the client's packets happened to be coalesced, it presented as an
intermittent hang that only appeared under CPU load.

Measured with a minimal C reproducer using nothing but libssh's public API,
30 connections per configuration under load: **9/30 stalled with callbacks
installed after kex, 0/30 with them before**, and identically so on libssh
0.10.6, 0.11.2 and 0.12.2 — there is no libssh version in which the late
ordering is safe. The real `tracker` binary went from 12/30 to 0/30.

Two consequences worth keeping in mind. Authentication can now complete
*inside* `handle_key_exchange`, so no code after it may assume
`s.authenticated` is still false — the pump loop's condition allows for that.
And libssh stranding a mandatory protocol reply with no error and no
documented contract is a genuine upstream robustness gap, distinct from this
bug: see [libssh issue
#360](https://gitlab.com/libssh/libssh-mirror/-/issues/360), which reports the
same symptom and misattributes it to buffer draining.

**`exec` and `subsystem` are refused by design, not by oversight.**
`cb_exec_request` (`ssh/server.odin`) unconditionally returns `ls.ERROR` —
"this server only speaks TUI." Subsystem requests are refused differently:
`channel_subsystem_request_function` is never set on
`Channel_Callbacks` in `cb_channel_open` (it stays a nil `rawptr`), so libssh
itself answers "not supported" without this code being involved at all.

**The auth/channel-setup pump loop is bounded by iteration count, not
time.** `session_thread`'s loop —
`for i := 0; i < 200 && !(...); i += 1 { ls.event_dopoll(s.event, 100) }` —
gives up after 200 iterations, whatever wall-clock time those took. What that
budget is worth in seconds depends on whether `event_dopoll` waits, and the
answer differs by phase: the "returns immediately" finding above was measured
on an *established* session with an open channel, and does not carry over to
the pre-shell pump. Measured against a password-only server
(`methods = {.Password}`) with a real OpenSSH client, timing from when the
prompt appeared: a password typed at 0.5 s, at 8 s and at 15 s got a session
every time. Only at 30 s did the server drop the client — with
`Received disconnect ... 11: Bye Bye`, i.e. the `handshake_seconds` socket
timeout (default 20) firing, not this loop running out of iterations. So during
authentication `event_dopoll(s.event, 100)` does in fact wait, and 200
iterations is ample.

What remains true is where the real backstop lives: a client that opens a
connection and never authenticates is cut off by the `handshake_seconds` /
`SSH_OPTIONS_TIMEOUT` socket timeout set at the top of `session_thread`, not
by this loop's iteration count. The iteration bound is a belt-and-braces cap,
not the thing keeping a thread from being held forever. If a connection
appears to hang before the shell starts, this is still the loop to look at —
it predates the `poll(2)`-based fix in `ssh.read` and does not use it.

**libssh's threading callbacks are set before `ssh_init`.**
`ls.threads_set_callbacks(ls.threads_get_default())` runs before `ls.init()`
in `ssh.serve` — deliberately, since connection threads start immediately
after `serve`'s accept loop begins, and libssh needs its thread-safety hooks
already installed before any concurrent use touches its internal state.
Reordering this would not fail loudly; it would show up as sporadic
corruption once real concurrent connections arrive. The binding is
`ssh_threads_get_default` and not `ssh_threads_get_pthread` for a separate
reason: `callbacks.h` declares the pthread spelling on every platform, but a
Windows libssh only defines the default and noop ones, so binding the pthread
name links everywhere except Windows (see the comment on the binding in
`libssh/libssh.odin`).

**`Session` is under 1 KB.** Six fixed identity/address buffers, the two
libssh callback structs, `Pty`, assorted ints and bools — 792 bytes measured
with `size_of(ssh.Session)` on darwin/arm64. It used to be 17 KB, then 4.8 KB,
when it carried an inline input ring; input buffering now lives in libssh's
own per-channel buffer (see "Input flow and backpressure"), which costs
nothing for an idle connection and is window-bounded at ~2 MiB for one being
flooded. `tests/ssh_test.odin:session_stays_small` holds the struct's size
down — a 2 KiB ceiling rather than an exact figure, since padding is the
compiler's business — so a large buffer cannot quietly move back inline.
