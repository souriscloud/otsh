# Tutorial: a stopwatch, with no SSH involved

![The finished stopwatch, captured from a real terminal session](assets/stopwatch.svg)

This is what you are building. The screenshot above is a real capture of the
finished program, not a mockup.

This tutorial covers the `tui` package on its own — no `ssh`, no `sshtui`,
no network of any kind. Everything you build here runs as a plain local
binary: you build it, you run it, it draws in the terminal you're already
sitting at. That is a legitimate use of otsh by itself, not just a stepping
stone, and it is also the right place to *start* even if a networked app is
your actual goal: `tui` is the rendering model underneath everything else in
this repo, and it is easier to learn without a second process, a socket, and
an SSH client in the loop.

If you already know `tui` and want the SSH half — serving the same kind of
app to many concurrent connections — see
[`tutorial-guestbook.md`](./tutorial-guestbook.md) instead. This page ends by
showing exactly how little changes when you get there.

This is a tutorial, not a reference. For exhaustive detail on any single
proc, type, or field mentioned here, see [`tui.md`](./tui.md) (the full API)
and [`cookbook.md`](./cookbook.md) (recipes for problems that show up in
almost every app). Both are linked at the point where they'd help, rather
than reproduced here.

## What you're building

A stopwatch: big ASCII-art digits counting `MM:SS`, space to start and stop
it, `l` to record a lap, `r` to reset, a scrollable list of laps once there
are more than fit on screen, and a layout that adapts to whatever terminal
size it's given. The finished program is
[`examples/stopwatch/main.odin`](../examples/stopwatch/main.odin) — every
code block below is either lifted directly from it or a smaller version of
something that ends up there. Build it as you go:

```sh
cd /path/to/otsh
./build.sh examples/stopwatch
./stopwatch
```

`build.sh` drops a binary named `stopwatch` in your current directory (see
[`getting-started.md`](./getting-started.md) if `odin` or `libssh` aren't on
your machine yet — this app needs the same toolchain as every other example
here, even though it never opens a socket).

## 1. The smallest program that draws

Four things make an otsh app run against your own terminal instead of a
network connection: `tui.Local` (a place to save the terminal's original
settings), `tui.local_enter_raw` (which changes them), `tui.local_backend`
(which turns the terminal into the byte source/sink `tui.run` needs), and
`tui.Program` plus `tui.run` (the loop itself). Here is the entire skeleton,
with a model that does nothing yet:

```odin
package main

import "core:fmt"
import "otsh:tui"

Model :: struct {}

update :: proc(p: ^tui.Program, msg: tui.Msg) {
	#partial switch e in msg {
	case tui.Key:
		if e.kind == .Esc || (e.kind == .Rune && e.r == 'q') {
			tui.quit(p)
		}
	}
}

view :: proc(p: ^tui.Program, s: ^tui.Screen) {
	tui.draw_text(s, 2, 1, "press q to quit", tui.Style{})
}

main :: proc() {
	l: tui.Local
	if !tui.local_enter_raw(&l) {
		fmt.eprintln("stopwatch: stdin is not a terminal")
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

This already runs. It is also already the whole shape the finished stopwatch
uses — bigger `Model`, bigger `update`, bigger `view`, same four calls in
`main`.

**Why raw mode is your job here and nowhere else in this repo.** A terminal
in its default ("cooked") mode line-buffers input, echoes what you type, and
turns Ctrl+C into `SIGINT`. None of that is what a TUI wants: you want every
keystroke the instant it arrives, nothing echoed unless you draw it yourself,
and Ctrl+C delivered as a key, not a signal that kills the process out from
under `tui.run`'s cleanup. `tui.local_enter_raw` disables all three
(`tui/local.odin`), and `defer tui.local_exit_raw(&l)` guarantees the
terminal is restored on every exit path — normal quit, a panic, whatever.

Over SSH, this whole step does not exist. The *client's* terminal is what a
human is typing into, and the SSH protocol's `pty-req` already puts *that*
terminal into raw mode before the server sees a single byte — see the
[README](../README.md) for the mechanism. `tui/local.odin` is the only
termios code anywhere in `tui`/`ssh`/`sshtui`, and it exists solely because a
local run has nobody else to do this for it.

`tui.local_enter_raw` returns `false` if stdin isn't a terminal (piping input
into the binary, running it from a script) — handle that instead of letting
`local_backend`'s `ioctl` calls fail confusingly later.

`tui.Program` is a plain struct you declare as a local (`p: tui.Program`);
nothing about it needs heap allocation for a local-only app like this one.
Set `p.backend` and `p.fps` before calling `tui.run`, which owns the rest of
the struct's fields (`quit`, `frame`, `elapsed`, `screen`, and the input
scratch space) for the duration of the loop. `tui.quit(p)` just flips
`p.quit = true`; `run` notices it and stops cleanly — see step 5 for exactly
when.

## 2. The loop

`tui.run` does the same seven things every tick, forever, until `p.quit`
becomes true or the backend reports the connection is gone:

1. **Poll** the backend for input, blocking up to the frame budget
   (`time.Second / p.fps` — 33ms at the default 30fps).
2. **Dispatch input** — decode whatever bytes arrived into `Key`/`Mouse`
   events and hand each one to `update`.
3. **Check for resize** — if the backend's terminal size changed, resize the
   screen buffer and send a `Resize` message.
4. **Send `Tick`** with how much real time passed (more on this in step 3).
5. **Clear** the screen buffer, then call `view` to paint the frame.
6. **Flush** — diff the freshly painted frame against the last one actually
   sent, and write only the difference.
7. **Pace** — if the tick finished under budget, sleep the remainder, so a
   backend that returns instantly can't turn this into a spin loop.

The full breakdown, with the exact escape sequences `run` emits on entry and
exit, is in [`tui.md`](./tui.md#run--the-frame-loop); the one thing worth
internalizing before you write a single `view` proc is step 5: **`view`
paints a complete frame, every tick, from nothing.** There is no `erase`, no
"undraw the old digits before drawing the new ones" — step 5 clears the
*whole* working grid before your code runs, and step 6's diff renderer is
what turns "redraw everything" back into "send only what changed" before any
bytes reach the terminal. You never track what was on screen a tick ago; you
only ever describe what should be there *now*. Get this wrong — draw the
digits only when they change, say — and you get a screen that never
clears the previous frame's leftovers, because nothing told the renderer
those cells should go back to blank.

`App` also has an `init: proc(p: ^Program)` field, called once after the
screen is sized but before the first frame. The stopwatch doesn't need it —
`Model{}`'s zero value (not running, zero elapsed, no laps) is already the
right starting state — but it's there for apps that need to compute
something once up front.

## 3. Time

A stopwatch's entire job is turning "time passed" into "elapsed changed", so
this is the step that actually matters. `tui.Tick` carries three fields:

```odin
Tick :: struct {
	dt:    f64, // seconds since the previous tick
	total: f64, // seconds since the loop started
	frame: u64, // ticks elapsed so far
}
```

Add running state and an accumulator to the model, and drive it off `dt`:

```odin
Model :: struct {
	running: bool,
	elapsed: f64,
}

