# tui — rendering and input

`tui` is a cell-buffer terminal UI runtime: an Elm-style update/view loop, a
diffing renderer, and a terminal input parser. It has no dependency on `ssh`
or `sshtui` — everything on this page works against your own terminal, no
network involved. `sshtui` exists to run the same `App` over an SSH channel
instead; see its own docs for that half.

## The model

An app is three procedures glued to a `Program` by an `App` value:

```odin
App :: struct {
	data:   rawptr,
	init:   proc(p: ^Program),
	update: proc(p: ^Program, msg: Msg),
	view:   proc(p: ^Program, s: ^Screen),
}
```

`data` is your model, stored as a `rawptr` and cast back to your own struct
pointer at the top of `update` and `view`:

```odin
Model :: struct { count: int }

update :: proc(p: ^tui.Program, msg: tui.Msg) {
	m := (^Model)(p.app.data)
	...
}
```

`init` runs once, after the screen is sized but before the first frame.
`update` runs once per incoming message. `view` runs once per tick and must
paint a **complete** frame: every cell that should be visible, drawn fresh,
every time. There is no `erase`, no `remove_line`, no incremental diff at the
app level — that part is handled for you, one layer down.

This is a deliberate departure from immediate-mode drawing styles where you
issue a stream of "draw this, then undraw that" calls against a live surface,
and from stateful/incremental UI where widgets track their own prior state
and emit patches. Here the runtime clears the working cell grid before each
call to `view` (`screen_clear`), so anything you don't draw this tick is not
there — the same discipline as a game's render loop or a React re-render.
You never chase down where the *previous* frame left stray content; you
only ever describe the *current* one. The cost of a wrong pixel is a bug in
this tick's `view`, not a leftover from three ticks ago.

The runtime still avoids repainting the terminal on every frame: `Screen`
keeps both the frame most recently drawn (`cur`) and the one it last sent
(`prev`), and `flush` emits only the ANSI needed to turn one into the other.
That diffing is entirely internal to `Screen` — from the app's point of view,
drawing is always "paint everything, every time."

## Backend — what makes an App transport-agnostic

```odin
Backend :: struct {
	data:  rawptr,
	write: proc(data: rawptr, buf: []u8) -> int,
	poll:  proc(data: rawptr, buf: []u8, timeout_ms: int) -> (n: int, ok: bool),
	size:  proc(data: rawptr) -> (cols, rows: int),
}
```

`App` never touches a file descriptor, a socket, or termios. It only ever
sees `Msg` values and draws into a `Screen`. Everything byte-shaped lives
behind `Backend`, so the exact same `App` can run against a local terminal or
an SSH channel with zero changes to app code — the transport is a struct of
three procs and an opaque `data` pointer.

The `poll` contract is the one worth reading twice, since it is what
`tui.run`'s frame loop depends on:

| Return | Meaning |
| --- | --- |
| blocks up to `timeout_ms` | `poll` should not return sooner than it has to, and must never block longer than `timeout_ms` |
| `n == 0, ok == true` | the timeout elapsed with nothing typed — not an error |
| `n > 0, ok == true` | `buf[:n]` holds newly read bytes |
| `ok == false` | the connection is gone; `run` stops the loop |

A backend whose `poll` sometimes returns early (before `timeout_ms`) is
fine — `run` paces frames itself afterward, so an eager `poll` cannot turn
into a spin loop.

`write` returns the number of bytes actually written; `size` reports current
terminal geometry in cells and is polled once per tick to detect resizes.

Two backends exist in this codebase:

- `tui.local_backend` (`tui/local.odin`) — the local terminal, described in
  the local-terminal section below.
- the SSH backend, supplied by `sshtui` (not part of this package) — it wraps
  an `ssh.Session`'s read/write/size as a `Backend` so `sshtui.serve` can run
  a `Program` per connection.

## Program

```odin
Program :: struct {
	backend:     Backend,
	app:         App,
	screen:      Screen,
	quit:        bool,
	mouse:       bool, // request mouse reporting from the terminal
	fps:         int,
	frame:       u64,
	elapsed:     f64,
	pending:     [dynamic]u8,
	stalls:      int,
	read_buf:    [4096]u8,
	bytes_out:   u64, // handy for showing off how little the diff renderer sends
	bytes_in:    u64,
}
```

