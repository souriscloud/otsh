# Cookbook

Recipes for problems that show up in almost every `tui.App`, once you get past
the three-proc skeleton in [`getting-started.md`](./getting-started.md). Each
one is a self-contained snippet you paste into your own `Model`/`update`/`view`
— not a full program. Where a recipe is lifted from a bundled example, the
file is named so you can see it running in context.

The compiler is the source of truth here, not this file: every proc, type,
and constant below is copied from `tui/`, `sshtui/`, or `ssh/` as it actually
exists in this repo. If a signature looks odd, check the source before
assuming the doc is right.

## 1. A scrollable list longer than the screen

Clipping a list at the bottom of its column is not enough once the list is
longer than the screen: you need a cursor *and* an offset for which row is
drawn first, and you have to move the offset whenever the cursor would
otherwise walk off the visible window.

`examples/tracker` does this in `clamp_view` (`examples/tracker/main.odin`),
which is called after every cursor move, after every resize, and after every
tick — because the row count can change underneath you when another connection
files or closes an issue:

<!-- check:verbatim examples/tracker/main.odin -->
```odin
// examples/tracker/main.odin
viewport_rows :: proc(h: int) -> int {
	return max(h - 6, 1)   // rows the list pane can show
}

clamp_view :: proc(m: ^Model, h: int) {
	n := len(m.rows)
	if n == 0 {
		m.cursor, m.offset = 0, 0
		return
	}
	m.cursor = clamp(m.cursor, 0, n - 1)
	rows := viewport_rows(h)
	if m.cursor < m.offset {m.offset = m.cursor}
	if m.cursor >= m.offset + rows {m.offset = m.cursor - rows + 1}
	m.offset = clamp(m.offset, 0, max(n - rows, 0))
}
```

Drawing then starts at the offset and stops when it runs out of rows or space:

<!-- check:skip loop body fragment with a literal "..." elision; illustrates the drawing loop only -->
```odin
for i in 0 ..< rows {
	idx := m.offset + i
	if idx >= len(m.rows) {break}
	...
}
```

The single most common bug here is clamping only on keypress. Anything that
changes the row count — a filter, a resize, another user's edit — has to
re-clamp too, or the cursor silently points past the end.

<!-- check:decls -->
```odin
List :: struct {
	items:  []string,
	cursor: int,
	offset: int, // index of the first visible row
}

list_move :: proc(l: ^List, delta, viewport_h: int) {
	n := len(l.items)
	if n == 0 {return}
	l.cursor = clamp(l.cursor + delta, 0, n - 1)
	// Scroll only as far as it takes to keep the cursor on screen.
	if l.cursor < l.offset {
		l.offset = l.cursor
	}
	if l.cursor >= l.offset + viewport_h {
		l.offset = l.cursor - viewport_h + 1
	}
}

list_view :: proc(sc: ^tui.Screen, l: ^List, x, y, w, h: int) {
	for row in 0 ..< h {
		i := l.offset + row
		if i >= len(l.items) {break}
		st := tui.Style{fg = tui.ansi(15)}
		if i == l.cursor {st.attrs = {.Reverse}}
		tui.draw_text_clipped(sc, x, y + row, w, l.items[i], st)
	}
}
```

Call `list_move(&m.list, -1, viewport_h)` / `list_move(&m.list, 1, viewport_h)`
from your `.Up`/`.Down` key handling, with the same `viewport_h` you pass to
`list_view`. The gotcha: those two numbers have to match. If `update` computes
the viewport height one way and `view` computes it another (e.g. one of them
forgets to subtract a header row), the cursor and the visible window drift
apart — the cursor can end up drawn off-screen or the list can scroll one row
short of showing it. Compute `viewport_h` once, from `sc.h`/your layout
constants, and use the same value in both places.

## 2. Multiple views/screens in one app

`examples/tracker` is three screens — the split list, a single issue
full-screen, and the compose form — behind one `View` enum and a field on the
model:

<!-- check:decls Model abridged with "// ..." to just the view field; full struct in examples/tracker/main.odin -->
```odin
// examples/tracker/main.odin
View :: enum {
	List,    // the split list + preview
	Detail,  // one issue, full screen
	Compose, // the new-issue form
}

Model :: struct {
	view: View,
	// ...
}
```

`update` dispatches key handling per view, and `view` dispatches drawing per
view — the same enum value picked twice, once for behavior and once for
paint:

<!-- check:verbatim examples/tracker/main.odin -->
```odin
// update, examples/tracker/main.odin
switch m.view {
case .List:
	key_list(p, m, e)
case .Detail:
	key_detail(p, m, e)
case .Compose:
	key_compose(p, m, e)
}
```

<!-- check:verbatim examples/tracker/main.odin -->
```odin
// view, examples/tracker/main.odin
switch m.view {
case .List:
	draw_list(m, s)
case .Detail:
	draw_detail(m, s)
case .Compose:
	draw_compose(m, s)
}
```