update :: proc(p: ^tui.Program, msg: tui.Msg) {
	m := (^Model)(p.app.data)
	#partial switch e in msg {
	case tui.Tick:
		if m.running {
			m.elapsed += e.dt
		}
	}
}
```

**Why `dt` and not `frame`.** `frame` only tells you how many ticks have
happened, and a tick is not a fixed slice of wall-clock time unless the loop
hits its target FPS exactly every single iteration — nothing guarantees
that. A slow `view()`, a loaded machine, a terminal emulator that's slow to
drain its output buffer: any of these stretch one tick's real duration
without changing `frame`'s count by even one. If you wrote `m.elapsed += 1.0
/ f64(p.fps)` instead, your stopwatch would drift against a real clock by
exactly however much real ticks deviated from the ideal — slow on a loaded
machine, and there is no way to notice from inside the app, because `frame`
looks identical either way. `dt` is measured directly
(`time.tick_diff` between two `time.tick_now()` calls inside `run`, see
`tui/tui.odin`), so `m.elapsed += e.dt` tracks real time regardless of how
unevenly the ticks carrying it actually arrived. `cookbook.md`'s [frame-rate-independent
animation recipe](./cookbook.md#6-frame-rate-independent-animation) is the
same principle applied to a header pulse instead of a clock.

## 4. Big digits

This is the step that gives the app an actual face: `MM:SS` rendered as
blocky digits several cells tall, built from a lookup table instead of
`fmt.tprintf`.

The trick is a small bitmap per digit — which cells are "lit" — scaled up to
whatever size you want at draw time:

```odin
DIGIT_W :: 3
DIGIT_H :: 5
SCALE   :: 2 // each bitmap cell becomes a SCALE x SCALE block of screen cells

BIG_DIGITS := [10][DIGIT_H]string {
	{"###", "# #", "   ", "# #", "###"}, // 0
	{"  #", "  #", "  #", "  #", "  #"}, // 1
	{"###", "  #", "###", "#  ", "###"}, // 2
	// ... 3 through 9, same shape
}
```

Each row is 3 ASCII bytes: `'#'` for lit, `' '` for unlit. That choice of
character matters more than it looks like it should. The glyph you actually
*draw* is `'█'` (U+2588, full block) — but `'█'` is 3 bytes in UTF-8, and if
the bitmap itself mixed that multi-byte rune with single-byte spaces,
`bmp[row][col]` would stop meaning "column `col`" the moment a row contained
one: byte offset and column offset part ways after the first lit cell, and
every cell after it in that row reads the wrong byte. Keeping the lookup
table single-byte ASCII sidesteps the problem entirely — `bmp[row][col]` is
always a real column index — and you're free to draw any rune you like for
a lit cell, independent of what the table stores.

Drawing one digit is a nested loop over the bitmap, using `tui.set_cell` for
each lit cell, scaled up by `SCALE` in both directions:

```odin
draw_big_glyph :: proc(s: ^tui.Screen, x, y: int, bmp: [DIGIT_H]string, cols: int, style: tui.Style) {
	for row in 0 ..< DIGIT_H {
		line := bmp[row]
		for col in 0 ..< cols {
			if line[col] != '#' {continue}
			for sy in 0 ..< SCALE {
				for sx in 0 ..< SCALE {
					tui.set_cell(s, x + col * SCALE + sx, y + row * SCALE + sy, '█', style)
				}
			}
		}
	}
}
```

`x + col * SCALE + sx` is the grid math this step is really teaching: `col`
is a position in the *bitmap*, `col * SCALE` is where that lands in *screen
columns* once each bitmap cell has become a `SCALE`-wide block, and `+ sx`
walks across that block. Get the scale factor into the wrong place in this
expression (multiply the whole sum instead of just `col`, say) and digits
either overlap or fly apart as `col` grows — the kind of bug that looks
correct for column 0 and wrong everywhere after it, because it's a rate
error, not an off-by-one.

A colon glyph is the same function with a 1-column bitmap:

```odin
BIG_COLON := [DIGIT_H]string{" ", "#", " ", "#", " "}
```

`draw_clock` (in the finished file) lays out two digits, a colon, and two
more digits left to right, advancing an `x` cursor by each glyph's rendered
width plus a gap — the same `draw_text`-style "advance a cursor, return how
far it moved" pattern `tui.draw_text` itself uses, just for glyphs instead of
runes.

For the fine-grained reading (hundredths of a second) and for each lap in
step 6, normal-sized text is the right tool — big digits for `MM:SS`, plain
`draw_text` for everything with more precision than a glance needs:

```odin
format_time :: proc(t: f64) -> string {
	cs := int(t * 100 + 0.5) // round to the nearest hundredth
	mm := cs / 6000
	ss := (cs / 100) % 60
	hh := cs % 100
	return fmt.tprintf("%02d:%02d.%02d", mm, ss, hh)
}
```

## 5. Controls

Wire up the keys a stopwatch needs: space to start/stop, `r` to reset, `l` to
lap, `q`/Esc to quit. This is where `tui.Key` and `tui.Key_Kind` earn their
keep:

```odin
Key :: struct {
	kind:  Key_Kind,
	r:     rune, // valid when kind == .Rune (also .Space, and Ctrl+letter)
	ctrl:  bool,
	alt:   bool,
	shift: bool,
}
```

Space bar arrives as `kind == .Space`, not `.Rune` — check `tui/key.odin` and
you'll find it has its own `Key_Kind` value precisely so you don't have to
compare `r == ' '` and worry about it colliding with, say, Ctrl+Space (which
*is* `.Space` with `ctrl = true`). Everything printable that isn't a named
key (arrows, function keys, Enter, and so on) arrives as `kind == .Rune` with
the actual character in `r`:

```odin
#partial switch e.kind {
case .Esc:
	tui.quit(p)
	return
