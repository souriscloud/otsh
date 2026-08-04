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

Example:

```odin
app := tui.App{data = m, update = update, view = view}
```

*[tui/tui.odin:64](../tui/tui.odin#L64)*

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

*[tui/screen.odin:58](../tui/screen.odin#L58)*

### `Attrs`

```odin
Attrs :: distinct bit_set[Attr;u8]
```

A set of `Attr`, e.g. `{.Bold, .Underline}`.

*[tui/screen.odin:67](../tui/screen.odin#L67)*

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

Wiring in a transport that is not ssh (which already provides one):

Example:

```odin
p.backend = tui.Backend{data = conn, write = my_write, poll = my_poll, size = my_size}
```

*[tui/tui.odin:15](../tui/tui.odin#L15)*

### `Border`

```odin
Border :: struct {
	tl, tr, bl, br, h, v: rune,
}
```

The six runes `draw_box` uses: four corners, then horizontal and vertical.

*[tui/screen.odin:337](../tui/screen.odin#L337)*

### `Cell`

```odin
Cell :: struct {
	r:     rune,
	style: Style,
}
```

One character cell: a rune plus how to paint it.

*[tui/screen.odin:122](../tui/screen.odin#L122)*

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

*[tui/screen.odin:26](../tui/screen.odin#L26)*

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

*[tui/screen.odin:18](../tui/screen.odin#L18)*

### `Input`

```odin
Input :: union {
	Key,
	Mouse,
}
```

What `parse_input` decodes: either a key or a mouse event.

*[tui/key.odin:82](../tui/key.odin#L82)*

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

Example:

```odin
if k, ok := msg.(tui.Key); ok && k.kind == .Enter {
	// submit
}
```

*[tui/key.odin:53](../tui/key.odin#L53)*

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

*[tui/key.odin:12](../tui/key.odin#L12)*

### `Local`

```odin
Local :: struct {
	orig:      posix.termios,
	have_orig: bool,
}
```

Saved terminal state for a local session, so raw mode can be undone. Zero
value is fine; pass the same one to enter/exit/backend.

*[tui/local.odin:46](../tui/local.odin#L46)*

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

*[tui/key.odin:72](../tui/key.odin#L72)*

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

*[tui/key.odin:62](../tui/key.odin#L62)*

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

Example:

```odin
m := (^Model)(p.app.data)
#partial switch e in msg {
case tui.Key:
	if e.kind == .Rune && e.r == 'q' {tui.quit(p)}
case tui.Resize:
	m.cols, m.rows = e.cols, e.rows
}
```

*[tui/tui.odin:51](../tui/tui.odin#L51)*

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

*[tui/tui.odin:74](../tui/tui.odin#L74)*

### `Resize`

```odin
Resize :: struct {
	cols, rows: int,
}
```

Sent when the terminal geometry changes. The screen buffer has already been
resized by the time your `update` sees this.

*[tui/tui.odin:28](../tui/tui.odin#L28)*

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

*[tui/screen.odin:130](../tui/screen.odin#L130)*

### `Style`

```odin
Style :: struct #align (4) {
	fg:    Color,
	bg:    Color,
	attrs: Attrs,
}
```

Everything about a cell except its rune. The zero value is the terminal's own
defaults, which is usually what you want as a base.

The alignment is not cosmetic and must not be dropped. These three fields come
to 11 bytes, and Odin emits a 12-byte store when an 11-byte struct is passed
by value — so every call taking a `Style` parameter writes one byte past its
own incoming stack slot. Harmless in a normal build (the byte lands in that
frame's padding) but AddressSanitizer reports it as a stack-buffer-overflow,
and it fires on the first frame any app draws, which makes ASan useless for
finding real defects here.

`#align(4)` rounds the size to 12 so the store is in bounds. Reduced to a
standalone 40-line program with no otsh code in it, on Odin dev-2026-07a /
arm64 macOS: an 11-byte struct as a by-value parameter reports, whether the
parameter is defaulted or explicit; the same struct as a local does not; the
same struct padded or aligned to 12 does not. `Cell` is 16 bytes either way,
so the cell grid — the only place these are stored in bulk — costs nothing.

Example:

```odin
style := tui.Style{fg = tui.ansi(2), bg = tui.no_color(), attrs = {.Bold}}
```

*[tui/screen.odin:90](../tui/screen.odin#L90)*

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

*[tui/tui.odin:34](../tui/tui.odin#L34)*

## Constants

### `BORDER_DOUBLE`

```odin
BORDER_DOUBLE :: Border{'╔', '╗', '╚', '╝', '═', '║'}
```

Double-ruled.

*[tui/screen.odin:346](../tui/screen.odin#L346)*

### `BORDER_ROUND`

```odin
BORDER_ROUND :: Border{'╭', '╮', '╰', '╯', '─', '│'}
```

Rounded corners.

*[tui/screen.odin:342](../tui/screen.odin#L342)*

### `BORDER_SHARP`

```odin
BORDER_SHARP :: Border{'┌', '┐', '└', '┘', '─', '│'}
```

Square corners.

*[tui/screen.odin:344](../tui/screen.odin#L344)*

### `BORDER_THICK`

```odin
BORDER_THICK :: Border{'┏', '┓', '┗', '┛', '━', '┃'}
```

Heavy weight.

*[tui/screen.odin:348](../tui/screen.odin#L348)*

### `MAX_COLS`

```odin
MAX_COLS :: 1000
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

*[tui/screen.odin:168](../tui/screen.odin#L168)*

### `MAX_ROWS`

```odin
MAX_ROWS :: 300
```

*[tui/screen.odin:169](../tui/screen.odin#L169)*

### `WIDE_CONT`

```odin
WIDE_CONT :: rune(-1) // right half of a double-width cell
```

Occupies the right-hand cell of a double-width glyph. Never drawn itself —
`flush` skips it, since the lead glyph already advanced the cursor over it.

*[tui/screen.odin:14](../tui/screen.odin#L14)*

## Procedures

### `ansi`

```odin
ansi :: proc "contextless" (idx: u8) -> Color
```

One of the terminal's 256 palette entries. 0-7 are the base colours, 8-15 the
bright ones; those sixteen follow the user's theme, 16-255 do not.

Example:

```odin
green := tui.Style{fg = tui.ansi(2)}
```

*[tui/screen.odin:45](../tui/screen.odin#L45)*

### `draw_box`

```odin
draw_box :: proc(s: ^Screen, x, y, w, h: int, style: Style, b := BORDER_ROUND, title := "")
```

Draws a box outline with an optional title inset into the top edge. Nothing is
drawn inside it. Silently does nothing if smaller than 2x2.

Example:

```odin
tui.draw_box(s, 2, 1, 40, 10, tui.Style{fg = tui.ansi(6)}, tui.BORDER_ROUND, " files ")
```

*[tui/screen.odin:356](../tui/screen.odin#L356)*

### `draw_text`

```odin
draw_text :: proc(s: ^Screen, x, y: int, text: string, style: Style) -> int
```

Returns the number of columns consumed.

Example:

```odin
tui.draw_text(s, 2, 1, "score: 42", tui.Style{})
```

*[tui/screen.odin:285](../tui/screen.odin#L285)*

### `draw_text_clipped`

```odin
draw_text_clipped :: proc(s: ^Screen, x, y, max_w: int, text: string, style: Style) -> int
```

Draws text clipped to `max_w` columns, appending "…" when it does not fit.

Example:

```odin
tui.draw_text_clipped(s, 0, 0, 12, "a very long label", tui.Style{})
```

*[tui/screen.odin:302](../tui/screen.odin#L302)*

### `fill_rect`

```odin
fill_rect :: proc(s: ^Screen, x, y, w, h: int, r: rune, style: Style)
```

Fills a rectangle with one rune. Clipped to the screen.

Example:

```odin
tui.fill_rect(s, 0, 0, s.w, 1, ' ', tui.Style{bg = tui.ansi(4)}) // status bar
```

*[tui/screen.odin:328](../tui/screen.odin#L328)*

### `flush`

```odin
flush :: proc(s: ^Screen) -> []u8
```

Produces the escape sequence stream that turns the previously rendered frame
into the current one. Returns an empty slice when nothing changed.

*[tui/screen.odin:525](../tui/screen.odin#L525)*

### `key_name`

```odin
key_name :: proc(k: Key, buf: []u8) -> string
```

Human-readable name, handy for help bars and debugging.

Example:

```odin
buf: [16]u8
label := tui.key_name(tui.Key{kind = .Enter}, buf[:]) // "enter"
```

*[tui/key.odin:391](../tui/key.odin#L391)*

### `local_backend`

```odin
local_backend :: proc(l: ^Local) -> Backend
```

A `Backend` over this process's own stdin/stdout.

*[tui/local.odin:52](../tui/local.odin#L52)*

### `local_enter_raw`

```odin
local_enter_raw :: proc(l: ^Local) -> bool
```

Puts the terminal into raw mode: no line buffering, no echo, no signal
generation from Ctrl+C. Over SSH the *client* does this for us, which is why
the server side never needs termios at all.

*[tui/local.odin:83](../tui/local.odin#L83)*

### `local_exit_raw`

```odin
local_exit_raw :: proc(l: ^Local)
```

Restores the terminal settings saved by `local_enter_raw`. Safe to call twice;
always `defer` it, or the user's shell is left in raw mode.

*[tui/local.odin:102](../tui/local.odin#L102)*

### `no_color`

```odin
no_color :: proc "contextless" () -> Color
```

The terminal's own default colour. Prefer this for backgrounds so the user's
theme shows through.

Example:

```odin
style := tui.Style{bg = tui.no_color()}
```

*[tui/screen.odin:38](../tui/screen.odin#L38)*

### `parse_input`

```odin
parse_input :: proc(buf: []u8) -> (ev: Input, n: int, ok: bool)
```

Decodes one event from the front of `buf`.

```
ok == false  -> incomplete sequence, wait for more bytes
n            -> bytes consumed
```

`run` already drives this for you; call it directly only if you are
building your own dispatch loop over a `Backend`.

Example:

```odin
ev, n, ok := tui.parse_input(buf)
if ok {
	switch e in ev {
	case tui.Key:   // e.kind, e.r
	case tui.Mouse: // e.x, e.y
	}
}
```

*[tui/key.odin:104](../tui/key.odin#L104)*

### `quit`

```odin
quit :: proc(p: ^Program)
```

Ends the loop after the current tick, before the next frame is drawn.

Example:

```odin
if k, ok := msg.(tui.Key); ok && k.kind == .Esc {
	tui.quit(p)
}
```

*[tui/tui.odin:97](../tui/tui.odin#L97)*

### `rgb`

```odin
rgb :: proc "contextless" (r, g, b: u8) -> Color
```

A 24-bit colour, emitted as an SGR truecolor sequence. Not a compile-time
constant — use a `:=` package variable, not `::`, for a palette.

Example:

```odin
orange := tui.Style{fg = tui.rgb(255, 128, 0)}
```

*[tui/screen.odin:52](../tui/screen.odin#L52)*

### `run`

```odin
run :: proc(p: ^Program, app: App)
```

Runs `app` until it quits or the connection drops. Sets up the alternate
screen, hides the cursor, disables autowrap, and restores all of it on exit.
Blocks for the lifetime of the app.

Example:

```odin
l: tui.Local
p: tui.Program
p.backend = tui.local_backend(&l)
tui.run(&p, tui.App{data = m, update = update, view = view})
```

*[tui/tui.odin:142](../tui/tui.odin#L142)*

### `rune_width`

```odin
rune_width :: proc "contextless" (r: rune) -> int
```

Display width in terminal columns: 0 for combining marks and format
characters, 2 for East Asian Wide and Fullwidth, 1 for everything else.

The answer comes from `width_table.odin`, generated from the Unicode
character database by `docs/tools/gen_width.py` — a hand-picked range list
is wrong for whole scripts at a time, and one wrong width shifts every
column after it on that line.

Ambiguous-width characters (East Asian Width A) count as 1. Terminals
overwhelmingly render them narrow, and the U+2500 box-drawing block this
package draws its own borders from — `BORDER_ROUND` and friends, via
`draw_box` — is ambiguous: at width 2 every border in every app would be
twice as wide as the box it frames.

Example:

```odin
w := tui.rune_width('字') // 2 — East Asian Wide
```

*[tui/screen.odin:409](../tui/screen.odin#L409)*

### `screen_clear`

```odin
screen_clear :: proc(s: ^Screen, style := Style{})
```

Resets the working buffer. Called by the runtime before each view().

*[tui/screen.odin:194](../tui/screen.odin#L194)*

### `screen_destroy`

```odin
screen_destroy :: proc(s: ^Screen)
```

Frees what `screen_init` allocated.

*[tui/screen.odin:148](../tui/screen.odin#L148)*

### `screen_init`

```odin
screen_init :: proc(s: ^Screen, w, h: int)
```

Allocates the grids and output buffer. `run` calls this for you.

*[tui/screen.odin:142](../tui/screen.odin#L142)*

### `screen_resize`

```odin
screen_resize :: proc(s: ^Screen, w, h: int)
```

Resizes the grids, forcing a full repaint on the next flush. A no-op if the
size is unchanged. Dimensions are clamped to MAX_COLS/MAX_ROWS.

Driving a Program without `run` (e.g. in a test):

Example:

```odin
tui.screen_resize(&p.screen, 100, 40)
```

*[tui/screen.odin:179](../tui/screen.odin#L179)*

### `set_cell`

```odin
set_cell :: proc(s: ^Screen, x, y: int, r: rune, style: Style)
```

Paints one cell, clipped to the screen. A double-width rune also claims the
cell to its right; in the last column, where there is no such cell, a space
is drawn instead. A zero-width rune is ignored.

Example:

```odin
tui.set_cell(s, 0, 0, '*', tui.Style{fg = tui.ansi(3)})
```

*[tui/screen.odin:213](../tui/screen.odin#L213)*

### `set_cursor`

```odin
set_cursor :: proc(s: ^Screen, x, y: int)
```

Shows the terminal cursor at this cell for the current frame. Call it every
frame you want the cursor visible — `screen_clear` hides it again. Use it for
text input, so the caret lands where the user is typing.

Example:

```odin
m := (^Model)(p.app.data)
tui.set_cursor(s, m.cursor_x, m.cursor_y)
```

*[tui/screen.odin:385](../tui/screen.odin#L385)*

### `text_width`

```odin
text_width :: proc "contextless" (text: string) -> int
```

Total display width of a string in terminal columns. Use this, never `len`,
for centering or alignment.

Example:

```odin
title := "status"
x := (s.w - tui.text_width(title)) / 2 // center it
```

*[tui/screen.odin:455](../tui/screen.odin#L455)*

### `with_attrs`

```odin
with_attrs :: proc "contextless" (s: Style, a: Attrs) -> Style
```

Returns a copy of `s` with `a` added to its attributes.

Example:

```odin
bold := tui.with_attrs(base, {.Bold})
```

*[tui/screen.odin:117](../tui/screen.odin#L117)*

### `with_bg`

```odin
with_bg :: proc "contextless" (s: Style, c: Color) -> Style
```

Returns a copy of `s` with the background replaced.

Example:

```odin
selected := tui.with_bg(base, tui.ansi(4)) // highlight a row
```

*[tui/screen.odin:109](../tui/screen.odin#L109)*

### `with_fg`

```odin
with_fg :: proc "contextless" (s: Style, c: Color) -> Style
```

Returns a copy of `s` with the foreground replaced.

Example:

```odin
warn := tui.with_fg(base, tui.ansi(1)) // red on whatever base's background is
```

*[tui/screen.odin:101](../tui/screen.odin#L101)*
