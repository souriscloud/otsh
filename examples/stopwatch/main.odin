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