case .Space:
	m.running = !m.running
	return
case .Rune:
// fall through to the rune switch below
case:
	return
}

switch e.r {
case 'q':
	tui.quit(p)
case 'r', 'R':
	if !m.running {
		m.elapsed = 0
	}
case 'l', 'L':
	if m.running {
		// record a lap — see step 6
	}
}
```

The `case .Rune: // fall through` / `case: return` pair, then a second
`switch` on `e.r`, is the same idiom `examples/tracker/main.odin`'s `key_list`
uses: handle the named keys in one switch, then handle "any other rune" in a
second one, rather than trying to cram both into one `#partial switch`.

Notice `r`/`l` are gated on `!m.running`/`m.running` — a real stopwatch only
lets you reset once it's stopped and only lets you lap while it's running.
Nothing in `tui` enforces that; it's just an `if` around the state change,
the same way you'd guard any other invalid transition.

**Ctrl+C is a `Key`, not a signal, and you have to check for it yourself.**
`local_enter_raw` turned off `ISIG` along with canonical input, which means
the terminal driver no longer intercepts Ctrl+C and turns it into `SIGINT` —
it travels down as the raw byte `0x03`, same as any other keystroke.
`tui/key.odin` decodes every C0 control byte back to the letter that
produces it:

```odin
case b < 0x20:
	return Key{kind = .Rune, r = rune('a' + b - 1), ctrl = true}
```

`0x03` becomes `Key{kind = .Rune, r = 'c', ctrl = true}`. There is no
dedicated "Ctrl+C" key kind — it's `.Rune` with `ctrl` set, exactly like
Ctrl+A, Ctrl+Z, or any other Ctrl+letter chord — so if you don't check for it
explicitly, your app simply never quits on Ctrl+C, which is the one keyboard
shortcut every user will try first out of habit. Check it before anything
else in the `Key` case:

```odin
case tui.Key:
	if e.ctrl && e.r == 'c' {
		tui.quit(p)
		return
	}
	// ... the rest of the switch
```

