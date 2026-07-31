// Regression tests written after an adversarial pass against the live server.
//
// The suite next door checks the parser and the drawing primitives in
// isolation. What was missing was a check on the two loops that a hostile
// client actually drives: the diff renderer, whose whole correctness argument
// is "prev is what the terminal shows", and `tui.run`, which is the thing
// holding a connection when the bytes arriving are garbage.
//
// So the tests here run against a model terminal — an independent
// implementation of the escape sequences `flush` emits — and against a scripted
// `tui.Backend` that plays the part of a malicious client.
package otsh_tests

import "core:math/rand"
import "core:testing"
import "core:unicode/utf8"
import "otsh:tui"

// --- a model terminal -------------------------------------------------------
//
// `flush` is only correct if replaying its output onto a terminal reproduces
// `Screen.cur` exactly. Nothing checked that before: the existing tests assert
// what flush emits, which is the same reasoning the renderer itself uses. This
// interprets the bytes instead.

@(private = "file")
Model :: struct {
	w, h:  int,
	cells: []rune,
	x, y:  int,
	stray: int, // glyphs that landed outside the grid
}

@(private = "file")
model_destroy :: proc(m: ^Model) {
	delete(m.cells)
	m.cells = nil
}

@(private = "file")
model_resize :: proc(m: ^Model, w, h: int) {
	delete(m.cells)
	m.w, m.h = w, h
	m.cells = make([]rune, w * h)
	for i in 0 ..< len(m.cells) {
		m.cells[i] = ' '
	}
	m.x, m.y = 0, 0
}

@(private = "file")
model_put :: proc(m: ^Model, r: rune) {
	w := tui.rune_width(r)
	if w == 0 {
		// flush must never emit a zero-width rune: it would desynchronise the
		// real cursor from the column `flush` thinks it is on.
		m.stray += 1
		return
	}
	if m.y < 0 || m.y >= m.h || m.x < 0 || m.x >= m.w {
		m.stray += 1
		m.x += w
		return
	}
	m.cells[m.y * m.w + m.x] = r
	if w == 2 {
		if m.x + 1 < m.w {
			m.cells[m.y * m.w + m.x + 1] = tui.WIDE_CONT
		} else {
			m.stray += 1 // a wide glyph with nowhere to put its right half
		}
	}
	m.x += w
}

// Applies exactly the subset of ANSI that screen.odin produces.
@(private = "file")
model_feed :: proc(m: ^Model, out: []u8) {
	i := 0
	for i < len(out) {
		if out[i] == 0x1b {
			if i + 1 >= len(out) || out[i + 1] != '[' {
				m.stray += 1
				i += 1
				continue
			}
			j := i + 2
			for j < len(out) && !(out[j] >= 0x40 && out[j] <= 0x7e) {
				j += 1
			}
			if j >= len(out) {
				m.stray += 1 // truncated sequence
				return
			}
			body, final := out[i + 2:j], out[j]
			switch final {
			case 'H':
				r, c := 1, 1
				k, cur := 0, 0
				seen := false
				for b in body {
					if b >= '0' && b <= '9' {
						cur = cur * 10 + int(b - '0')
						seen = true
					} else if b == ';' {
						if k == 0 {r = seen ? cur : 1}
						k += 1
						cur, seen = 0, false
					}
				}
				if k == 0 {
					r = seen ? cur : 1
				} else {
					c = seen ? cur : 1
				}
				m.y, m.x = r - 1, c - 1
			case 'J':
				for idx in 0 ..< len(m.cells) {
					m.cells[idx] = ' '
				}
			case 'm', 'h', 'l':
			// styles and modes do not move the cursor
			case:
				m.stray += 1
			}
			i = j + 1
			continue
		}
		r, sz := utf8.decode_rune(out[i:])
		if sz <= 0 {
			m.stray += 1
			i += 1
			continue
		}
		model_put(m, r)
		i += sz
	}
}

// Every cell of the model must equal the cell the app drew.
@(private = "file")
model_matches :: proc(t: ^testing.T, m: ^Model, s: ^tui.Screen, where_: string) -> bool {
	if m.w != s.w || m.h != s.h {
		testing.expectf(t, false, "%s: model is %dx%d, screen is %dx%d", where_, m.w, m.h, s.w, s.h)
		return false
	}
	for y in 0 ..< s.h {
		for x in 0 ..< s.w {
			i := y * s.w + x
			want := s.cur[i].r
			if want == 0 {want = ' '}
			if m.cells[i] != want {
				testing.expectf(t, false,
					"%s: cell (%d,%d) — terminal shows %v, app drew %v",
					where_, x, y, m.cells[i], want)
				return false
			}
		}
	}
	return true
}

