// Cell-buffer screen with diff-based rendering.
//
// The app draws a full frame into a grid of cells every tick; flush() compares
// it against the previously rendered grid and emits only the escape sequences
// needed to turn one into the other. Over SSH that is the difference between
// a few dozen bytes per frame and a few kilobytes.
package tui

import "core:strconv"
import "core:unicode/utf8"

// Occupies the right-hand cell of a double-width glyph. Never drawn itself —
// `flush` skips it, since the lead glyph already advanced the cursor over it.
WIDE_CONT :: rune(-1) // right half of a double-width cell

// How a Color is encoded on the wire. Default emits SGR 39/49 so the user's own
// terminal theme decides; the others pin an exact colour.
Color_Mode :: enum u8 {
	Default,
	Palette,
	True,
}

// A foreground or background colour. Build one with `no_color`, `ansi` or `rgb`
// rather than filling the fields by hand.
Color :: struct {
	mode:    Color_Mode,
	idx:     u8,
	r, g, b: u8,
}

// The terminal's own default colour. Prefer this for backgrounds so the user's
// theme shows through.
no_color :: proc "contextless" () -> Color {return Color{mode = .Default}}
// One of the terminal's 256 palette entries. 0-7 are the base colours, 8-15 the
// bright ones; those sixteen follow the user's theme, 16-255 do not.
ansi :: proc "contextless" (idx: u8) -> Color {return Color{mode = .Palette, idx = idx}}
// A 24-bit colour, emitted as an SGR truecolor sequence. Not a compile-time
// constant — use a `:=` package variable, not `::`, for a palette.
rgb :: proc "contextless" (r, g, b: u8) -> Color {
	return Color{mode = .True, r = r, g = g, b = b}
}

// Text attributes. Terminal support varies: Bold and Reverse are universal,
// Italic and Strike are not.
Attr :: enum u8 {
	Bold,
	Dim,
	Italic,
	Underline,
	Reverse,
	Strike,
}
// A set of `Attr`, e.g. `{.Bold, .Underline}`.
Attrs :: distinct bit_set[Attr;u8]

// Everything about a cell except its rune. The zero value is the terminal's own
// defaults, which is usually what you want as a base.
Style :: struct {
	fg:    Color,
	bg:    Color,
	attrs: Attrs,
}

// Returns a copy of `s` with the foreground replaced.
with_fg :: proc "contextless" (s: Style, c: Color) -> Style {
	s := s;s.fg = c;return s
}
// Returns a copy of `s` with the background replaced.
with_bg :: proc "contextless" (s: Style, c: Color) -> Style {
	s := s;s.bg = c;return s
}
// Returns a copy of `s` with `a` added to its attributes.
with_attrs :: proc "contextless" (s: Style, a: Attrs) -> Style {
	s := s;s.attrs += a;return s
}

// One character cell: a rune plus how to paint it.
Cell :: struct {
	r:     rune,
	style: Style,
}

// The cell grid. `cur` is the frame being drawn, `prev` the one last sent to the
// terminal; `flush` emits the difference. Apps normally only draw into it and
// let `run` handle the rest.
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

// Allocates the grids and output buffer. `run` calls this for you.
screen_init :: proc(s: ^Screen, w, h: int) {
	s.out = make([dynamic]u8, 0, 8192)
	screen_resize(s, w, h)
}

// Frees what `screen_init` allocated.
screen_destroy :: proc(s: ^Screen) {
	delete(s.cur)
	delete(s.prev)
	delete(s.out)
}