This is the same check `examples/tracker/main.odin` makes, and
[`cookbook.md`'s graceful-exit recipe](./cookbook.md#12-graceful-exit) covers
it in more depth, including exactly when `tui.quit` actually stops the loop
(hint: not mid-statement — the current `Tick` still gets dispatched, and only
then does drawing stop).

## 6. Laps

A lap is nothing more than "the current `elapsed` value, kept": a
`[dynamic]f64`, appended to when the user presses `l`.

```odin
Model :: struct {
	running:    bool,
	elapsed:    f64,
	laps:       [dynamic]f64,
	lap_offset: int, // scroll position, see below
}
```

```odin
case 'l', 'L':
	if m.running {
		append(&m.laps, m.elapsed)
		m.lap_offset = 0 // keep the newest lap in view
	}
```

Rendering them newest-first means walking the array backward. Reserve
`i == len(laps) - 1` for the newest entry rather than inserting at the front
of the array on every lap (which would mean shifting every existing element
down one slot, an O(n) operation on every single keypress) — indexing
backward is free, so do the reordering at draw time instead of at write
time:

```odin
for row in 0 ..< viewport_h {
	idx_from_end := m.lap_offset + row
	if idx_from_end >= len(m.laps) {break}
	i := len(m.laps) - 1 - idx_from_end
	split := m.laps[i]
	delta := i == 0 ? split : split - m.laps[i - 1]
	// ... draw `i + 1`, `format_time(split)`, `format_time(delta)`
}
```

`delta` — the time since the *previous* lap, not since the start — is what
makes a laps list actually useful; `split` alone just repeats "elapsed so
far" with the labels changed.

Once there are more laps than fit on screen, you need a scroll offset and the
logic to move it without letting the visible window drift away from where
the cursor (or, here, "the newest lap") actually is. This is exactly
[cookbook.md's scrollable-list recipe](./cookbook.md#1-a-scrollable-list-longer-than-the-screen);
the version here is simpler because there's no cursor to keep on screen, just
"clamp the offset to the valid range":

```odin
laps_scroll :: proc(m: ^Model, delta, viewport_h: int) {
	n := len(m.laps)
	if n <= viewport_h {
		m.lap_offset = 0
		return
	}
	max_offset := n - viewport_h
	m.lap_offset = min(max(m.lap_offset + delta, 0), max_offset)
}
```

The cookbook recipe's warning applies here without change: `update` (handling
Up/Down) and `view` (drawing the list) both need `viewport_h`, and if they
compute it two different ways — one of them forgetting a header row, say —
the scroll position and what's actually drawn quietly disagree. Step 7 is
where that number comes from, how the stopwatch avoids the two of them
drifting apart, and why `lap_offset` also has to be re-clamped every time the
window changes size.

## 7. Make it fit any window

Two separate concerns: laying out relative to whatever size the terminal
actually is, and giving up gracefully below some minimum.

**Centering.** `tui.Resize` tells you the terminal changed size, but by the
time your code sees it, `tui.run` has already resized `Screen` — `sc.w`/
`sc.h` in `view` are always current, whether or not this exact tick carried a
`Resize` message. That means layout math belongs in a plain proc that takes
`sc.w`/`sc.h` and recomputes everything from scratch every call, rather than
in the `Resize` case itself:

```odin
layout :: proc(sc_w, sc_h: int) -> (clock_x, clock_y, laps_y, viewport_h: int) {
	clock_x = max((sc_w - CLOCK_BOX_W) / 2, 1)
	clock_y = 2
	laps_y = clock_y + CLOCK_BOX_H + 2
	viewport_h = max(sc_h - laps_y - 2, 0)
	return
}
```

`max(..., 1)`/`max(..., 0)` matter here for the same reason
[`cookbook.md`'s centering recipe](./cookbook.md#4-centering-and-box-layout)
calls them out: on a terminal shorter or narrower than the content wants, the
raw arithmetic goes negative, and a negative coordinate isn't an error —
`set_cell` and everything built on it silently drops out-of-range writes —
it just means part of your layout quietly never appears. Clamping to a
sensible floor turns "mysteriously missing content" into "content pinned to
the edge," which is the failure mode you actually want.

This same `layout` proc is what step 6 needed: call it once in `update`
(discarding the three values you don't need with `_`) and once in `view`,
and `viewport_h` is guaranteed to match between the two, because it's the
same three lines of arithmetic run both times rather than two separate
copies that could drift.

```odin
_, _, _, viewport_h := layout(p.screen.w, p.screen.h)
```

reads `p.screen.w`/`p.screen.h` directly — `Program.screen` is a plain
`Screen` value on the struct, not hidden behind an accessor, so `update` can
read the current geometry the same way `view` does, without `tui` having to
hand it to you as part of every message.

**Giving up below a minimum.** Below some size, don't try to lay out the
real UI at all:

```odin
if sc.w < MIN_W || sc.h < MIN_H {
	msg := fmt.tprintf("terminal too small — need %dx%d, have %dx%d", MIN_W, MIN_H, sc.w, sc.h)
	tui.draw_text_clipped(
		sc,
		max((sc.w - tui.text_width(msg)) / 2, 0),
		sc.h / 2,
		sc.w,
		msg,
		tui.Style{fg = C_ACCENT},
	)
	return
}
```

Two things worth noticing. First, this uses `tui.draw_text_clipped`, not
`tui.draw_text`, even for the fallback message itself — on a terminal narrow
enough to trigger this guard, the message might not fit either, and clipped
degrades to an ellipsis instead of running off the edge or wrapping
somewhere unexpected. Second, centering it uses `tui.text_width(msg)`, not
`len(msg)`. This message happens to be plain ASCII, so the two would agree —
but `len` counts *bytes*, and the moment any string you center contains a
multi-byte rune (a box-drawing character, an em dash, anything outside
ASCII), `len` overshoots and the centering drifts off by however many extra
bytes that rune cost. `tui.text_width` sums each rune's actual column width
and is the only measurement that's correct in general; see [`tui.md`'s text
metrics section](./tui.md#text-metrics) for the full rune-width table this
is built on. Use `text_width` for layout arithmetic even when you're fairly
sure today's string is ASCII — the whole point is not having to re-audit
every `draw_text` call the day it isn't.

**What that guard does not cover.** `view` bails out below the minimum, but
`update` does not: `j`/`k`/Up/Down keep being handled while the "terminal too
small" message is on screen, and down there `layout` reports
`viewport_h == 0`. `laps_scroll`'s `max_offset` is then `n - 0`, so
`lap_offset` can walk right past the newest lap. Grow the window back and
`draw_laps` breaks out on its very first row: a blank laps pane — no rows, not
even the "no laps yet" line — with a stale `▲` in its top corner, until you
happen to press a scroll key and it re-clamps itself.
Nothing is corrupt — the offset is simply still describing a viewport that no
longer exists. So re-clamp whenever the viewport changes, which is precisely
what a `Resize` message announces:

```odin
case tui.Resize:
	_, _, _, viewport_h := layout(e.cols, e.rows)
	laps_scroll(m, 0, viewport_h)
```

A `delta` of `0` turns `laps_scroll` into a pure clamp, so this needs no
second proc. `tui.run` sends `Resize` before that frame's `Tick` and before
it calls `view`, so the corrected offset is already in place for the first
frame drawn at the new size — there is no stale frame in between. It also
fixes the milder version of the same problem, the one that has nothing to do
with the minimum: scroll to the bottom of a short viewport, make the window
taller, and without this the list keeps the old offset and draws three rows
into a pane with room for twelve. `examples/guestbook` and `examples/tracker`
both clamp their scroll state in their own `Resize` cases, for exactly this
reason — an offset only means anything relative to a viewport height, so it
has to be revisited every time that height moves.

## 8. Colour and polish

Three constructors build a `tui.Color`: `tui.no_color()` (terminal default),
`tui.ansi(idx)` (256-color palette), `tui.rgb(r, g, b)` (24-bit true color).
The stopwatch's palette uses both of the non-default ones:

```odin
C_TEXT   := tui.rgb(224, 224, 230)
C_DIM    := tui.ansi(8)
C_ACCENT := tui.rgb(233, 166, 88)
C_GREEN  := tui.rgb(126, 196, 144)
C_BORDER := tui.rgb(90, 86, 100)
```

Notice these are `:=` package-level variables, not `::` constants. `tui.rgb`
and `tui.ansi` are ordinary procs (marked `proc "contextless"`, which affects
whether they need Odin's implicit `context` set up — it doesn't make them
constant-foldable). A `::` declaration needs a value the compiler can fold at
compile time, and a proc call isn't one, so `C_TEXT :: tui.rgb(224, 224,
230)` doesn't compile. A `:=` global has no such restriction — its
initializer is ordinary code that runs once, before `main`, same as any other
package-level variable — so that's the form to reach for whenever you want a
named color built from `rgb`/`ansi` instead of a hand-written
`tui.Color{...}` literal.

**The running/stopped indicator is a color change plus one line of text, not
a banner.** The big digits themselves switch from `C_TEXT` to `C_GREEN` while
running, and a small status line below them adds the hundredths reading and
a one-character glyph (`●` running, `○` stopped):

```odin
digit_style := tui.Style{fg = m.running ? C_GREEN : C_TEXT, attrs = {.Bold}}
```

That's the whole indicator. It reads at a glance, and it never competes with
the clock for attention — restraint here is the polish; a blinking
`*** RUNNING ***` would not be.

**The box.** `tui.draw_box` frames the clock with a title baked into the top
border:

```odin
tui.draw_box(sc, x, y, CLOCK_BOX_W, CLOCK_BOX_H, tui.Style{fg = C_BORDER}, tui.BORDER_ROUND, " stopwatch ")
```

`BORDER_ROUND` is one of four presets in `tui/screen.odin`
(`BORDER_ROUND`, `BORDER_SHARP`, `BORDER_DOUBLE`, `BORDER_THICK` — see
[`tui.md`'s borders section](./tui.md#borders) if you want a different feel).
`draw_box` no-ops below `2x2` and only draws the title if the box is wider
than 4 columns, so it degrades the same way the rest of this app's layout
does: shrink the terminal enough and pieces stop appearing rather than
overlapping or corrupting anything.

`Attr`/`Attrs` — the bit-set behind `Style.attrs` — covers `Bold`, `Dim`,
`Italic`, `Underline`, `Reverse`, `Strike`; the laps list uses `.Italic` for
its empty state (`"no laps yet — press l while running"`) so it reads as a
hint rather than data. Set several at once with a set literal:
`attrs = {.Bold, .Italic}`; see [`cookbook.md`'s colors and styling
recipe](./cookbook.md#9-colors-and-styling) for the `with_fg`/`with_bg`/
`with_attrs` combinators if you find yourself building the same `Style` with
one field changed in several places.

## The complete program

Every piece above, assembled. This is exactly
[`examples/stopwatch/main.odin`](../examples/stopwatch/main.odin) — build it
with `./build.sh examples/stopwatch` from the repo root and run `./stopwatch`
directly, no SSH client, no listening port, no host key file.

```odin
// stopwatch — a local-only stopwatch/interval timer, built on otsh's `tui`
// package alone. No `ssh`, no `sshtui`, no network of any kind: this process
// and your terminal are the whole program.
//
//	./build.sh examples/stopwatch && ./stopwatch
//
//	space         start/stop
//	l             lap (while running)
//	r             reset (while stopped)
//	up/down, j/k  scroll laps
//	q, esc        quit
//	ctrl+c        quit (it's a Key here, not a signal — see tutorial-tui.md)
//
// This file is the finished program from docs/tutorial-tui.md. Read that
// alongside this one; the tutorial builds it up in the same order the
// sections below appear in.
package main

import "core:fmt"
import "otsh:tui"

// --- palette -----------------------------------------------------------
//
// tui.rgb and tui.ansi are ordinary procs, not compiler intrinsics, so they
// cannot appear in a `::` constant declaration — Odin needs a constant
// declaration's value to be foldable at compile time, and a proc call isn't.
// A package-level `:=` variable has no such restriction: its initializer
// runs once, before main, like any other global. Both are marked
// `proc "contextless"`, so neither needs `context` to be set up yet at that
// point — which is exactly why the package can call them here.

C_TEXT   := tui.rgb(224, 224, 230)
C_DIM    := tui.ansi(8)
C_ACCENT := tui.rgb(233, 166, 88)
C_GREEN  := tui.rgb(126, 196, 144)
C_BORDER := tui.rgb(90, 86, 100)

// --- big digits ----------------------------------------------------------
//
// Each digit is a 3x5 bitmap of '#' (lit) and ' ' (unlit) ASCII bytes — ASCII
// on purpose, not the '█' we actually draw, so that `bmp[row][col]` is a
// plain byte index into the row string. If the bitmap itself used '█'
// (U+2588, 3 bytes in UTF-8) mixed with single-byte spaces, byte offset and
// column offset would part ways after the first lit cell in a row, and every
// glyph past that point would come out sheared. Keep the lookup table
// single-byte; pick whatever glyph you like at draw time.

DIGIT_W :: 3
DIGIT_H :: 5
SCALE   :: 2 // each bitmap cell becomes a SCALE x SCALE block of screen cells

GLYPH_W   :: DIGIT_W * SCALE
GLYPH_H   :: DIGIT_H * SCALE
COLON_W   :: SCALE
GLYPH_GAP :: 1

// MM : SS — four digit glyphs and one colon glyph, four gaps between them.
CLOCK_W :: GLYPH_W * 4 + COLON_W + GLYPH_GAP * 4
CLOCK_H :: GLYPH_H

CLOCK_BOX_W :: CLOCK_W + 6 // 2-column padding each side, 1-cell border each side
CLOCK_BOX_H :: CLOCK_H + 6 // padding above the digits, a status line below, borders

MIN_W :: 44
MIN_H :: 24

BIG_DIGITS := [10][DIGIT_H]string {
	{"###", "# #", "   ", "# #", "###"}, // 0
	{"  #", "  #", "  #", "  #", "  #"}, // 1
	{"###", "  #", "###", "#  ", "###"}, // 2
	{"###", "  #", "###", "  #", "###"}, // 3
	{"   ", "# #", "###", "  #", "   "}, // 4
	{"###", "#  ", "###", "  #", "###"}, // 5
	{"###", "#  ", "###", "# #", "###"}, // 6
	{"###", "  #", "   ", "  #", "   "}, // 7
	{"###", "# #", "###", "# #", "###"}, // 8
	{"###", "# #", "###", "  #", "###"}, // 9
}

BIG_COLON := [DIGIT_H]string{" ", "#", " ", "#", " "}

draw_big_glyph :: proc(s: ^tui.Screen, x, y: int, bmp: [DIGIT_H]string, cols: int, style: tui.Style) {
	for row in 0 ..< DIGIT_H {
		line := bmp[row]
		for col in 0 ..< cols {
			if line[col] != '#' {continue}
			for sy in 0 ..< SCALE {
				for sx in 0 ..< SCALE {
					tui.set_cell(s, x + col * SCALE + sx, y + row * SCALE + sy, '█', style)
				}
			}
		}
	}
}

draw_big_digit :: proc(s: ^tui.Screen, x, y, d: int, style: tui.Style) {
	draw_big_glyph(s, x, y, BIG_DIGITS[d], DIGIT_W, style)
}

// Draws MM:SS at (x, y) using the big glyphs, left to right.
draw_clock :: proc(s: ^tui.Screen, x, y: int, elapsed: f64, style: tui.Style) {
	total := min(int(elapsed), 99 * 60 + 59) // clamp so it always fits two digits
	mm := total / 60
	ss := total % 60
	digits := [4]int{mm / 10, mm % 10, ss / 10, ss % 10}

	cx := x
	for i in 0 ..< 2 {
		draw_big_digit(s, cx, y, digits[i], style)
		cx += GLYPH_W + GLYPH_GAP
	}
	draw_big_glyph(s, cx, y, BIG_COLON, 1, style)
	cx += COLON_W + GLYPH_GAP
	for i in 2 ..< 4 {
		draw_big_digit(s, cx, y, digits[i], style)
		cx += GLYPH_W + GLYPH_GAP
	}
}

// Small, normal-size "mm:ss.hh" text — used for the hundredths readout and
// for each line of the laps list, where big glyphs would be overkill.
format_time :: proc(t: f64) -> string {
	cs := int(t * 100 + 0.5) // round to the nearest hundredth
	mm := cs / 6000
	ss := (cs / 100) % 60
	hh := cs % 100
	return fmt.tprintf("%02d:%02d.%02d", mm, ss, hh)
}

// --- model ---------------------------------------------------------------

Model :: struct {
	running:    bool,
	elapsed:    f64, // total seconds accumulated while running
	laps:       [dynamic]f64, // each entry is `elapsed` at the moment of the lap
	lap_offset: int, // index (from the newest lap) of the first visible row
}

// Shared between update (to scroll) and view (to draw) so the two never
// disagree about how tall the laps viewport is — see the cookbook's
// scrollable-list recipe for what goes wrong when they do.
layout :: proc(sc_w, sc_h: int) -> (clock_x, clock_y, laps_y, viewport_h: int) {
	clock_x = max((sc_w - CLOCK_BOX_W) / 2, 1)
	clock_y = 2
	laps_y = clock_y + CLOCK_BOX_H + 2
	viewport_h = max(sc_h - laps_y - 2, 0)
	return
}

laps_scroll :: proc(m: ^Model, delta, viewport_h: int) {
	n := len(m.laps)
	if n <= viewport_h {
		m.lap_offset = 0
		return
	}
	max_offset := n - viewport_h
	m.lap_offset = min(max(m.lap_offset + delta, 0), max_offset)
}

// --- update ----------------------------------------------------------------

update :: proc(p: ^tui.Program, msg: tui.Msg) {
	m := (^Model)(p.app.data)

	#partial switch e in msg {
	case tui.Tick:
		// Accumulate real elapsed seconds, not frame count: the loop's actual
		// interval depends on backend latency and system load, so `dt` is the
		// only measurement of time that is not also a measurement of how busy
		// the machine happened to be this tick.
		if m.running {
			m.elapsed += e.dt
		}

	case tui.Resize:
		// update handles scroll keys even below MIN_W/MIN_H, where layout
		// reports viewport_h == 0 and lap_offset can climb past the newest
		// lap — which would leave the list blank once the window grows back.
		// Re-clamp on every size change, as guestbook and tracker do.
		_, _, _, viewport_h := layout(e.cols, e.rows)
		laps_scroll(m, 0, viewport_h)

	case tui.Key:
		// The terminal is in raw mode (tui.local_enter_raw turned off ISIG),
		// so Ctrl+C never becomes SIGINT — it arrives down the same path as
		// every other keystroke, as byte 0x03, which tui/key.odin decodes to
		// Key{kind = .Rune, r = 'c', ctrl = true}. Handle it explicitly, first.
		if e.ctrl && e.r == 'c' {
			tui.quit(p)
			return
		}

		_, _, _, viewport_h := layout(p.screen.w, p.screen.h)

		#partial switch e.kind {
		case .Esc:
			tui.quit(p)
			return
		case .Space:
			m.running = !m.running
			return
		case .Up:
			laps_scroll(m, -1, viewport_h)
			return
		case .Down:
			laps_scroll(m, 1, viewport_h)
			return
		case .Rune:
		// fall through to the rune switch below
		case:
			return
		}

		switch e.r {
		case 'q':
			tui.quit(p)
		case 'r', 'R':
			// Real stopwatches only let you reset once stopped; do the same
			// here rather than let a reset race a running clock.
			if !m.running {
				m.elapsed = 0
				clear(&m.laps)
				m.lap_offset = 0
			}
		case 'l', 'L':
			if m.running {
				append(&m.laps, m.elapsed)
				m.lap_offset = 0 // keep the newest lap in view
			}
		case 'j':
			laps_scroll(m, 1, viewport_h)
		case 'k':
			laps_scroll(m, -1, viewport_h)
		}
	}
}