`pending`, `stalls`, and `read_buf` are the input pipeline's own scratch
space; treat them as implementation detail. The fields an app reads (and, for
`fps`/`mouse`, sets before calling `run`) are:

| Field | Type | Meaning |
| --- | --- | --- |
| `fps` | `int` | target frame rate; `run` defaults it to 30 if `<= 0` |
| `mouse` | `bool` | set before `run` to request mouse reporting from the terminal |
| `frame` | `u64` | ticks elapsed so far, incremented once per loop iteration |
| `elapsed` | `f64` | total seconds since the loop started |
| `bytes_out` | `u64` | cumulative bytes written by the renderer |
| `bytes_in` | `u64` | cumulative bytes read from the backend |
| `screen` | `Screen` | the cell grid; `view` draws into `&p.screen` |
| `quit` | `bool` | set by `tui.quit(p)` to stop the loop after this tick |

```odin
quit :: proc(p: ^Program)
```

Sets `p.quit = true`. `run` checks it right after dispatching a `Tick`
message and breaks the loop before drawing that frame, so a `quit` called
from `update` is the app's normal way to end the program (see the `Esc`/`q`
handling in `examples/whoami/main.odin` and `examples/tracker/main.odin`).

## `run` — the frame loop

```odin
run :: proc(p: ^Program, app: App)
```

`run` owns the whole lifecycle: terminal setup, the loop, and teardown.
Per tick, in order:

1. **Poll** the backend for input, blocking up to the frame budget
   (`time.Second / p.fps`). `ok == false` ends the loop.
2. **Dispatch input** — decode and hand off every complete `Key`/`Mouse`
   event accumulated in `p.pending` via `app.update`.
3. **Check for resize** — compare the backend's current `size` against
   `p.screen.w/h`; if it changed, `screen_resize` the buffer and send a
   `Resize` message.
4. **Send `Tick`** with the elapsed `dt`, running total, and frame counter.
   If `app.update` called `tui.quit(p)` anywhere above (including from this
   `Tick`), the loop breaks here, before drawing.
5. **`screen_clear`** the working buffer, then call `app.view` to paint the
   frame.
6. **`flush`** the screen to get the ANSI diff and write it through the
   backend.
7. **Pace the frame** — if the tick finished under budget, sleep the
   remainder so a fast backend does not spin.

Before the loop, `run` enters the alternate screen, hides the cursor, and
disables terminal autowrap (so writing to the bottom-right cell does not
scroll the view):

```
\x1b[?1049h\x1b[?25l\x1b[?7l\x1b[2J
```

If `p.mouse` is set, it also enables mouse reporting (click tracking, drag
tracking, and SGR extended coordinates):

```
\x1b[?1000h\x1b[?1002h\x1b[?1006h
```

All of it is undone on the way out, in reverse, via `defer` — mouse
reporting first (if it was enabled), then autowrap, cursor, and the
alternate screen. An app never has to clean up terminal modes itself; that
symmetry is `run`'s job whether the loop ends via `quit`, a lost connection,
or a resize that never comes.

## `Msg`

```odin
Msg :: union {
	Key,
	Mouse,
	Resize,
	Tick,
}
```

`update` receives one of these per call. Field references:

**`Key`**

| Field | Type | Notes |
| --- | --- | --- |
| `kind` | `Key_Kind` | see Input |
| `r` | `rune` | valid when `kind == .Rune` (also set for `.Space` and for Ctrl+letter combos) |
| `ctrl` | `bool` | |
| `alt` | `bool` | |
| `shift` | `bool` | |

**`Mouse`**

| Field | Type | Notes |
| --- | --- | --- |
| `kind` | `Mouse_Kind` | see Input |
| `button` | `int` | which button, for `.Press`/`.Release`/`.Motion` |
| `x`, `y` | `int` | zero-based cell coordinates |
| `ctrl`, `alt`, `shift` | `bool` | modifier state at click time |

**`Resize`**

| Field | Type | Notes |
| --- | --- | --- |
| `cols` | `int` | new terminal width in cells |
| `rows` | `int` | new terminal height in cells |

`run` already resizes `p.screen` before sending this — an app typically has
nothing to do beyond noting it happened (see `examples/tracker/main.odin`,
which handles `tui.Resize` with a comment and no code).

**`Tick`**