// Hard bounds on a screen, in cells.
//
// Terminal geometry arrives from whatever is on the other end. Over SSH that is
// an untrusted uint32 the client picks, so this is a security boundary, not a
// style choice: at 16 bytes per cell and two grids, an unclamped 2e9 x 2e9
// overflows the allocation size, `make` hands back an empty slice, and the first
// draw panics and takes the whole process down. Anything merely large — 10000 x
// 10000 — commits gigabytes instead.
//
// The caps are generous against real hardware — an ultrawide 5120px display at a
// 6px font is about 850 columns, a 4K display at a 10px line height about 210
// rows — while bounding a session at roughly 9.6 MB of cell grid (two grids,
// 16 bytes a cell). That worst case still multiplies by the session limit, so an
// operator expecting many concurrent users should size RAM accordingly.
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

// Resets the working buffer. Called by the runtime before each view().
screen_clear :: proc(s: ^Screen, style := Style{}) {
	for i in 0 ..< len(s.cur) {
		s.cur[i] = Cell {
			r     = ' ',
			style = style,
		}
	}
	s.cursor_visible = false
}

// --- drawing primitives -----------------------------------------------------

// Paints one cell, clipped to the screen. A double-width rune also claims the
// cell to its right; a zero-width one is ignored.
set_cell :: proc(s: ^Screen, x, y: int, r: rune, style: Style) {
	if x < 0 || y < 0 || x >= s.w || y >= s.h {
		return
	}
	w := rune_width(r)
	if w == 0 {
		return
	}
	row := y * s.w

	// Overwriting half of a double-width glyph would leave the other half
	// orphaned. `flush` walks the grid one index at a time while advancing the
	// real cursor by each rune's width, so a lead without its continuation (or a
	// continuation without its lead) desynchronises the two for the rest of that
	// run — and since `prev` then records the wrong cells as painted, the damage
	// is permanent rather than repaired on the next frame.
	//
	// This is reachable with ordinary drawing: a box or a fill landing on one
	// column of a CJK label is enough. So break the pair up here, where we still
	// know which cells were involved, and blank the orphan.
	if s.cur[row + x].r == WIDE_CONT && x > 0 {
		s.cur[row + x - 1] = Cell {
			r     = ' ',
			style = s.cur[row + x - 1].style,
		}
	}
	if rune_width(s.cur[row + x].r) == 2 && x + 1 < s.w {
		s.cur[row + x + 1] = Cell {
			r     = ' ',
			style = s.cur[row + x + 1].style,
		}
	}
	// The cell we are about to claim as a continuation has the same problem.
	if w == 2 && x + 1 < s.w && rune_width(s.cur[row + x + 1].r) == 2 && x + 2 < s.w {
		s.cur[row + x + 2] = Cell {
			r     = ' ',
			style = s.cur[row + x + 2].style,
		}
	}

	s.cur[row + x] = Cell {
		r     = r,
		style = style,
	}
	if w == 2 && x + 1 < s.w {
		s.cur[row + x + 1] = Cell {
			r     = WIDE_CONT,
			style = style,
		}
	}
}

// Returns the number of columns consumed.
draw_text :: proc(s: ^Screen, x, y: int, text: string, style: Style) -> int {
	col := x
	for r in text {
		if col >= s.w {
			break
		}
		set_cell(s, col, y, r, style)
		col += rune_width(r)
	}
	return col - x
}

// Draws text clipped to `max_w` columns, appending "…" when it does not fit.
draw_text_clipped :: proc(s: ^Screen, x, y, max_w: int, text: string, style: Style) -> int {
	if max_w <= 0 {
		return 0
	}
	if text_width(text) <= max_w {
		return draw_text(s, x, y, text, style)
	}
	col := x
	limit := x + max_w - 1
	for r in text {
		w := rune_width(r)
		if col + w > limit {
			break
		}
		set_cell(s, col, y, r, style)
		col += w
	}
	set_cell(s, col, y, '…', style)
	return col + 1 - x
}

// Fills a rectangle with one rune. Clipped to the screen.
fill_rect :: proc(s: ^Screen, x, y, w, h: int, r: rune, style: Style) {
	for row in y ..< y + h {
		for col in x ..< x + w {
			set_cell(s, col, row, r, style)
		}
	}
}