// --- view --------------------------------------------------------------

view :: proc(p: ^tui.Program, sc: ^tui.Screen) {
	defer free_all(context.temp_allocator)
	m := (^Model)(p.app.data)

	if sc.w < MIN_W || sc.h < MIN_H {
		msg := fmt.tprintf("terminal too small — need %dx%d, have %dx%d", MIN_W, MIN_H, sc.w, sc.h)
		tui.draw_text_clipped(
			sc,
			max((sc.w - tui.text_width(msg)) / 2, 0),
			sc.h / 2,
			sc.w,
			msg,
			tui.Style{fg = C_ACCENT},
		)
		return
	}

	clock_x, clock_y, laps_y, viewport_h := layout(sc.w, sc.h)

	draw_header(sc)
	draw_clock_panel(sc, m, clock_x, clock_y)
	draw_laps(sc, m, laps_y, viewport_h)
	draw_footer(sc, m, viewport_h)
}

draw_header :: proc(sc: ^tui.Screen) {
	tui.draw_text(sc, 2, 0, "stopwatch", tui.Style{fg = C_ACCENT, attrs = {.Bold}})
	tui.draw_text(sc, 12, 0, "· no ssh involved ·", tui.Style{fg = C_DIM})

	right := fmt.tprintf("%dx%d", sc.w, sc.h)
	x := sc.w - tui.text_width(right) - 2
	if x > 32 {
		tui.draw_text(sc, x, 0, right, tui.Style{fg = C_DIM})
	}
	for col in 0 ..< sc.w {
		tui.set_cell(sc, col, 1, '─', tui.Style{fg = C_BORDER})
	}
}