| Field | Type | Notes |
| --- | --- | --- |
| `dt` | `f64` | seconds since the previous tick |
| `total` | `f64` | seconds since the loop started |
| `frame` | `u64` | frame counter |

Drive animation off `dt`, not off the frame counter or a fixed per-frame
increment — the loop's actual interval varies with backend latency and
system load, so `state += 1` per tick runs at a different visual speed
depending on how fast frames actually arrive, while `state += rate * dt`
does not. `examples/tracker/main.odin` does this for its header pulse and
its "changed just now" markers: `m.spinner += e.dt`.

## Input

### Keys

```odin
Key_Kind :: enum u8 {
	None, Rune, Enter, Tab, Shift_Tab, Backspace, Esc, Space,
	Delete, Insert,
	Up, Down, Left, Right, Home, End, Page_Up, Page_Down,
	F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12,
}

Key :: struct {
	kind:  Key_Kind,
	r:     rune, // valid when kind == .Rune
	ctrl:  bool,
	alt:   bool,
	shift: bool,
}
```

C0 control bytes (0x01–0x1f, excluding the ones with their own key —
Enter/Tab/Backspace) decode back to `Key{kind = .Rune, ctrl = true, r = ...}`
with `r` recovered as the letter that produces that control code: Ctrl+C
arrives as byte `0x03` and decodes to `Key{kind = .Rune, r = 'c', ctrl =
true}`. This is why `examples/tracker/main.odin` checks for quit as
`m.ctrl && m.r == 'c'` rather than a dedicated "Ctrl+C" key kind — there
isn't one; it is `.Rune` with `ctrl` set, like every other Ctrl+letter chord.

A lone `Esc` byte is ambiguous with the start of an escape sequence — both
begin with `0x1b`. `run`'s dispatcher resolves this the standard way: if an
incomplete sequence stays incomplete for two ticks in a row, the leading
`0x1b` is reported as `Key{kind = .Esc}`.

### Mouse

```odin
Mouse_Kind :: enum u8 {
	Press,
	Release,
	Motion,
	Wheel_Up,
	Wheel_Down,
}
```

Delivered only when `Program.mouse` was set before `run` (see the `run` frame loop). Wheel
events are also `Mouse` values, distinguished by `kind`.

### Display names

```odin
key_name :: proc(k: Key, buf: []u8) -> string
```

Renders a `Key` as a short human-readable label — `"ctrl+c"`, `"shift+tab"`,
`"f11"`, `"a"` — into a caller-supplied buffer, for help bars and debug
overlays. It does not allocate.

### Driving the parser directly

```odin
parse_input :: proc(buf: []u8) -> (ev: Input, n: int, ok: bool)
```

where `Input :: union { Key, Mouse }`. This is the primitive `run` calls
internally (via its own dispatch loop) to decode one event from the front of
a byte buffer:

- `ok == false` — the bytes in `buf` are an incomplete sequence; wait for
  more and try again with the extended buffer.
- `ok == true` — `n` bytes were consumed from the front of `buf` and `ev`
  holds the decoded event (`ev` may be `nil` for a byte sequence that was
  recognized and skipped, e.g. a malformed SGR mouse report).

Most apps never call this — `run` already turns backend bytes into `Key` and
`Mouse` messages. It is exposed for anyone parsing terminal input outside the
`Program` loop. Note that `parse_input` alone does not implement the
lone-`Esc` timeout described above; that policy lives in `run`'s dispatcher,
so a caller driving `parse_input` directly and wanting the same behavior has
to add it themselves.

## Drawing

All drawing procs take a `^Screen` and clip to its bounds — coordinates
outside `[0, w) x [0, h)` are silently ignored rather than causing an error
or wrapping. An out-of-bounds call has no effect: it cannot corrupt memory
or scroll the view.

```odin
set_cell          :: proc(s: ^Screen, x, y: int, r: rune, style: Style)
draw_text         :: proc(s: ^Screen, x, y: int, text: string, style: Style) -> int
draw_text_clipped :: proc(s: ^Screen, x, y, max_w: int, text: string, style: Style) -> int
fill_rect         :: proc(s: ^Screen, x, y, w, h: int, r: rune, style: Style)
draw_box          :: proc(s: ^Screen, x, y, w, h: int, style: Style, b := BORDER_ROUND, title := "")
set_cursor        :: proc(s: ^Screen, x, y: int)
```