// A mix chosen to hit every branch of set_cell and flush: narrow ASCII, East
// Asian Wide (2 columns), a combining mark (0 columns, must be dropped), and
// the box-drawing runes the package's own borders use.
@(private = "file")
ALPHABET := []rune {
	'a', 'Z', '0', ' ', '.', '#',
	'世', '界', 'ｆ', '＝',
	'́', '​',
	'─', '│', '╭', '╯', '█', '…', '▌',
	'é', 'ß', '🎉',
}

@(private = "file")
draw_random_frame :: proc(s: ^tui.Screen) {
	styles := []tui.Style {
		{},
		{fg = tui.ansi(1)},
		{bg = tui.ansi(4), attrs = {.Bold}},
		{fg = tui.rgb(10, 200, 30), bg = tui.rgb(1, 2, 3)},
		{attrs = {.Reverse, .Underline}},
	}
	pick :: proc(n: int) -> int {return int(rand.uint32() % u32(max(n, 1)))}

	n := 1 + pick(12)
	for _ in 0 ..< n {
		st := styles[pick(len(styles))]
		switch pick(5) {
		case 0:
			tui.set_cell(s, pick(s.w + 2) - 1, pick(s.h + 2) - 1, ALPHABET[pick(len(ALPHABET))], st)
		case 1:
			buf: [24]u8
			k := 0
			for _ in 0 ..< 1 + pick(8) {
				b, sz := utf8.encode_rune(ALPHABET[pick(len(ALPHABET))])
				if k + sz > len(buf) {break}
				copy(buf[k:], b[:sz])
				k += sz
			}
			tui.draw_text(s, pick(s.w + 2) - 1, pick(s.h + 1) - 1, string(buf[:k]), st)
		case 2:
			tui.fill_rect(s, pick(s.w) - 1, pick(s.h) - 1, pick(s.w), pick(s.h),
				ALPHABET[pick(len(ALPHABET))], st)
		case 3:
			tui.draw_box(s, pick(s.w) - 1, pick(s.h) - 1, pick(s.w + 2), pick(s.h + 2), st)
		case 4:
			buf: [16]u8
			k := 0
			for _ in 0 ..< 1 + pick(5) {
				b, sz := utf8.encode_rune(ALPHABET[pick(len(ALPHABET))])
				if k + sz > len(buf) {break}
				copy(buf[k:], b[:sz])
				k += sz
			}
			tui.draw_text_clipped(s, pick(s.w) - 1, pick(s.h) - 1, pick(s.w + 2) - 1,
				string(buf[:k]), st)
		}
	}
}

@(test)
renderer_matches_a_model_terminal :: proc(t: ^testing.T) {
	rand.reset(0xD1FF)
	s: tui.Screen
	tui.screen_init(&s, 37, 11)
	defer tui.screen_destroy(&s)

	m: Model
	defer model_destroy(&m)
	model_resize(&m, s.w, s.h)

	for round in 0 ..< 600 {
		tui.screen_clear(&s)
		draw_random_frame(&s)
		model_feed(&m, tui.flush(&s))
		if !model_matches(t, &m, &s, "steady size") {
			testing.expectf(t, false, "diverged at round %d", round)
			return
		}
	}
	testing.expectf(t, m.stray == 0, "renderer emitted %d bytes the terminal could not place", m.stray)
}

@(test)
renderer_matches_a_model_terminal_across_resizes :: proc(t: ^testing.T) {
	// A resize storm is the case where "prev is what the terminal shows" is
	// easiest to get wrong, because the grids are reallocated underneath it.
	rand.reset(0x5152)
	s: tui.Screen
	tui.screen_init(&s, 20, 6)
	defer tui.screen_destroy(&s)

	m: Model
	defer model_destroy(&m)
	model_resize(&m, s.w, s.h)

	for round in 0 ..< 600 {
		if rand.uint32() % 3 == 0 {
			w := 1 + int(rand.uint32() % 60)
			h := 1 + int(rand.uint32() % 20)
			tui.screen_resize(&s, w, h)
			// A real terminal is resized by the user, not by us; the model
			// follows the geometry the screen actually adopted.
			if m.w != s.w || m.h != s.h {
				model_resize(&m, s.w, s.h)
			}
		}
		tui.screen_clear(&s)
		draw_random_frame(&s)
		model_feed(&m, tui.flush(&s))
		if !model_matches(t, &m, &s, "resizing") {
			testing.expectf(t, false, "diverged at round %d (%dx%d)", round, s.w, s.h)
			return
		}
	}
	testing.expectf(t, m.stray == 0, "renderer emitted %d bytes the terminal could not place", m.stray)
}