draw_clock_panel :: proc(sc: ^tui.Screen, m: ^Model, x, y: int) {
	tui.draw_box(sc, x, y, CLOCK_BOX_W, CLOCK_BOX_H, tui.Style{fg = C_BORDER}, tui.BORDER_ROUND, " stopwatch ")

	digit_style := tui.Style{fg = m.running ? C_GREEN : C_TEXT, attrs = {.Bold}}
	inner_x := x + (CLOCK_BOX_W - CLOCK_W) / 2
	inner_y := y + 2
	draw_clock(sc, inner_x, inner_y, m.elapsed, digit_style)

	cs := int(m.elapsed * 100 + 0.5) % 100
	status := m.running ? fmt.tprintf(".%02d  ● running", cs) : fmt.tprintf(".%02d  ○ stopped", cs)
	status_style := tui.Style{fg = m.running ? C_GREEN : C_DIM}
	status_y := inner_y + CLOCK_H + 1
	sx := x + (CLOCK_BOX_W - tui.text_width(status)) / 2
	tui.draw_text(sc, sx, status_y, status, status_style)
}

draw_laps :: proc(sc: ^tui.Screen, m: ^Model, y, viewport_h: int) {
	tui.draw_text(sc, 2, y, "LAPS", tui.Style{fg = C_DIM, attrs = {.Bold}})
	if len(m.laps) > 0 {
		count := fmt.tprintf("%d recorded", len(m.laps))
		tui.draw_text(sc, sc.w - tui.text_width(count) - 2, y, count, tui.Style{fg = C_DIM})
	}

	if viewport_h <= 0 {
		return
	}
	list_y := y + 1

	if len(m.laps) == 0 {
		tui.draw_text(
			sc,
			2,
			list_y,
			"no laps yet — press l while running",
			tui.Style{fg = C_DIM, attrs = {.Italic}},
		)
		return
	}

	// Newest lap first. `lap_offset` counts rows skipped from the newest end,
	// so a fresh lap (lap_offset reset to 0 in update) is always the first
	// thing drawn, and scrolling down walks back through history.
	for row in 0 ..< viewport_h {
		idx_from_end := m.lap_offset + row
		if idx_from_end >= len(m.laps) {break}
		i := len(m.laps) - 1 - idx_from_end
		split := m.laps[i]
		delta := i == 0 ? split : split - m.laps[i - 1]
		line := fmt.tprintf("%2d   %s   +%s", i + 1, format_time(split), format_time(delta))
		tui.draw_text_clipped(sc, 2, list_y + row, sc.w - 6, line, tui.Style{fg = C_TEXT})
	}

	if m.lap_offset > 0 {
		tui.set_cell(sc, sc.w - 3, list_y, '▲', tui.Style{fg = C_ACCENT})
	}
	if m.lap_offset + viewport_h < len(m.laps) {
		tui.set_cell(sc, sc.w - 3, list_y + viewport_h - 1, '▼', tui.Style{fg = C_ACCENT})
	}
}