- `set_cell` writes one rune with one style. If `r` is double-width (see
  Text metrics), it also occupies `x + 1` with the internal continuation marker.
  Zero-width runes (combining marks, control bytes) are a no-op.
- `draw_text` writes `text` starting at `(x, y)`, stops at the screen edge,
  and returns the number of columns it consumed (`rune_width` summed over
  the runes actually drawn).
- `draw_text_clipped` is `draw_text` with a hard column budget: if `text`
  would exceed `max_w` columns, it draws as much as fits minus one column
  and appends `…`. Returns columns consumed either way. This is what powers
  every truncated label in `examples/tracker/main.odin` (item names, cart
  lines, the toast).
- `fill_rect` paints a `w x h` block of the given rune and style — draw a
  background panel with `r = ' '` before drawing text over it.
- `draw_box` draws a rectangular border and, if `title` is non-empty and the
  box is wide enough (`w > 4`), overlays the title on the top edge starting
  two columns in, clipped with `draw_text_clipped`. Does nothing if
  `w < 2 || h < 2`.
- `set_cursor` marks the terminal cursor as visible at `(x, y)` for this
  frame. Cursor visibility resets to hidden every `screen_clear`, so a
  text-input widget must call this every `view` it wants the cursor shown.

### Borders

```odin
Border :: struct {
	tl, tr, bl, br, h, v: rune,
}

BORDER_ROUND  :: Border{'╭', '╮', '╰', '╯', '─', '│'}
BORDER_SHARP  :: Border{'┌', '┐', '└', '┘', '─', '│'}
BORDER_DOUBLE :: Border{'╔', '╗', '╚', '╝', '═', '║'}
BORDER_THICK  :: Border{'┏', '┓', '┗', '┛', '━', '┃'}
```

`draw_box`'s `b` parameter defaults to `BORDER_ROUND`; pass one of the others
or a custom `Border` value for a different corner/edge style.

## Style and color

```odin
Color_Mode :: enum u8 { Default, Palette, True }

Color :: struct {
	mode:    Color_Mode,
	idx:     u8,
	r, g, b: u8,
}

no_color :: proc "contextless" () -> Color
ansi     :: proc "contextless" (idx: u8) -> Color
rgb      :: proc "contextless" (r, g, b: u8) -> Color
```

`no_color()` means "terminal default" (emits SGR `39`/`49`, not a specific
color). `ansi(idx)` selects the 256-color palette index. `rgb(r, g, b)`
emits a 24-bit true-color escape. Nothing here queries the terminal for
color support — pick whichever fits the app; `examples/whoami/main.odin`
uses the 256-color palette (`tui.ansi(8)`, `tui.ansi(15)`), `examples/tracker`
uses true color throughout.

```odin
Attr :: enum u8 {
	Bold,
	Dim,
	Italic,
	Underline,
	Reverse,
	Strike,
}
Attrs :: distinct bit_set[Attr;u8]

Style :: struct {
	fg:    Color,
	bg:    Color,
	attrs: Attrs,
}
```

A zero-value `Style{}` is default foreground, default background, no
attributes — always a safe starting point.

```odin
with_fg    :: proc "contextless" (s: Style, c: Color) -> Style
with_bg    :: proc "contextless" (s: Style, c: Color) -> Style
with_attrs :: proc "contextless" (s: Style, a: Attrs) -> Style
```

Each returns a modified copy; `with_attrs` unions `a` into the existing set
rather than replacing it (`s.attrs += a`), so chaining
`with_attrs(with_attrs(s, {.Bold}), {.Underline})` yields both attributes,
not only the last one applied.

## Text metrics

```odin
rune_width :: proc "contextless" (r: rune) -> int
text_width :: proc "contextless" (text: string) -> int
```

`rune_width` returns how many terminal columns one rune occupies, and
`text_width` sums it over a whole string. The answer comes from
`tui/width_table.odin` — sorted, disjoint rune ranges generated from the
Unicode character database by `docs/tools/gen_width.py`, which reads Python's
own `unicodedata` module, so there is no vendored copy of the UCD and no
network fetch. ASCII is answered before the table is touched; everything else
is a binary search over the ranges. The file's header records which Unicode
version it was generated from.

The policy the generator applies:

- East Asian Width **W** and **F** are `2`: CJK ideographs, Hangul syllables,
  fullwidth forms, most emoji.