Global keys — quit, resize, tick — are handled once, above this switch, in
`update`'s outer `switch e in msg`; only the per-view keys live inside
`key_list`/`key_detail`/`key_compose`. Putting a global check (like Ctrl+C) *inside* one
view's branch means it silently stops working the moment you add a fourth
view and forget to copy it.

## 3. A text input field

The key decoder never hands you a whole line — it hands you one `tui.Key` per
keystroke, with `kind == .Rune` carrying one decoded rune in `.r`. Building a
text field means accumulating those into a buffer yourself and handling
`.Backspace` by stepping back one *rune*, not one byte:

<!-- check:decls -->
```odin
import "core:unicode/utf8"

Field :: struct {
	buf: [256]u8,
	len: int,
}

field_key :: proc(f: ^Field, k: tui.Key) -> bool {
	#partial switch k.kind {
	case .Rune:
		b, n := utf8.encode_rune(k.r)
		if f.len + n <= len(f.buf) {
			copy(f.buf[f.len:], b[:n])
			f.len += n
		}
		return true
	case .Backspace:
		if f.len > 0 {
			_, size := utf8.decode_last_rune(f.buf[:f.len])
			f.len -= size
		}
		return true
	}
	return false
}

field_text :: proc(f: ^Field) -> string {return string(f.buf[:f.len])}

field_view :: proc(sc: ^tui.Screen, f: ^Field, x, y, w: int) {
	text := field_text(f)
	tui.draw_text_clipped(sc, x, y, w, text, tui.Style{fg = tui.ansi(15)})
	tui.set_cursor(sc, x + tui.text_width(text), y)
}
```

The cursor is the part that's easy to get wrong: `set_cell`/`draw_text` don't
draw one, so without `tui.set_cursor` your field looks unfocused no matter
what you type. `set_cursor(s, x, y)` sets `Screen.cursor_visible`/`cursor_x`/
`cursor_y`, which `flush` uses to position and show the real terminal cursor
after painting. Two things follow from that: `screen_clear` resets
`cursor_visible` to false every frame, so you must call `set_cursor` again
inside every `view()` call where the field is focused, and the *x* you pass
has to be in columns, not bytes — that's why it's
`x + tui.text_width(text)`, not `x + f.len`. `.Rune` also fires for
Space (`kind == .Space` is separate — see `tui/key.odin`), so if you want the
space bar to insert a literal space into the field, handle `.Space` here too.

## 4. Centering and box layout

`draw_box` takes an absolute `x, y, w, h`; centering is arithmetic you do
yourself against `Screen.w`/`Screen.h`. `examples/whoami/main.odin` and
`examples/members/main.odin` both use the same formula:

<!-- check:verbatim examples/whoami/main.odin -->
```odin
// examples/whoami/main.odin
w := min(sc.w - 4, 64)
x := (sc.w - w) / 2
y := max((sc.h - len(rows) - 4) / 2, 1)

tui.draw_box(sc, x, y, w, len(rows) + 4, tui.Style{fg = tui.ansi(6)}, tui.BORDER_ROUND, " whoami ")
```

Cap the width (`min(sc.w - 4, 64)`) so the box doesn't become absurdly wide on
a huge terminal, and clamp `y` with `max(..., 1)` so it never goes negative on
a terminal shorter than the content — a negative `y` isn't an error
(`draw_box`/`set_cell` bounds-check and silently drop out-of-range cells), it
just means the top of your box quietly doesn't get drawn.

`draw_box` signature, for reference:

<!-- check:skip signature fragment; `Screen`/`Style` are defined in tui/screen.odin, body there too -->
```odin
draw_box :: proc(s: ^Screen, x, y, w, h: int, style: Style, b := BORDER_ROUND, title := "")
```

It no-ops if `w < 2 || h < 2`, and only draws `title` when `w > 4` (drawn with
`draw_text_clipped`, so a title longer than the box gets an ellipsis rather
than overflowing it). Four border presets ship in `tui/screen.odin`:
`BORDER_ROUND`, `BORDER_SHARP`, `BORDER_DOUBLE`, `BORDER_THICK` — all are
plain `Border{tl, tr, bl, br, h, v: rune}` values, so defining your own with a
different glyph set is just another `Border{...}` literal.

To paint a solid panel behind the box (useful with a translucent-looking
background color), fill first, box second:

<!-- check:skip usage sketch, not a file-scope declaration -->
```odin
tui.fill_rect(sc, x, y, w, h, ' ', tui.Style{bg = tui.rgb(30, 28, 34)})
tui.draw_box(sc, x, y, w, h, tui.Style{fg = tui.ansi(6)})
```

## 5. Responsive layout

Two separate problems: reacting to a resize, and degrading when the terminal
is simply too small to show anything useful.