draw_footer :: proc(sc: ^tui.Screen, m: ^Model, viewport_h: int) {
	y := sc.h - 1
	for col in 0 ..< sc.w {
		tui.set_cell(sc, col, y - 1, '─', tui.Style{fg = C_BORDER})
	}

	left := m.running ? "space stop · l lap · q quit" : "space start · r reset · q quit"
	if len(m.laps) > viewport_h {
		left = fmt.tprintf("%s · ↑↓ scroll laps", left)
	}
	tui.draw_text_clipped(sc, 2, y, sc.w - 4, left, tui.Style{fg = C_DIM})
}

// --- wiring --------------------------------------------------------------
//
// No sshtui, no ssh, no Info, no Create_Proc — a local-only app just needs a
// Local backend and a Program to run it against.

main :: proc() {
	l: tui.Local
	if !tui.local_enter_raw(&l) {
		fmt.eprintln("stopwatch: stdin is not a terminal")
		return
	}
	defer tui.local_exit_raw(&l)

	model := Model{}
	defer delete(model.laps)

	p: tui.Program
	p.backend = tui.local_backend(&l)
	p.fps = 30
	tui.run(&p, tui.App{data = &model, update = update, view = view})
}
```

## Porting this to SSH is four lines

Nothing above mentions `ssh` or `sshtui`. That's not an accident — it's the
entire design of this package set, and it means the stopwatch is already
one `sshtui.serve` call away from being reachable over SSH by many people at
once, with `update`, `view`, `Model`, and every `draw_*` proc unchanged.

The only real difference is *how the `Model` is allocated*, and it follows
directly from how the two entry points differ. `main`'s local version
declares `model := Model{}` on `main`'s own stack, and that's fine, because
`main` doesn't return until `tui.run` does — the model lives exactly as long
as the program runs. `sshtui.Create_Proc` is different: it's called once per
connection and has to *return* a `tui.App` before that connection's loop
starts, so anything it hands back has to outlive the call itself. That means
heap-allocating with `new(Model)`, and freeing it — including the laps
array, which `free` on its own won't reach, since `free` only releases the
one block `new` returned, not whatever that block points into — in a
`Destroy_Proc`:

```odin
import "core:os"
import "otsh:sshtui"