- Combining marks (categories `Mn`, `Me`) and format characters (`Cf`,
  which covers U+200B–U+200F and the U+FE00–U+FE0F variation selectors) are
  `0`. U+00AD soft hyphen is the exception — terminals draw it, so it is `1`,
  as `wcwidth` has it.
- East Asian Width **A** (ambiguous) is `1`. That is a deliberate choice, not
  a reading of the standard: terminals overwhelmingly render ambiguous-width
  characters narrow, and the U+2500 box-drawing block that `BORDER_ROUND` and
  the other borders are built from is ambiguous. At `2` every box `draw_box`
  drew would be twice the width of the box it frames, and every column after
  it on the line would shift. So is `…`, the character `draw_text_clipped`
  appends.
- C0 controls, DEL, and the C1 controls U+0080–U+009F are `0`, so `set_cell`
  drops them rather than letting a control byte reach the escape stream.
  `wcwidth` reports these as an error; `rune_width` has no error channel.
- Everything else is `1`, including private use (ambiguous) and unassigned
  code points outside the blocks Unicode gives a wide default to.

What is still approximate is grapheme clustering: there is none. Width is
measured per rune, so a ZWJ emoji sequence measures as its parts — 👨 + ZWJ +
👩 is `2 + 0 + 2 = 4` — and so does a skin-tone modifier (`2 + 2`). A terminal
that composes those into one glyph occupies 2 columns and will disagree.
Conjoining Hangul jamo are counted individually rather than composed into the
syllable they form, where `wcwidth` gives the medial and trailing jamo
U+1160–U+11FF a width of `0`. Precomposed Hangul, which is what text almost
always arrives as, is right.

This matters more than it looks like it should, because column position is
the coordinate system the whole rest of the package draws in. `draw_text`
advances its cursor by `rune_width(r)` for every rune it places, and
`set_cell` uses `rune_width` to decide whether a glyph needs a second,
continuation cell. If width were computed wrong for even one rune — say, a
CJK character treated as width 1 — every subsequent `set_cell` call on that
line lands one column off from where it visually needs to be, silently
shifting or truncating everything after it. The same applies to any
alignment math an app does itself: centering with `len(text)` or a naive
rune count instead of `tui.text_width(text)` will misplace text whenever the
string contains a wide or zero-width rune. `examples/tracker/main.odin` uses
`tui.text_width` throughout for exactly this reason — right-aligning prices,
centering the "terminal too small" message, computing where the receipt text
starts.

```odin
WIDE_CONT :: rune(-1) // right half of a double-width cell
```

`WIDE_CONT` is the sentinel `set_cell` writes into the cell immediately
right of a double-width glyph, so the grid has one `Cell` per column even
though the glyph is visually one wide character. `rune_width(WIDE_CONT)` is
`0`, so `set_cell` never lets you draw it directly — you don't produce
`WIDE_CONT`, the drawing primitives do. `flush` uses it to know that a given
cell is a glyph's continuation rather than independent content: it never
starts a redraw run there, and moving through one during a run does not
re-issue a cursor move.

## Screen internals

```odin
Screen :: struct {
	w, h:           int,
	cur:            []Cell,
	prev:           []Cell,
	out:            [dynamic]u8,
	full_redraw:    bool,
	cursor_visible: bool,
	cursor_x:       int,
	cursor_y:       int,
}

Cell :: struct {
	r:     rune,
	style: Style,
}
```

`w`/`h` are the current geometry in cells — read these in `view` to lay out
content responsively, as `examples/tracker/main.odin` does (`sc.w < 54 || sc.h
< 18` gates a "too small" screen). `cur` is the buffer `view` draws into via
the primitives in the Drawing section; `prev` is what was last actually sent, used by `flush`
to compute the diff.

```odin
screen_init    :: proc(s: ^Screen, w, h: int)
screen_destroy :: proc(s: ^Screen)
screen_resize  :: proc(s: ^Screen, w, h: int)
screen_clear   :: proc(s: ^Screen, style := Style{})
flush          :: proc(s: ^Screen) -> []u8
```

`run` calls all five of these for you over the course of the loop:
`screen_init` once at startup, `screen_resize` whenever the backend reports
new geometry, `screen_clear` before every `view`, `flush` after every
`view`, and `screen_destroy` on the way out. An app built on `run` normally
never calls any of them directly — it reads `s.w`/`s.h` and draws. They are
documented here because `Screen` is a plain value: nothing stops a test or a
tool from driving one standalone, without `Program`/`run` at all.