**Resize.** `tui.run` already resizes `Screen` for you before your code sees
the next frame — by the time `view` runs, `sc.w`/`sc.h` are current. That
covers everything you recompute from the screen each frame. What it does not
cover is state you keep *outside* the screen: a scroll offset was computed
against the old height and is still that old number. So an app with a
viewport has real work to do here. `examples/tracker/main.odin` re-clamps:

<!-- check:verbatim examples/tracker/main.odin -->
```odin
case tui.Resize:
	clamp_view(m, e.rows)
```

`examples/guestbook/main.odin` does the same thing — `compute_layout(e.cols,
e.rows)`, then `clamp_scroll` against the new list height. Take the geometry
from `e.cols`/`e.rows`; that is what the message is carrying.

Layout numbers that depend on `sc.w`/`sc.h` are the part that genuinely needs
no handler — the list/preview split in `draw_list`, say:

<!-- check:verbatim examples/tracker/main.odin -->
```odin
split := min(max(s.w * 3 / 5, 34), s.w - 22)
```

That is recomputed every `view()` call anyway, since `view` runs once per tick
regardless of whether anything resized.

**Too small.** Below some minimum, don't try to lay out the real UI at all —
show one clipped line and return. `examples/tracker/main.odin`'s guard — two
file-scope constants, and the first thing `view` does:

<!-- check:skip elides the enclosing `view` proc signature with "// ... in view:"; see examples/tracker/main.odin -->
```odin
MIN_W :: 56
MIN_H :: 16

// ... in view:
if s.w < MIN_W || s.h < MIN_H {
	msg := fmt.tprintf("terminal too small — need %dx%d, have %dx%d", MIN_W, MIN_H, s.w, s.h)
	tui.draw_text_clipped(
		s,
		max((s.w - tui.text_width(msg)) / 2, 0),
		s.h / 2,
		s.w,
		msg,
		tui.Style{fg = C_ACCENT},
	)
	return
}
```

The minimum is two named constants, and the message formats the same two —
so the number the user is told to hit is by construction the number the guard
tests.

Even that fallback line uses `draw_text_clipped`, not `draw_text` — on a
terminal narrow enough to trigger this guard, the message itself might not
fit either, and `draw_text_clipped` degrades to an ellipsis instead of
whatever `draw_text` would do (silently stop at the screen edge, cutting the
word rather than the whole sentence).

## 6. Frame-rate-independent animation

`tui.Tick` carries `dt: f64` — real seconds elapsed since the previous tick —
alongside `frame: u64`, a plain counter. Drive animation off `dt`, accumulated
into your own state, never off `frame`:

<!-- check:verbatim examples/tracker/main.odin -->
```odin
// examples/tracker/main.odin
case tui.Tick:
	m.spinner += e.dt
```

<!-- check:verbatim examples/tracker/main.odin -->
```odin
// draw_header, examples/tracker/main.odin — m.spinner turned into motion
dots := [4]string{"·  ", "·· ", "···", " ··"}
tui.draw_text(s, 9, 0, dots[int(m.spinner * 2) % 4], tui.Style{fg = C_DIM})
```

The reason `frame` can't stand in for elapsed time: `frame` only means a
fixed slice of wall-clock time if the loop hits its target FPS exactly every
single tick, and nothing guarantees that. `Program.fps` (default 30, set via
`sshtui.Config.fps`) sets a *budget* per frame — `tui.run` sleeps off any
slack under budget, but it never speeds up to make up lost time, and a slow
`view()`, a laggy connection, or a different `fps` value entirely will all
change how much real time one increment of `frame` represents. `dt` is
measured directly (`time.tick_diff` between two `time.tick_now()` calls in
`tui.run`), so `m.spinner += e.dt` keeps the animation's *speed* constant no
matter what the actual frame timing did. `m.spinner += 1` per tick would
drift with every hiccup.

**One boundary: `dt` belongs to per-connection state only.** Every session
runs its own update loop, so every session has its own stream of ticks. The
tracker's issues are *shared* — one board, seen by every connection — and
each issue carries a `touched` marker so a session notices somebody else's
edit landing in real time. Summing each session's `dt` into that shared field
would advance it once per session per frame — N sessions age the marker N×
too fast. (An earlier version of the tracker did exactly this.) Shared state
wants a wall-clock reading instead: stamp the change with `time.tick_now()`,
compare with `time.tick_since` when drawing:

<!-- check:skip stitched from three separate spots in examples/tracker/main.odin (edit_issue, just_changed, draw_list); not contiguous -->
```odin
// examples/tracker/main.odin — edit_issue stamps, draw_list compares
issue.touched = time.tick_now()

just_changed :: proc(issue: Issue) -> bool {
	if issue.touched == (time.Tick{}) {
		return false // seeded issues: the zero Tick never reads as recent
	}
	return time.duration_seconds(time.tick_since(issue.touched)) < 2.0
}

// draw_list — anything changed in the last two seconds gets a marker
if just_changed(issue) {
	tui.set_cell(s, split - 10, y, '●', tui.Style{fg = C_ACCENT, bg = st.bg})
}
```