create :: proc(info: sshtui.Info) -> tui.App {
	m := new(Model)
	return tui.App{data = m, update = update, view = view}
}

destroy :: proc(app: tui.App) {
	m := (^Model)(app.data)
	delete(m.laps)
	free(app.data)
}

main :: proc() {
	cfg := sshtui.Config {
		port          = 2222,
		host_key_path = "stopwatch_hostkey",
		create        = create,
		destroy       = destroy,
	}

	// serve returns false when the server never came up — port in use, bad
	// host key, libssh too old — after printing why. Exiting 0 would hide it.
	if !sshtui.serve(cfg) {
		os.exit(1)
	}
}
```

`create`/`destroy`/the `Config` literal/the `serve` call — that's the four
lines (well, four *things*) that change; the `core:os` import tags along only
because a `serve` that never bound has to exit non-zero, the same check every
example in the repository makes. `local_enter_raw`, `local_backend`,
and the manual `tui.Program` setup all disappear, because `sshtui.serve`
builds a `Backend` out of the SSH channel itself instead of your terminal,
and runs the same `tui.run` loop against it per connection, on that
connection's own thread. Every person who connects gets their own `Model`
and their own independent stopwatch, started fresh at `Model{}`'s zero value,
exactly as if they'd run the local binary themselves.

`sshtui.run_local` — a third option — runs this exact `create`/`destroy`
version against your own terminal instead of a socket, which is the
"iterate without an SSH client" loop described in
[`getting-started.md`](./getting-started.md#the---local-development-loop).
For the fuller SSH walkthrough — auth, `Info`, per-connection identity, a
multi-user app with actual state shared across users — see
[`tutorial-guestbook.md`](./tutorial-guestbook.md) and
[`sshtui.md`](./sshtui.md).

## What to try next

- **Mouse wheel to scroll laps**, the way `examples/tracker` uses wheel events
  to move its menu cursor — see [`cookbook.md`'s mouse
  recipe](./cookbook.md#11-mouse-support). Set `p.mouse = true` before
  `tui.run` and handle `tui.Mouse{kind = .Wheel_Up}`/`.Wheel_Down` alongside
  the `j`/`k` handling you already have.
- **A countdown/interval mode** — subtract `dt` instead of adding it, and
  fire an alert (a terminal bell, `\a`, written through the same backend
  `view` already has access to via `p`) when it crosses zero. The `Model`,
  `layout`, and drawing code barely change; only the arithmetic in the
  `Tick` case does.
- **A second view**, cycling through several named timers, the way
  `examples/tracker` switches between its issue list, one issue's detail, and
  the new-issue form behind one `View` enum (`List`, `Detail`, `Compose`) —
  see [`cookbook.md`'s multiple-views recipe](./cookbook.md#2-multiple-viewsscreens-in-one-app).
- **Export laps** to a file when the user presses a key, using `core:os` —
  nothing about `tui` stops you from doing ordinary I/O from inside
  `update`; it just has no opinion about it either way.
- **Serve it over SSH for real** (see the section above), then give it
  per-connection identity and a shared best-time leaderboard across every
  visitor, the way `examples/members` keys a roster off `sshtui.Info.id` — see
  [`cookbook.md`'s per-user state recipe](./cookbook.md#8-per-user-persistent-state-keyed-by-identity).
  That's also where the security tradeoffs of identifying users at all are
  explained; read [`security.md`](./security.md) before you ship it.
