# otsh:tui — API reference

Screen, styles, drawing, the frame loop, and input decoding. No dependency on `ssh` — usable for a purely local TUI.

Generated from `tui/*.odin` by `docs/tools/gen_api.py`. For how these fit together, see the hand-written guide ([tui](tui.md)).

## Contents

**Types** — [`App`](#app), [`Attr`](#attr), [`Attrs`](#attrs), [`Backend`](#backend), [`Border`](#border), [`Cell`](#cell), [`Color`](#color), [`Color_Mode`](#color-mode), [`Input`](#input), [`Key`](#key), [`Key_Kind`](#key-kind), [`Local`](#local), [`Mouse`](#mouse), [`Mouse_Kind`](#mouse-kind), [`Msg`](#msg), [`Program`](#program), [`Resize`](#resize), [`Screen`](#screen), [`Style`](#style), [`Tick`](#tick)

**Constants** — [`BORDER_DOUBLE`](#border-double), [`BORDER_ROUND`](#border-round), [`BORDER_SHARP`](#border-sharp), [`BORDER_THICK`](#border-thick), [`MAX_COLS`](#max-cols), [`MAX_ROWS`](#max-rows), [`WIDE_CONT`](#wide-cont)

**Procedures** — [`ansi`](#ansi), [`draw_box`](#draw-box), [`draw_text`](#draw-text), [`draw_text_clipped`](#draw-text-clipped), [`fill_rect`](#fill-rect), [`flush`](#flush), [`key_name`](#key-name), [`local_backend`](#local-backend), [`local_enter_raw`](#local-enter-raw), [`local_exit_raw`](#local-exit-raw), [`no_color`](#no-color), [`parse_input`](#parse-input), [`quit`](#quit), [`rgb`](#rgb), [`run`](#run), [`rune_width`](#rune-width), [`screen_clear`](#screen-clear), [`screen_destroy`](#screen-destroy), [`screen_init`](#screen-init), [`screen_resize`](#screen-resize), [`set_cell`](#set-cell), [`set_cursor`](#set-cursor), [`text_width`](#text-width), [`with_attrs`](#with-attrs), [`with_bg`](#with-bg), [`with_fg`](#with-fg)

## Types

### `App`

```odin
App :: struct {
	data:   rawptr,
	init:   proc(p: ^Program),
	update: proc(p: ^Program, msg: Msg),
	view:   proc(p: ^Program, s: ^Screen),
}
```

Your application: a model pointer plus up to three callbacks. `init` is
optional; `update` handles messages, `view` paints a complete frame.

*tui/tui.odin:44*

### `Attr`

```odin
Attr :: enum u8 {
	Bold,
	Dim,
	Italic,
	Underline,
	Reverse,
	Strike,
}
```

Text attributes. Terminal support varies: Bold and Reverse are universal,
Italic and Strike are not.

*tui/screen.odin:46*

### `Attrs`

```odin
Attrs :: distinct bit_set[Attr;u8]
```

A set of `Attr`, e.g. `{.Bold, .Underline}`.

*tui/screen.odin:55*

### `Backend`

```odin
Backend :: struct {
	data:  rawptr,
	// Writes rendered output. Returns bytes written.
	write: proc(data: rawptr, buf: []u8) -> int,
	// Blocks up to timeout_ms. n == 0 means "nothing typed"; ok == false means
	// the connection is gone.
	poll:  proc(data: rawptr, buf: []u8, timeout_ms: int) -> (n: int, ok: bool),
	// Current terminal geometry in cells.
	size:  proc(data: rawptr) -> (cols, rows: int),
}
```

A source of terminal bytes and a sink for them.

*tui/tui.odin:9*

### `Border`

```odin
Border :: struct {
	tl, tr, bl, br, h, v: rune,
}
```

The six runes `draw_box` uses: four corners, then horizontal and vertical.

*tui/screen.odin:224*

### `Cell`

```odin
Cell :: struct {
	r:     rune,
	style: Style,
}
```

One character cell: a rune plus how to paint it.

*tui/screen.odin:79*

### `Color`

```odin
Color :: struct {
	mode:    Color_Mode,
	idx:     u8,
	r, g, b: u8,
}
```

A foreground or background colour. Build one with `no_color`, `ansi` or `rgb`
rather than filling the fields by hand.

*tui/screen.odin:26*

### `Color_Mode`

```odin
Color_Mode :: enum u8 {
	Default,
	Palette,
	True,
}
```

How a Color is encoded on the wire. Default emits SGR 39/49 so the user's own
terminal theme decides; the others pin an exact colour.

*tui/screen.odin:18*

### `Input`

```odin
Input :: union {
	Key,
	Mouse,
}
```

What `parse_input` decodes: either a key or a mouse event.

*tui/key.odin:76*

### `Key`

```odin
Key :: struct {
	kind:  Key_Kind,
	r:     rune, // valid when kind == .Rune
	ctrl:  bool,
	alt:   bool,
	shift: bool,
}
```

A keypress. Note that Ctrl+C arrives here rather than as a signal, because the
client's terminal is in raw mode.

*tui/key.odin:47*

### `Key_Kind`

```odin
Key_Kind :: enum u8 {
	None,
	Rune,
	Enter,
	Tab,
	Shift_Tab,
	Backspace,
	Esc,
	Space,
	Delete,
	Insert,
	Up,
	Down,
	Left,
	Right,
	Home,
	End,
	Page_Up,
	Page_Down,
	F1,
	F2,
	F3,
	F4,
	F5,
	F6,
	F7,
	F8,
	F9,
	F10,
	F11,
	F12,
}
```

Which key was pressed. `.Rune` means an ordinary character, carried in
`Key.r`; everything else is a named key with no rune.

*tui/key.odin:12*

### `Local`

```odin
Local :: struct {
	orig:      posix.termios,
	have_orig: bool,
}
```

Saved terminal state for a local session, so raw mode can be undone. Zero
value is fine; pass the same one to enter/exit/backend.

*tui/local.odin:32*

### `Mouse`

```odin
Mouse :: struct {
	kind:   Mouse_Kind,
	button: int,
	x, y:   int, // zero-based cell coordinates
	ctrl:   bool,
	alt:    bool,
	shift:  bool,
}
```

A mouse event, in zero-based cell coordinates. Only delivered when
`Program.mouse` was set before `run`.

*tui/key.odin:66*

### `Mouse_Kind`

```odin
Mouse_Kind :: enum u8 {
	Press,
	Release,
	Motion,
	Wheel_Up,
	Wheel_Down,
}
```

What the mouse did. Wheel events carry no button.

*tui/key.odin:56*

### `Msg`

```odin
Msg :: union {
	Key,
	Mouse,
	Resize,
	Tick,
}
```

Everything `update` can receive.

*tui/tui.odin:35*

### `Program`

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

One running app: its backend, its screen, and the loop's own bookkeeping.
Set `fps` and `mouse` before `run`; read `frame`, `elapsed`, `bytes_out` and
`bytes_in` any time.

*tui/tui.odin:54*

### `Resize`

```odin
Resize :: struct {
	cols, rows: int,
}
```

Sent when the terminal geometry changes. The screen buffer has already been
resized by the time your `update` sees this.

*tui/tui.odin:22*

### `Screen`

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
```

The cell grid. `cur` is the frame being drawn, `prev` the one last sent to the
terminal; `flush` emits the difference. Apps normally only draw into it and
let `run` handle the rest.

*tui/screen.odin:87*

### `Style`

```odin
Style :: struct {
	fg:    Color,
	bg:    Color,
	attrs: Attrs,
}
```

Everything about a cell except its rune. The zero value is the terminal's own
defaults, which is usually what you want as a base.

*tui/screen.odin:59*

### `Tick`

```odin
Tick :: struct {
	dt:    f64, // seconds since the previous tick
	total: f64,
	frame: u64,
}
```

Sent once per frame. Drive animation off `dt` (real seconds since the previous
tick), never off `frame` — see docs/cookbook.md.

*tui/tui.odin:28*

## Constants

### `BORDER_DOUBLE`

```odin
BORDER_DOUBLE :: Border{'╔', '╗', '╚', '╝', '═', '║'}
```

Double-ruled.

*tui/screen.odin:233*

### `BORDER_ROUND`

```odin
BORDER_ROUND :: Border{'╭', '╮', '╰', '╯', '─', '│'}
```

Rounded corners.

*tui/screen.odin:229*

### `BORDER_SHARP`

```odin
BORDER_SHARP :: Border{'┌', '┐', '└', '┘', '─', '│'}
```

Square corners.

*tui/screen.odin:231*

### `BORDER_THICK`

```odin
BORDER_THICK :: Border{'┏', '┓', '┗', '┛', '━', '┃'}
```

Heavy weight.

*tui/screen.odin:235*

### `MAX_COLS`

```odin
MAX_COLS :: 1000
MAX_ROWS :: 300

// Resizes the grids, forcing a full repaint on the next flush. A no-op if the
// size is unchanged. Dimensions are clamped to MAX_COLS/MAX_ROWS.
screen_resize :: proc(s: ^Screen, w, h: int) {
	w, h := clamp(w, 1, MAX_COLS), clamp(h, 1, MAX_ROWS)
	if s.w == w && s.h == h && s.cur != nil {
		return
	}
	delete(s.cur)
	delete(s.prev)
	s.w, s.h = w, h
	s.cur = make([]Cell, w * h)
	s.prev = make([]Cell, w * h)
	s.full_redraw = true
	screen_clear(s)
}
```

Hard bounds on a screen, in cells.

Terminal geometry arrives from whatever is on the other end. Over SSH that is
an untrusted uint32 the client picks, so this is a security boundary, not a
style choice: at 16 bytes per cell and two grids, an unclamped 2e9 x 2e9
overflows the allocation size, `make` hands back an empty slice, and the first
draw panics and takes the whole process down. Anything merely large — 10000 x
10000 — commits gigabytes instead.

The caps are generous against real hardware — an ultrawide 5120px display at a
6px font is about 850 columns, a 4K display at a 10px line height about 210
rows — while bounding a session at roughly 9.6 MB of cell grid (two grids,
16 bytes a cell). That worst case still multiplies by the session limit, so an
operator expecting many concurrent users should size RAM accordingly.

*tui/screen.odin:125*

### `MAX_ROWS`

```odin
MAX_ROWS :: 300

// Resizes the grids, forcing a full repaint on the next flush. A no-op if the
// size is unchanged. Dimensions are clamped to MAX_COLS/MAX_ROWS.
screen_resize :: proc(s: ^Screen, w, h: int) {
	w, h := clamp(w, 1, MAX_COLS), clamp(h, 1, MAX_ROWS)
	if s.w == w && s.h == h && s.cur != nil {
		return
	}
	delete(s.cur)
	delete(s.prev)
	s.w, s.h = w, h
	s.cur = make([]Cell, w * h)
	s.prev = make([]Cell, w * h)
	s.full_redraw = true
	screen_clear(s)
}
```

*tui/screen.odin:126*

### `WIDE_CONT`

```odin
WIDE_CONT :: rune(-1) // right half of a double-width cell
```

Occupies the right-hand cell of a double-width glyph. Never drawn itself —
`flush` skips it, since the lead glyph already advanced the cursor over it.

*tui/screen.odin:14*

## Procedures

### `ansi`

```odin
ansi :: proc "contextless" (idx: u8) -> Color
```

One of the terminal's 256 palette entries. 0-7 are the base colours, 8-15 the
bright ones; those sixteen follow the user's theme, 16-255 do not.

*tui/screen.odin:37*

### `draw_box`

```odin
draw_box :: proc(s: ^Screen, x, y, w, h: int, style: Style, b := BORDER_ROUND, title := "")
```

Draws a box outline with an optional title inset into the top edge. Nothing is
drawn inside it. Silently does nothing if smaller than 2x2.

*tui/screen.odin:239*

### `draw_text`

```odin
draw_text :: proc(s: ^Screen, x, y: int, text: string, style: Style) -> int
```

Returns the number of columns consumed.

*tui/screen.odin:180*

### `draw_text_clipped`

```odin
draw_text_clipped :: proc(s: ^Screen, x, y, max_w: int, text: string, style: Style) -> int
```

Draws text clipped to `max_w` columns, appending "…" when it does not fit.

*tui/screen.odin:193*

### `fill_rect`

```odin
fill_rect :: proc(s: ^Screen, x, y, w, h: int, r: rune, style: Style)
```

Fills a rectangle with one rune. Clipped to the screen.

*tui/screen.odin:215*

### `flush`

```odin
flush :: proc(s: ^Screen) -> []u8
```

Produces the escape sequence stream that turns the previously rendered frame
into the current one. Returns an empty slice when nothing changed.

*tui/screen.odin:382*

### `key_name`

```odin
key_name :: proc(k: Key, buf: []u8) -> string
```

Human-readable name, handy for help bars and debugging.

*tui/key.odin:357*

### `local_backend`

```odin
local_backend :: proc(l: ^Local) -> Backend
```

A `Backend` over this process's own stdin/stdout.

*tui/local.odin:38*

### `local_enter_raw`

```odin
local_enter_raw :: proc(l: ^Local) -> bool
```

Puts the terminal into raw mode: no line buffering, no echo, no signal
generation from Ctrl+C. Over SSH the *client* does this for us, which is why
the server side never needs termios at all.

*tui/local.odin:69*

### `local_exit_raw`

```odin
local_exit_raw :: proc(l: ^Local)
```

Restores the terminal settings saved by `local_enter_raw`. Safe to call twice;
always `defer` it, or the user's shell is left in raw mode.

*tui/local.odin:88*

### `no_color`

```odin
no_color :: proc "contextless" () -> Color
```

The terminal's own default colour. Prefer this for backgrounds so the user's
theme shows through.

*tui/screen.odin:34*

### `parse_input`

```odin
parse_input :: proc(buf: []u8) -> (ev: Input, n: int, ok: bool)
```

Decodes one event from the front of `buf`.

ok == false  -> incomplete sequence, wait for more bytes
n            -> bytes consumed

*tui/key.odin:85*

### `quit`

```odin
quit :: proc(p: ^Program)
```

Ends the loop after the current tick, before the next frame is drawn.

*tui/tui.odin:71*

### `rgb`

```odin
rgb :: proc "contextless" (r, g, b: u8) -> Color
```

A 24-bit colour, emitted as an SGR truecolor sequence. Not a compile-time
constant — use a `:=` package variable, not `::`, for a palette.

*tui/screen.odin:40*

### `run`

```odin
run :: proc(p: ^Program, app: App)
```

Runs `app` until it quits or the connection drops. Sets up the alternate
screen, hides the cursor, disables autowrap, and restores all of it on exit.
Blocks for the lifetime of the app.

*tui/tui.odin:85*

### `rune_width`

```odin
rune_width :: proc "contextless" (r: rune) -> int
```

Display width in terminal columns. Covers the ranges that matter in
practice: combining marks (0), CJK and emoji (2), everything else (1).

*tui/screen.odin:272*

### `screen_clear`

```odin
screen_clear :: proc(s: ^Screen, style := Style{})
```

Resets the working buffer. Called by the runtime before each view().

*tui/screen.odin:145*

### `screen_destroy`

```odin
screen_destroy :: proc(s: ^Screen)
```

Frees what `screen_init` allocated.

*tui/screen.odin:105*

### `screen_init`

```odin
screen_init :: proc(s: ^Screen, w, h: int)
```

Allocates the grids and output buffer. `run` calls this for you.

*tui/screen.odin:99*

### `screen_resize`

```odin
screen_resize :: proc(s: ^Screen, w, h: int)
```

Resizes the grids, forcing a full repaint on the next flush. A no-op if the
size is unchanged. Dimensions are clamped to MAX_COLS/MAX_ROWS.

*tui/screen.odin:130*

### `set_cell`

```odin
set_cell :: proc(s: ^Screen, x, y: int, r: rune, style: Style)
```

Paints one cell, clipped to the screen. A double-width rune also claims the
cell to its right; a zero-width one is ignored.

*tui/screen.odin:159*

### `set_cursor`

```odin
set_cursor :: proc(s: ^Screen, x, y: int)
```

Shows the terminal cursor at this cell for the current frame. Call it every
frame you want the cursor visible — `screen_clear` hides it again. Use it for
text input, so the caret lands where the user is typing.

*tui/screen.odin:263*

### `text_width`

```odin
text_width :: proc "contextless" (text: string) -> int
```

Total display width of a string in terminal columns. Use this, never `len`,
for centering or alignment.

*tui/screen.odin:312*

### `with_attrs`

```odin
with_attrs :: proc "contextless" (s: Style, a: Attrs) -> Style
```

Returns a copy of `s` with `a` added to its attributes.

*tui/screen.odin:74*

### `with_bg`

```odin
with_bg :: proc "contextless" (s: Style, c: Color) -> Style
```

Returns a copy of `s` with the background replaced.

*tui/screen.odin:70*

### `with_fg`

```odin
with_fg :: proc "contextless" (s: Style, c: Color) -> Style
```

Returns a copy of `s` with the foreground replaced.

*tui/screen.odin:66*