@(test)
renderer_matches_a_model_terminal_at_degenerate_sizes :: proc(t: ^testing.T) {
	// 1x1, 2x1 and 1x2 are what a client gets to ask for, and every branch that
	// says `x + 1 < s.w` behaves differently there.
	sizes := [][2]int{{1, 1}, {2, 1}, {1, 2}, {3, 2}, {2, 3}, {1, 40}, {40, 1}}
	rand.reset(0xDEAD)
	for sz in sizes {
		s: tui.Screen
		tui.screen_init(&s, sz.x, sz.y)
		defer tui.screen_destroy(&s)

		m: Model
		defer model_destroy(&m)
		model_resize(&m, s.w, s.h)

		for round in 0 ..< 200 {
			tui.screen_clear(&s)
			draw_random_frame(&s)
			model_feed(&m, tui.flush(&s))
			if !model_matches(t, &m, &s, "degenerate") {
				testing.expectf(t, false, "diverged at %dx%d round %d", sz.x, sz.y, round)
				break
			}
		}
	}
}

// --- geometry ---------------------------------------------------------------

@(test)
screen_resize_clamps_hostile_geometry :: proc(t: ^testing.T) {
	// These are the numbers a client can put in a pty-req or a window-change.
	cases := [][2]int {
		{0, 0}, {-1, -1}, {1, 1},
		{tui.MAX_COLS, tui.MAX_ROWS},
		{tui.MAX_COLS + 1, tui.MAX_ROWS + 1},
		{1 << 20, 1 << 20},
		{int(max(i32)) / 2, int(max(i32)) / 2},
		{65535, 65535},
	}
	s: tui.Screen
	tui.screen_init(&s, 80, 24)
	defer tui.screen_destroy(&s)

	for c in cases {
		tui.screen_resize(&s, c.x, c.y)
		testing.expectf(t, s.w >= 1 && s.w <= tui.MAX_COLS,
			"width %d out of range after asking for %d", s.w, c.x)
		testing.expectf(t, s.h >= 1 && s.h <= tui.MAX_ROWS,
			"height %d out of range after asking for %d", s.h, c.y)
		testing.expectf(t, len(s.cur) == s.w * s.h && len(s.prev) == s.w * s.h,
			"grid is %d cells for a %dx%d screen", len(s.cur), s.w, s.h)
		// Drawing into the extremes must stay in bounds.
		tui.set_cell(&s, s.w - 1, s.h - 1, '世', {})
		tui.set_cell(&s, 0, 0, '界', {})
		tui.draw_text(&s, s.w - 2, s.h - 1, "世界", {})
		_ = tui.flush(&s)
	}
}

@(test)
wide_glyph_never_orphaned :: proc(t: ^testing.T) {
	// The invariant flush depends on, asserted at the one place it is easiest
	// to break: a double-width glyph whose right half would fall off the edge.
	// A lead without a continuation makes flush advance the real cursor by two
	// columns while advancing its own index by one, and `prev` then records a
	// frame the terminal is not showing — damage that never repairs.
	for w in 1 ..= 6 {
		s: tui.Screen
		tui.screen_init(&s, w, 2)
		defer tui.screen_destroy(&s)

		tui.draw_text(&s, 0, 0, "世界世界世界", {})
		tui.set_cell(&s, w - 1, 1, '界', {})

		for y in 0 ..< s.h {
			for x in 0 ..< s.w {
				r := s.cur[y * s.w + x].r
				if tui.rune_width(r) == 2 {
					testing.expectf(t, x + 1 < s.w,
						"width %d: wide lead %v in the last column (%d,%d)", w, r, x, y)
					if x + 1 < s.w {
						testing.expectf(t, s.cur[y * s.w + x + 1].r == tui.WIDE_CONT,
							"width %d: wide lead at (%d,%d) lost its continuation", w, x, y)
					}
				}
				if r == tui.WIDE_CONT {
					testing.expectf(t, x > 0, "width %d: continuation at column 0", w)
					if x > 0 {
						testing.expectf(t, tui.rune_width(s.cur[y * s.w + x - 1].r) == 2,
							"width %d: continuation at (%d,%d) has no lead", w, x, y)
					}
				}
			}
		}
	}
}