## 7. A transient status message ("toast") that expires

A toast needs a message, a countdown, and — the part that's easy to miss — a
draw path that doesn't overprint whatever it's replacing.

<!-- check:decls -->
```odin
Toast :: struct {
	buf: [96]u8,
	len: int,
	ttl: f64,
}

toast_set :: proc(t: ^Toast, msg: string) {
	c := min(len(msg), len(t.buf))
	copy(t.buf[:c], msg[:c])
	t.len = c
	t.ttl = 2.0
}

toast_tick :: proc(t: ^Toast, dt: f64) {
	if t.ttl > 0 {
		t.ttl -= dt
		if t.ttl <= 0 {t.len = 0}
	}
}
```

This is `examples/tracker/main.odin`'s `toast`/`update`'s `tui.Tick` case,
condensed. The trap the tracker example was written to avoid: `view` paints a
*full* frame every tick, cell by cell, over whatever was in `Screen.cur`
before — there is no "erase" step separate from drawing. If you draw the
toast text on top of the help line without also blanking the help line first,
and the toast string is shorter than the help string it's covering, the tail
of the help text past the toast's length never gets overwritten and stays on
screen, stitched onto the end of your toast.

The fix is not to overprint at all — pick *one* string for that line and draw
only it, which is what `examples/tracker/main.odin`'s `draw_footer` actually
does:

<!-- check:skip reformatted (single-line Style literal) from examples/tracker/main.odin's draw_footer; not literally contiguous -->
```odin
// draw_footer, examples/tracker/main.odin
left := ""
style := tui.Style{fg = C_DIM}
if m.toast_n > 0 {
	left = string(m.toast[:m.toast_n])
	style.fg = C_ACCENT
} else {
	switch m.view {
	case .List:
		left = "↑↓/jk move · enter open · c close · n new · f filter · q quit"
	case .Detail:
		left = "c close/reopen · esc back"
	case .Compose:
		left = "type a title · enter file · esc cancel"
	}
}
tui.draw_text_clipped(s, 2, y, s.w - 20, left, style)
```

One `draw_text_clipped` call, one string, chosen by an `if`/`else` before
drawing — never two calls to the same row.

## 8. Per-user persistent state keyed by identity

`sshtui.Create_Proc` runs once per connection, **on that connection's own
thread** (`ssh/server.odin` spawns one `thread.create_and_start_with_poly_data`
per accepted session). Any state that outlives a single connection — a
roster, a leaderboard, a counter — has to live outside the per-connection
`Model` in a package-level variable, and every connection's thread can reach
it at the same time. That means a `sync.Mutex`, exactly as
`examples/members/main.odin` does it:

<!-- check:skip recognise abridged with "// ... enrol a new member"; see examples/members/main.odin for the complete proc -->
```odin
// examples/members/main.odin
roster: map[string]Member
roster_mu: sync.Mutex

Member :: struct {
	id:     string,
	number: int,
	visits: int,
}

recognise :: proc(id: string) -> (Member, bool) {
	if id == "" {
		return {}, false
	}
	sync.lock(&roster_mu)
	defer sync.unlock(&roster_mu)

	if m, found := roster[id]; found {
		m.visits += 1
		roster[id] = m
		return m, true
	}
	// ... enrol a new member, also under the same lock
}
```

Key it on `sshtui.Info.id`, not `Info.user` (freely chosen by the client, not
identity) and not `Info.fingerprint` (a real key fingerprint — correlatable
across every other service that saw the same key; see
[`security.md`](./security.md)). `Info.id` only exists when
`sshtui.Config.identity_secret` is set.

The gotcha the mutex alone doesn't cover: `Info.id` is a `string` backed by
the `Session`'s own fixed buffer (`Session.id_buf` in `ssh/server.odin`),
which gets zeroed and freed when that connection's thread tears down. If you
store the string you were handed directly as a map key, the moment that
connection ends the map key's backing bytes are gone. `id_buf` is zeroed on
teardown, so the failure reads as a blank id rather than plausible garbage —
but it is still wrong.

Clone before you store. For a single field, `strings.clone` is enough, which is
what `examples/members/main.odin` does:

<!-- check:skip fields elided with "..."; see examples/members/main.odin's recognise for the complete literal -->
```odin
m := Member{id = strings.clone(id), ...}
roster[m.id] = m
```

To keep a whole `Info` past the connection, use `sshtui.clone_info` and free it
later with `sshtui.delete_info`:

<!-- check:skip usage sketch with a "// ..." elision, referencing an `info` from surrounding context -->
```odin
saved := sshtui.clone_info(info)
// ...
sshtui.delete_info(saved)
```

One subtlety worth knowing: assigning to a key that is *already* in an Odin map
updates the value and leaves the stored key alone, so the returning-visitor
path (`roster[id] = m`) is safe even with a borrowed `id`. It is the insert
that has to own its key.

## 9. Colors and styling

Three ways to make a `tui.Color`, all in `tui/screen.odin`:

<!-- check:skip signature fragment; `Color` is defined in tui/screen.odin, bodies there too -->
```odin
no_color :: proc "contextless" () -> Color            // Color{mode = .Default}
ansi     :: proc "contextless" (idx: u8) -> Color      // 256-color palette index
rgb      :: proc "contextless" (r, g, b: u8) -> Color  // 24-bit true color
```

`Style` is `{fg, bg: Color, attrs: Attrs}`, and `Attrs` is a `bit_set` over:

<!-- check:decls condensed onto fewer lines than tui/screen.odin -->
```odin
Attr :: enum u8 {
	Bold, Dim, Italic, Underline, Reverse, Strike,
}
```

Set several at once with a set literal: `attrs = {.Bold, .Underline}`. Three
small combinators build a new `Style` from an old one without repeating the
fields you're keeping: `with_fg(s, c)` and `with_bg(s, c)` copy `s` and
replace one color; `with_attrs(s, a)` copies `s` and unions `a` into the
existing flags (`s.attrs += a`), so it adds attributes rather than replacing
whatever was already set.

The choice that matters most is **background**. `no_color()` — which is also
what a zero-valued `Style{}` already gives you, since `Color_Mode.Default` is
the zero value — emits `\x1b[...;49m`, "reset to the terminal's own default
background," not any particular color. Leave `bg` unset for ordinary text and
the user's own terminal theme (dark, light, whatever they run) shows through
exactly as it does outside your app. Only set an explicit `bg` where you mean
to override it on purpose — a selected row, say, the way
`examples/tracker/main.odin` highlights the cursor:

<!-- check:skip statement fragment with a "// ..." elision, not a file-scope declaration; see examples/tracker/main.odin's draw_list -->
```odin
// draw_list, examples/tracker/main.odin
if selected {
	st.bg = C_SEL_BG
	st.attrs = {.Bold}
	// ...
}
```

`C_SEL_BG` there is `tui.rgb(40, 38, 48)` — a fixed color, chosen on purpose,
that overrides whatever background the user's terminal theme would otherwise
show for that row.

If you want a themable "selected" look instead of a fixed color, `.Reverse`
(swap fg/bg) tracks the user's own palette instead of fighting it —
`examples/members/main.odin`'s `deny` screen and this cookbook's list recipe
(§1) both use it for that reason.

## 10. Wide characters and emoji

Never assume one rune is one column. `tui.rune_width(r)` returns 0 for
combining marks and zero-width joiners, 1 for ordinary ASCII/Latin, and 2 for
CJK, Hangul, and most emoji (see the range table in `tui/width_table.odin`).
`draw_text` and `set_cell` already use it — `set_cell` writes a
`WIDE_CONT` marker into the cell to the right of any 2-wide glyph so the
diff renderer never lands a write in the middle of one:

<!-- check:skip reformatted (one-line if) from tui/screen.odin's draw_text; not literally contiguous -->
```odin
// draw_text, tui/screen.odin
for r in text {
	if col >= s.w {break}
	set_cell(s, col, y, r, style)
	col += rune_width(r)
}
```

For measuring a whole string before you've drawn it — centering, right
alignment, deciding whether text fits a box — use `tui.text_width(text)`, the
sum of `rune_width` over every rune, never `len(text)`. `len` counts *bytes*;
a wide CJK character or most emoji are multiple UTF-8 bytes but only 2
*columns*, so `len` overshoots badly and any layout math built on it
misaligns. `examples/tracker/main.odin`'s header right-aligns a status string
this way:

<!-- check:verbatim examples/tracker/main.odin -->
```odin
// draw_header, examples/tracker/main.odin
right := fmt.tprintf("%d open · %d connected", open_count(), conns)
x := s.w - tui.text_width(right) - 2
```

Swap that for `len(right)` and this one drifts immediately: the `·` separator
is one column but two UTF-8 bytes, so the whole string starts one column
left of where it should, on every frame. Put anything genuinely wide in such
a string — a CJK label, a user-supplied name — and the error grows by however
many extra bytes those runes cost, in a way that only shows up for the users
who have them, which is exactly the kind of bug that survives testing in
ASCII.

## 11. Mouse support