## Local terminal use without SSH

```odin
Local :: struct {
	orig:      posix.termios,
	have_orig: bool,
}

local_backend   :: proc(l: ^Local) -> Backend
local_enter_raw :: proc(l: ^Local) -> bool
local_exit_raw  :: proc(l: ^Local)
```

`local_backend` wires stdin/stdout/`TIOCGWINSZ` up as a `Backend`: `write`
goes to `STDOUT_FILENO`, `poll` does a `poll(2)` on `STDIN_FILENO` up to
`timeout_ms` and reads whatever arrived, `size` reads the window size ioctl
(falling back to 80x24 if it fails).

Raw mode is a purely local concern. A terminal in its default ("cooked")
mode line-buffers input, echoes what you type, and turns Ctrl+C into a
`SIGINT` — all things a TUI has to do itself instead. `local_enter_raw`
disables that:

```odin
raw.c_iflag -= {.BRKINT, .ICRNL, .INPCK, .ISTRIP, .IXON}
raw.c_oflag -= {.OPOST}
raw.c_lflag -= {.ECHO, .ICANON, .IEXTEN, .ISIG}
raw.c_cflag += {.CS8}
raw.c_cc[.VMIN] = 0
raw.c_cc[.VTIME] = 0
```

It saves the original `termios` into `l.orig` first (returning `false` if
`tcgetattr` fails, e.g. stdin is not a TTY) so `local_exit_raw` can restore
it exactly on the way out.

This is the only termios code in the `tui`/`ssh`/`sshtui` stack, and it
exists only because a local run has no one else to do this job. Over SSH,
the *client's* terminal is what a human is typing into, and the SSH protocol
already carries a `pty-req` that puts raw mode on the client side; the
server side (`sshtui`) never calls `tcgetattr`/`tcsetattr` at all — see the
main README for the full explanation of why an SSH-served `tui.App` needs no
termios code whatsoever.

Typical local wiring (this is what `sshtui.run_local` does under the hood):

```odin
l: tui.Local
if !tui.local_enter_raw(&l) {
	// stdin is not a terminal
}
defer tui.local_exit_raw(&l)

p: tui.Program
p.backend = tui.local_backend(&l)
p.fps = 30
tui.run(&p, app)
```

## A minimal example

A counter, run directly against the local terminal — no `ssh`, no `sshtui`.
Up/Down change the count, `q` or `Esc` quits.

```odin
package main

import "core:fmt"
import "otsh:tui"

Model :: struct {
	count: int,
}

update :: proc(p: ^tui.Program, msg: tui.Msg) {
	m := (^Model)(p.app.data)
	#partial switch e in msg {
	case tui.Key:
		#partial switch e.kind {
		case .Up:
			m.count += 1
		case .Down:
			m.count -= 1
		case .Esc:
			tui.quit(p)
		case .Rune:
			if e.r == 'q' {tui.quit(p)}
		}
	}
}

view :: proc(p: ^tui.Program, s: ^tui.Screen) {
	// view runs every frame, so anything drawn from the temp allocator has to
	// be released every frame too — otherwise the arena grows for the life of
	// the session.
	defer free_all(context.temp_allocator)
	m := (^Model)(p.app.data)
	tui.draw_box(s, 2, 1, 24, 5, tui.Style{fg = tui.ansi(6)}, tui.BORDER_ROUND, " counter ")
	tui.draw_text(s, 4, 3, fmt.tprintf("count: %d", m.count), tui.Style{attrs = {.Bold}})
	tui.draw_text(s, 4, 4, "up/down change, q quits", tui.Style{fg = tui.ansi(8)})
}

main :: proc() {
	l: tui.Local
	if !tui.local_enter_raw(&l) {
		fmt.eprintln("counter: stdin is not a terminal")
		return
	}
	defer tui.local_exit_raw(&l)

	model := Model{}
	p: tui.Program
	p.backend = tui.local_backend(&l)
	p.fps = 30
	tui.run(&p, tui.App{data = &model, update = update, view = view})
}
```

Build it against the package collection the same way any otsh app is built
(see the main README for the `-collection:otsh=` flag) and run the
resulting binary directly in a terminal: no `ssh`, no listening socket —
only this process and your TTY.