// --- the frame loop against a hostile backend -------------------------------

@(private = "file")
Script :: struct {
	chunks:     [][]u8, // one poll's worth each, cycled
	next:       int,
	frames:     int,
	max_frames: int,
	sizes:      [][2]int, // geometry reported per frame, cycled; empty = 80x24
	size_calls: int,
	written:    int,
	keys:       int,
	mice:       int,
	resizes:    int,
	last_resize: tui.Resize,
	max_pending: int,
}

@(private = "file")
script_backend :: proc(sc: ^Script) -> tui.Backend {
	return tui.Backend {
		data = sc,
		write = proc(data: rawptr, buf: []u8) -> int {
			s := (^Script)(data)
			s.written += len(buf)
			return len(buf)
		},
		poll = proc(data: rawptr, buf: []u8, timeout_ms: int) -> (n: int, ok: bool) {
			s := (^Script)(data)
			s.frames += 1
			if s.frames > s.max_frames {
				return 0, false // the client hung up
			}
			if len(s.chunks) == 0 {
				return 0, true
			}
			c := s.chunks[s.next % len(s.chunks)]
			s.next += 1
			n = min(len(c), len(buf))
			copy(buf[:n], c[:n])
			return n, true
		},
		size = proc(data: rawptr) -> (cols, rows: int) {
			s := (^Script)(data)
			s.size_calls += 1
			if len(s.sizes) == 0 {
				return 80, 24
			}
			g := s.sizes[(s.size_calls - 1) % len(s.sizes)]
			return g.x, g.y
		},
	}
}

@(private = "file")
script_app :: proc(sc: ^Script) -> tui.App {
	return tui.App {
		data = sc,
		update = proc(p: ^tui.Program, msg: tui.Msg) {
			s := (^Script)(p.app.data)
			s.max_pending = max(s.max_pending, len(p.pending))
			switch m in msg {
			case tui.Key:
				s.keys += 1
			case tui.Mouse:
				s.mice += 1
			case tui.Resize:
				s.resizes += 1
				s.last_resize = m
			case tui.Tick:
			}
		},
		view = proc(p: ^tui.Program, sc: ^tui.Screen) {
			tui.draw_box(sc, 0, 0, sc.w, sc.h, {})
			tui.draw_text(sc, 1, 1, "世界 hostile", {})
		},
	}
}

@(private = "file")
run_script :: proc(sc: ^Script) -> tui.Program {
	p: tui.Program
	p.backend = script_backend(sc)
	// A huge frame rate collapses the per-frame sleep to nothing: the loop's
	// logic does not depend on wall time (stall counting is per frame), so the
	// test runs the same number of frames in a fraction of the time.
	p.fps = 200_000
	tui.run(&p, script_app(sc))
	return p
}