// The six runes `draw_box` uses: four corners, then horizontal and vertical.
Border :: struct {
	tl, tr, bl, br, h, v: rune,
}

// Rounded corners.
BORDER_ROUND :: Border{'╭', '╮', '╰', '╯', '─', '│'}
// Square corners.
BORDER_SHARP :: Border{'┌', '┐', '└', '┘', '─', '│'}
// Double-ruled.
BORDER_DOUBLE :: Border{'╔', '╗', '╚', '╝', '═', '║'}
// Heavy weight.
BORDER_THICK :: Border{'┏', '┓', '┗', '┛', '━', '┃'}

// Draws a box outline with an optional title inset into the top edge. Nothing is
// drawn inside it. Silently does nothing if smaller than 2x2.
draw_box :: proc(s: ^Screen, x, y, w, h: int, style: Style, b := BORDER_ROUND, title := "") {
	if w < 2 || h < 2 {
		return
	}
	set_cell(s, x, y, b.tl, style)
	set_cell(s, x + w - 1, y, b.tr, style)
	set_cell(s, x, y + h - 1, b.bl, style)
	set_cell(s, x + w - 1, y + h - 1, b.br, style)
	for col in x + 1 ..< x + w - 1 {
		set_cell(s, col, y, b.h, style)
		set_cell(s, col, y + h - 1, b.h, style)
	}
	for row in y + 1 ..< y + h - 1 {
		set_cell(s, x, row, b.v, style)
		set_cell(s, x + w - 1, row, b.v, style)
	}
	if title != "" && w > 4 {
		draw_text_clipped(s, x + 2, y, w - 4, title, style)
	}
}

// Shows the terminal cursor at this cell for the current frame. Call it every
// frame you want the cursor visible — `screen_clear` hides it again. Use it for
// text input, so the caret lands where the user is typing.
set_cursor :: proc(s: ^Screen, x, y: int) {
	s.cursor_visible = true
	s.cursor_x, s.cursor_y = x, y
}

// --- text metrics -----------------------------------------------------------

// Display width in terminal columns. Covers the ranges that matter in
// practice: combining marks (0), CJK and emoji (2), everything else (1).
rune_width :: proc "contextless" (r: rune) -> int {
	switch {
	case r == WIDE_CONT:
		return 0
	case r < 0x20:
		return 0
	case r < 0x7f:
		return 1
	case r >= 0x0300 && r <= 0x036f:
		return 0 // combining diacriticals
	case r >= 0x200b && r <= 0x200f:
		return 0 // zero-width space/joiners
	case r == 0xfe0f || r == 0xfe0e:
		return 0 // variation selectors
	case r >= 0x1100 && r <= 0x115f:
		return 2 // hangul jamo
	case r >= 0x2e80 && r <= 0xa4cf:
		return 2 // CJK radicals … yi
	case r >= 0xac00 && r <= 0xd7a3:
		return 2 // hangul syllables
	case r >= 0xf900 && r <= 0xfaff:
		return 2 // CJK compatibility ideographs
	case r >= 0xfe30 && r <= 0xfe6f:
		return 2 // CJK compatibility forms
	case r >= 0xff00 && r <= 0xff60:
		return 2 // fullwidth forms
	case r >= 0xffe0 && r <= 0xffe6:
		return 2
	case r >= 0x1f300 && r <= 0x1f64f:
		return 2 // emoji
	case r >= 0x1f900 && r <= 0x1f9ff:
		return 2
	case r >= 0x20000 && r <= 0x3fffd:
		return 2
	}
	return 1
}

// Total display width of a string in terminal columns. Use this, never `len`,
// for centering or alignment.
text_width :: proc "contextless" (text: string) -> int {
	w := 0
	for r in text {
		w += rune_width(r)
	}
	return w
}

// --- ANSI emission ----------------------------------------------------------

@(private)
put :: proc(s: ^Screen, str: string) {
	append(&s.out, str)
}