Off by default. Ask for it via `sshtui.Config.mouse` (or `tui.Program.mouse`
if you're driving the loop yourself); `sshtui` forwards it into the `Program`
in both `on_session` and `run_local`. When set, `tui.run` sends the mouse
tracking escape sequences on entry and turns them back off on exit:

<!-- check:verbatim tui/tui.odin -->
```odin
// tui/tui.odin
if p.mouse {
	emit(p, "\x1b[?1000h\x1b[?1002h\x1b[?1006h")
}
```

Events arrive as `tui.Mouse`, one of the cases in `tui.Msg`:

<!-- check:decls condensed onto fewer lines than tui/key.odin -->
```odin
// tui/key.odin
Mouse_Kind :: enum u8 {
	Press, Release, Motion, Wheel_Up, Wheel_Down,
}

Mouse :: struct {
	kind:   Mouse_Kind,
	button: int,
	x, y:   int, // zero-based cell coordinates
	ctrl:   bool,
	alt:    bool,
	shift:  bool,
}
```

`x`/`y` are already the cell coordinates your `view` drew into, so hit-testing
a click against a list is the same arithmetic as laying it out —
`examples/tracker/main.odin` uses wheel events to move the menu cursor without
even needing coordinates:

<!-- check:verbatim examples/tracker/main.odin -->
```odin
// update, examples/tracker/main.odin
case tui.Mouse:
	if m.view != .List {break}
	#partial switch e.kind {
	case .Wheel_Up:
		m.cursor = max(m.cursor - 1, 0)
		clamp_view(m, p.screen.h)
	case .Wheel_Down:
		m.cursor += 1
		clamp_view(m, p.screen.h)
	}
```

To hit-test a `Press` against the scrollable list from §1, compare `m.y`
against the same `y`/`h` you rendered with:

<!-- check:skip illustrative combination of a Mouse case with the List type from recipe 1; not lifted from a single file -->
```odin
case tui.Mouse:
	if m.kind == .Press && m.y >= list_y && m.y < list_y + viewport_h {
		l.cursor = l.offset + (m.y - list_y)
	}
```

The gotcha: `.Motion` only fires while a button is held. The three modes
`tui.run` enables are 1000 (click reporting), 1002 (motion *while a button is
down*), and 1006 (SGR extended coordinates for terminals wider/taller than
223 cells) — not 1003 (report every hover, button or not). If your app needs
hover tracking with no button pressed, this backend doesn't send it; treat
`.Motion` as "dragging," not "hovering."

## 12. Graceful exit

`tui.quit(p)` just sets `Program.quit = true`:

<!-- check:verbatim tui/tui.odin -->
```odin
quit :: proc(p: ^Program) {
	p.quit = true
}
```

It doesn't stop the program mid-statement. The run loop finishes dispatching
whatever input batch it was on, still sends one more `tui.Tick` to `update`
(look at `tui/tui.odin`'s loop: the `Tick` send happens unconditionally,
*then* `if p.quit {break}` runs, before the screen is cleared or `view` is
called again) — so a `Tick` handler can still fire once after you've called
`quit`, but no further frame gets drawn.

**Ctrl+C is not a signal here.** The client asked for a pty
(`pty-req`), so *its own* terminal — not this server — goes into raw mode,
which turns off `ISIG` along with canonical input (see
`tui/local.odin`'s `local_enter_raw` for the same flags set on the local
backend: `raw.c_lflag -= {.ECHO, .ICANON, .IEXTEN, .ISIG}`). With `ISIG` off,
Ctrl+C is never intercepted and turned into `SIGINT` — it travels down the
channel as the raw byte `0x03`, and `tui/key.odin`'s parser turns any C0
control byte into `Key{kind = .Rune, r = rune('a' + b - 1), ctrl = true}`, so
byte `0x03` becomes `Key{kind = .Rune, r = 'c', ctrl = true}`. Handle it like
any other key, checked early, the way every bundled example does:

<!-- check:verbatim examples/tracker/main.odin -->
```odin
// update, examples/tracker/main.odin
if e.ctrl && e.r == 'c' {
	tui.quit(p)
	return
}
```

**Cleanup order.** `tui.run`'s own `defer`s always run when the loop exits —
whether that's `quit(p)` or the backend reporting the connection is gone
(`poll` returning `ok = false`) — putting the terminal back the way it found
it: mouse tracking off if it was on, autowrap back on, cursor shown, and the
alternate screen left (`tui/tui.odin`). One layer up, `sshtui.on_session`'s
`defer if cfg.destroy != nil {cfg.destroy(app)}` then runs, so whatever
`create` allocated gets freed exactly once, on every exit path, without your
app code having to distinguish "user quit" from "connection dropped":

<!-- check:verbatim examples/whoami/main.odin -->
```odin
destroy :: proc(app: tui.App) {
	free(app.data)
}
```

If `create` allocated more than the one top-level struct — a `[dynamic]`,
a `map`, a cloned string per §8 — free those inside `destroy` too; `free`
only releases the block `new(Model)` returned, not whatever it points into.

## 13. A modal confirm dialog

A modal needs three things: something that visually separates it from
whatever is behind it, a box on top, and a key handler that swallows input
while it is open — press any key during a confirmation and it must never
reach whatever `update` was doing before the modal opened, or the
confirmation is bypassed by accident.

There is no real transparency here. A terminal cell has no alpha channel, so
"dimming" the backdrop means painting the whole screen with a plain, darker
`Style{bg = ...}` before drawing the box on top — the same `fill_rect`-then-
`draw_box` order recipe 4 uses for a solid panel, just covering the full
screen instead of one box's footprint:

<!-- check:decls -->
```odin
Confirm :: struct {
	active:  bool,
	message: string,
}

confirm_open :: proc(c: ^Confirm, message: string) {
	c.active = true
	c.message = message
}

// Reports whether the dialog consumed the key (so the caller's own key
// handling should be skipped this tick) and, if it just closed, what the
// user chose.
confirm_key :: proc(c: ^Confirm, k: tui.Key) -> (consumed, closed, yes: bool) {
	if !c.active {
		return false, false, false
	}
	#partial switch k.kind {
	case .Rune:
		switch k.r {
		case 'y', 'Y':
			c.active = false
			return true, true, true
		case 'n', 'N':
			c.active = false
			return true, true, false
		}
	case .Esc:
		c.active = false
		return true, true, false
	}
	return true, false, false // swallow everything else while open
}

confirm_view :: proc(sc: ^tui.Screen, c: ^Confirm) {
	if !c.active {return}

	// No alpha channel in a terminal: "dimming" is a plain darker fill, not a
	// blend with whatever fill_rect is painting over.
	tui.fill_rect(sc, 0, 0, sc.w, sc.h, ' ', tui.Style{bg = tui.rgb(10, 10, 14)})

	w := min(tui.text_width(c.message) + 8, max(sc.w - 4, 10))
	h := 4
	x := max((sc.w - w) / 2, 0)
	y := max((sc.h - h) / 2, 0)
	tui.draw_box(sc, x, y, w, h, tui.Style{fg = tui.ansi(3)}, tui.BORDER_ROUND, " confirm ")
	tui.draw_text_clipped(sc, x + 2, y + 1, w - 4, c.message, tui.Style{fg = tui.ansi(15)})
	tui.draw_text(sc, x + 2, y + 2, "y yes · n no · esc cancel", tui.Style{fg = tui.ansi(8)})
}
```

Wire the key handler in above your normal dispatch — the same position
§5's Ctrl+C check occupies, and for the same reason: a check that only fires
conditionally has to sit above whatever it is meant to override, or a mode
added later slips in front of it by accident. Draw the dialog last in
`view`, so it paints over the frame instead of getting painted over by it:

<!-- check:skip usage sketch spanning update and view; Confirm/confirm_key/confirm_view are defined above -->
```odin
// In update, above your normal dispatch:
#partial switch e in msg {
case tui.Key:
	if consumed, closed, yes := confirm_key(&m.confirm, e); consumed {
		if closed && yes {
			// ... the confirmed action
		}
		return
	}
	// ... your normal key handling
}

// In view, drawn last:
confirm_view(sc, &m.confirm)
```

`confirm_key` returning `true` on every key while `c.active` — not just `y`/
`n`/`Esc` — is what makes the modal actually modal: an unrecognised keystroke
while it's open still has to be swallowed, or it leaks through to the
handling underneath and moves a cursor the user can no longer see.

## 14. A progress bar / gauge

A gauge is `fill_rect` called twice — once for the track, once for however
much of it is filled — plus a percentage label that has to sit on whichever
half it lands on, not on whatever background `draw_text` defaults to.

That last part is the trap. `draw_text`/`set_cell` replace a cell's rune
*and* style together; nothing about them blends with what was there before.
A label drawn with an unset background paints the terminal's own default
background under its own characters, not the gauge color beneath them — the
same "a cell is fully replaced, not merged" fact recipe 13's backdrop relies
on, just biting the other way here. The fix is to give each label rune the
background of whichever side of the fill boundary its column falls on,
walking columns the same `col += rune_width(r)` way `draw_text` itself does
(recipe 10):

<!-- check:decls -->
```odin
import "core:fmt"

// frac is a plain 0..1 fraction the caller owns; tui has no notion of
// progress of its own.
gauge_draw :: proc(sc: ^tui.Screen, x, y, w: int, frac: f64, track, fill: tui.Style) {
	f := clamp(frac, 0, 1)
	filled := int(f64(w) * f + 0.5)

	tui.fill_rect(sc, x, y, w, 1, ' ', track)
	if filled > 0 {
		tui.fill_rect(sc, x, y, filled, 1, ' ', fill)
	}

	label := fmt.tprintf("%d%%", int(f * 100 + 0.5))
	lx := x + (w - tui.text_width(label)) / 2
	cx := lx
	for r in label {
		bg := cx < x + filled ? fill.bg : track.bg
		tui.set_cell(sc, cx, y, r, tui.Style{fg = tui.ansi(15), bg = bg, attrs = {.Bold}})
		cx += tui.rune_width(r)
	}
}
```

Call it once per frame with whatever fraction your model is tracking — a
download, a long-running import, time left on a countdown:

<!-- check:skip usage sketch; sc/m are the caller's Screen/Model -->
```odin
gauge_draw(sc, 2, 5, 40, m.progress, tui.Style{bg = tui.rgb(40, 38, 48)}, tui.Style{bg = tui.rgb(80, 160, 90)})
```

Nothing here animates the fill on its own — `gauge_draw` reads `m.progress`
fresh every frame, so driving the number up over time is ordinary `dt`-based
state in `update`, the same shape recipe 6 uses for anything else that has to
move at a rate independent of frame timing.

## 15. A tab bar with Tab/Shift_Tab focus cycling

`Key_Kind` carries dedicated `.Tab` and `.Shift_Tab` values, so cycling
forward and backward through a set of tabs needs no invented key combination
for "previous" — `.Shift_Tab` decodes from the standard CSI `Z` ("back-tab")
escape sequence (`tui/key.odin`), the same way `.Tab` decodes from a bare
`0x09` byte.

<!-- check:decls -->
```odin
Tabs :: struct {
	labels: []string,
	active: int,
}

tabs_key :: proc(t: ^Tabs, k: tui.Key) -> bool {
	n := len(t.labels)
	if n == 0 {return false}
	#partial switch k.kind {
	case .Tab:
		t.active = (t.active + 1) % n
		return true
	case .Shift_Tab:
		t.active = (t.active - 1 + n) % n
		return true
	}
	return false
}

tabs_view :: proc(sc: ^tui.Screen, t: ^Tabs, x, y: int) {
	cx := x
	for label, i in t.labels {
		st := tui.Style{fg = tui.ansi(8)}
		if i == t.active {
			st = tui.Style{fg = tui.ansi(15), attrs = {.Bold, .Underline}}
		}
		cx += tui.draw_text(sc, cx, y, label, st)
		cx += tui.draw_text(sc, cx, y, "  ", tui.Style{})
	}
}
```

`(t.active - 1 + n) % n` rather than `(t.active - 1) % n` is the part worth
noticing: `t.active` is always in `[0, n)` going in, so adding `n` before the
modulo keeps the intermediate value non-negative no matter what Odin's `%`
does with a negative left-hand side, instead of relying on it.

`tabs_key` returning `false` for anything that isn't `.Tab`/`.Shift_Tab` lets
it slot into the same "try the widget first, fall through to normal
handling" shape recipe 3's `field_key` uses — call it the same way, before
whatever `.Tab` would otherwise do, which by default is nothing: `tui` gives
the key no meaning of its own. If a tab's own content includes a text field
from recipe 3, decide which of the two gets first look at `.Tab` yourself;
nothing here arbitrates that for you.

## 16. A debug HUD from Program's own counters

`Program` already counts the things worth watching while an app misbehaves —
`frame`, `elapsed`, `bytes_out`, `bytes_in` — without any help from your
`Model`. A HUD is just those four numbers, drawn in a corner every frame,
read from the same `^Program` your `view` proc is already handed:

<!-- check:decls -->
```odin
import "core:fmt"

hud_draw :: proc(sc: ^tui.Screen, p: ^tui.Program) {
	// frame / elapsed is the average rate since the loop started, not the
	// instantaneous one — good enough for a debug corner, misleading if
	// you're hunting a momentary stall.
	fps := p.elapsed > 0 ? f64(p.frame) / p.elapsed : 0
	line := fmt.tprintf(
		"frame %d  %.1ffps  out %db  in %db",
		p.frame, fps, p.bytes_out, p.bytes_in,
	)
	x := sc.w - tui.text_width(line) - 1
	if x < 0 {return}
	tui.draw_text(sc, x, 0, line, tui.Style{fg = tui.ansi(8)})
}
```

Call it last in `view`, after everything else — like recipe 7's toast, a
later draw simply overwrites an earlier one cell by cell, so a HUD drawn
first would vanish under your own UI instead of sitting on top of it:

<!-- check:skip usage sketch; sc/p are the caller's Screen/Program -->
```odin
hud_draw(sc, p)
```

`bytes_out`'s own doc comment in `tui/tui.odin` says what it's for outright:
"handy for showing off how little the diff renderer sends." Watch it while
resizing a terminal (forces a full repaint, so `bytes_out` jumps) versus
while idling (it should barely move) to see the diffing recipe 10 and the
rest of this package lean on actually paying off.