@(test)
run_survives_hostile_input :: proc(t: ^testing.T) {
	// Every one of these was thrown at the live server over a real SSH channel.
	// What must hold is that `run` returns, that the pending buffer stays
	// bounded, and that no payload leaves the loop unable to make progress.
	esc_pairs := make([]u8, 4096)
	defer delete(esc_pairs)
	for i in 0 ..< len(esc_pairs) {
		esc_pairs[i] = i % 2 == 0 ? 0x1b : '['
	}
	csi_run := make([]u8, 4096)
	defer delete(csi_run)
	csi_run[0], csi_run[1] = 0x1b, '['
	for i in 2 ..< len(csi_run) {
		csi_run[i] = '1'
	}
	nuls := make([]u8, 4096)
	defer delete(nuls)
	escapes := make([]u8, 4096)
	defer delete(escapes)
	for i in 0 ..< len(escapes) {
		escapes[i] = 0x1b
	}
	mouse_prefix := make([]u8, 4096)
	defer delete(mouse_prefix)
	mouse_prefix[0], mouse_prefix[1], mouse_prefix[2] = 0x1b, '[', '<'
	for i in 3 ..< len(mouse_prefix) {
		mouse_prefix[i] = '9'
	}
	rnd := make([]u8, 4096)
	defer delete(rnd)
	rand.reset(0xF00D)
	for i in 0 ..< len(rnd) {
		rnd[i] = u8(rand.uint32())
	}

	cases := []struct {
		name:   string,
		chunks: [][]u8,
	} {
		{"unterminated CSI pairs", {esc_pairs}},
		{"one long CSI parameter run", {csi_run}},
		{"NUL flood", {nuls}},
		{"bare escapes", {escapes}},
		{"unterminated SGR mouse", {mouse_prefix}},
		{"random bytes", {rnd}},
		{"trickled escape", {{0x1b}}},
		{"trickled CSI", {{0x1b}, {'['}, {'1'}, {';'}, {'2'}}},
		{"split utf-8", {{0xf0}, {0x9f}, {0x8e}, {0x89}}},
		{"invalid continuations", {{0x80, 0x81, 0xbf, 0x80, 0xbf}}},
		{"mouse with absurd coordinates",
			{transmute([]u8)string("\x1b[<0;99999999999;99999999999M")}},
	}

	for c in cases {
		sc := Script {
			chunks     = c.chunks,
			max_frames = 400,
		}
		p := run_script(&sc)
		testing.expectf(t, sc.frames >= sc.max_frames,
			"%s: loop ended early after %d frames", c.name, sc.frames)
		// dispatch_input drops a leading byte once the buffer passes
		// MAX_INCOMPLETE, so it can never grow past that plus one poll.
		testing.expectf(t, sc.max_pending <= 256 + len(p.read_buf),
			"%s: pending grew to %d bytes — the drop-and-resync path did not fire",
			c.name, sc.max_pending)
		testing.expectf(t, sc.written > 0, "%s: nothing was ever rendered", c.name)
	}
}

@(test)
run_reports_one_resize_per_real_geometry_change :: proc(t: ^testing.T) {
	// A Backend is free to report whatever the far end claimed, and over SSH
	// that is an untrusted uint32. `run` clamps it into the screen — so the
	// comparison that decides whether to emit a Resize has to be against the
	// clamped size. Comparing against the raw request instead means an
	// out-of-range terminal re-fires a Resize *every frame*, forever, and hands
	// the app cols/rows that are not on the grid.
	sizes := [][2]int{{5000, 5000}}
	sc := Script {
		sizes      = sizes,
		max_frames = 120,
	}
	p := run_script(&sc)
	testing.expectf(t, sc.resizes <= 1,
		"a constant (if out-of-range) geometry produced %d Resize messages", sc.resizes)
	if sc.resizes > 0 {
		testing.expectf(t,
			sc.last_resize.cols == p.screen.w && sc.last_resize.rows == p.screen.h,
			"Resize said %dx%d but the screen is %dx%d",
			sc.last_resize.cols, sc.last_resize.rows, p.screen.w, p.screen.h)
	}
	testing.expectf(t, p.screen.w <= tui.MAX_COLS && p.screen.h <= tui.MAX_ROWS,
		"screen is %dx%d, past the cap", p.screen.w, p.screen.h)
}

@(test)
run_resize_storm_stays_consistent :: proc(t: ^testing.T) {
	// Alternating geometries, including out-of-range ones, at one change per
	// frame. Every Resize the app sees must name the size the screen actually
	// has, or layout code that trusts the message draws off the grid.
	sizes := [][2]int {
		{1, 1}, {2000, 900}, {80, 24}, {0, 0}, {1000, 300}, {1001, 301}, {44, 14},
	}
	sc := Script {
		sizes      = sizes,
		max_frames = 300,
	}
	p := run_script(&sc)
	testing.expectf(t, sc.resizes > 0, "a resize storm produced no Resize messages at all")
	testing.expectf(t, sc.resizes <= sc.frames,
		"more Resize messages (%d) than frames (%d)", sc.resizes, sc.frames)
	testing.expectf(t,
		sc.last_resize.cols == p.screen.w && sc.last_resize.rows == p.screen.h,
		"last Resize said %dx%d but the screen is %dx%d",
		sc.last_resize.cols, sc.last_resize.rows, p.screen.w, p.screen.h)
	testing.expect(t, sc.written > 0)
}