@(private)
put_int :: proc(s: ^Screen, v: int) {
	buf: [24]u8
	append(&s.out, ..transmute([]u8)strconv.write_int(buf[:], i64(v), 10))
}

@(private)
put_rune :: proc(s: ^Screen, r: rune) {
	bytes, n := utf8.encode_rune(r)
	append(&s.out, ..bytes[:n])
}

@(private)
move_to :: proc(s: ^Screen, x, y: int) {
	put(s, "\x1b[")
	put_int(s, y + 1)
	put(s, ";")
	put_int(s, x + 1)
	put(s, "H")
}

@(private)
put_color :: proc(s: ^Screen, c: Color, is_bg: bool) {
	switch c.mode {
	case .Default:
		put(s, is_bg ? ";49" : ";39")
	case .Palette:
		put(s, is_bg ? ";48;5;" : ";38;5;")
		put_int(s, int(c.idx))
	case .True:
		put(s, is_bg ? ";48;2;" : ";38;2;")
		put_int(s, int(c.r))
		put(s, ";")
		put_int(s, int(c.g))
		put(s, ";")
		put_int(s, int(c.b))
	}
}

@(private)
put_style :: proc(s: ^Screen, st: Style) {
	put(s, "\x1b[0")
	if .Bold in st.attrs {put(s, ";1")}
	if .Dim in st.attrs {put(s, ";2")}
	if .Italic in st.attrs {put(s, ";3")}
	if .Underline in st.attrs {put(s, ";4")}
	if .Reverse in st.attrs {put(s, ";7")}
	if .Strike in st.attrs {put(s, ";9")}
	put_color(s, st.fg, false)
	put_color(s, st.bg, true)
	put(s, "m")
}

// Produces the escape sequence stream that turns the previously rendered frame
// into the current one. Returns an empty slice when nothing changed.
flush :: proc(s: ^Screen) -> []u8 {
	clear(&s.out)

	if s.full_redraw {
		put(s, "\x1b[0m\x1b[2J")
		for i in 0 ..< len(s.prev) {
			s.prev[i] = Cell{}
		}
		s.full_redraw = false
	}

	last_style := Style{}
	style_valid := false
	cursor_known := false
	cx, cy := 0, 0

	for y in 0 ..< s.h {
		x := 0
		for x < s.w {
			i := y * s.w + x
			if s.cur[i] == s.prev[i] {
				x += 1
				continue
			}
			// Never start a run on the right half of a wide glyph.
			if s.cur[i].r == WIDE_CONT && x > 0 {
				x -= 1
				i -= 1
			}

			if !cursor_known || cx != x || cy != y {
				move_to(s, x, y)
				cx, cy = x, y
				cursor_known = true
			}

			// Extend the run through unchanged cells too — a short gap is
			// cheaper to overwrite than to jump over.
			gap := 0
			for x < s.w {
				i = y * s.w + x
				cell := s.cur[i]
				if cell == s.prev[i] {
					gap += 1
					if gap > 4 {
						break
					}
				} else {
					gap = 0
				}

				if cell.r == WIDE_CONT {
					s.prev[i] = cell
					x += 1
					continue // the lead glyph already moved the cursor
				}

				if !style_valid || cell.style != last_style {
					put_style(s, cell.style)
					last_style = cell.style
					style_valid = true
				}
				put_rune(s, cell.r == 0 ? ' ' : cell.r)
				s.prev[i] = cell
				w := rune_width(cell.r)
				x += 1
				cx += max(w, 1)
			}
		}
	}

	if len(s.out) > 0 {
		put(s, "\x1b[0m")
	}

	if s.cursor_visible {
		move_to(s, s.cursor_x, s.cursor_y)
		put(s, "\x1b[?25h")
	} else if len(s.out) > 0 {
		put(s, "\x1b[?25l")
	}

	return s.out[:]
}
