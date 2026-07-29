// Tests for the pure logic in otsh:tui — text metrics, input decoding, and the
// diffing renderer. None of this needs a terminal or a network.
//
//	./test.sh          (or: odin test tests -collection:otsh=.)
package otsh_tests

import "core:testing"
import "otsh:tui"

// --- text metrics -----------------------------------------------------------

@(test)
rune_width_basics :: proc(t: ^testing.T) {
	testing.expect_value(t, tui.rune_width('a'), 1)
	testing.expect_value(t, tui.rune_width(' '), 1)
	testing.expect_value(t, tui.rune_width('é'), 1)
	// Control characters occupy no columns.
	testing.expect_value(t, tui.rune_width('\n'), 0)
	testing.expect_value(t, tui.rune_width(rune(0x07)), 0)
}

@(test)
rune_width_wide :: proc(t: ^testing.T) {
	testing.expect_value(t, tui.rune_width('世'), 2) // CJK
	testing.expect_value(t, tui.rune_width('한'), 2) // hangul syllable
	testing.expect_value(t, tui.rune_width('🙂'), 2) // emoji
	testing.expect_value(t, tui.rune_width('！'), 2) // fullwidth form
}

@(test)
rune_width_zero :: proc(t: ^testing.T) {
	testing.expect_value(t, tui.rune_width(rune(0x0301)), 0) // combining acute
	testing.expect_value(t, tui.rune_width(rune(0x200b)), 0) // zero-width space
	testing.expect_value(t, tui.rune_width(rune(0xfe0f)), 0) // variation selector
	// The continuation sentinel must never claim a column of its own.
	testing.expect_value(t, tui.rune_width(tui.WIDE_CONT), 0)
}

// The widths below come from the generated table in tui/width_table.odin
// (docs/tools/gen_width.py). They are the cases a hand-written range list gets
// wrong, and each wrong answer shifts every column after it on the line.

@(test)
rune_width_wide_from_table :: proc(t: ^testing.T) {
	testing.expect_value(t, tui.rune_width('世'), 2)          // CJK unified ideograph
	testing.expect_value(t, tui.rune_width('한'), 2)          // hangul syllable
	testing.expect_value(t, tui.rune_width(rune(0x1f600)), 2) // grinning face
	testing.expect_value(t, tui.rune_width('Ａ'), 2)          // fullwidth latin A
	testing.expect_value(t, tui.rune_width('　'), 2)          // ideographic space
}

@(test)
rune_width_zero_from_table :: proc(t: ^testing.T) {
	testing.expect_value(t, tui.rune_width(rune(0x0301)), 0) // combining acute accent
	testing.expect_value(t, tui.rune_width(rune(0x200d)), 0) // zero-width joiner
	testing.expect_value(t, tui.rune_width(rune(0x0591)), 0) // hebrew accent etnahta
	testing.expect_value(t, tui.rune_width(rune(0x0e31)), 0) // thai mai han akat
	// Not every mark is invisible: U+0E33 is a spacing letter, not a mark.
	testing.expect_value(t, tui.rune_width(rune(0x0e33)), 1)
}

@(test)
rune_width_ambiguous_is_narrow :: proc(t: ^testing.T) {
	// East Asian Width A. The package's own borders live in this block, so
	// width 2 here would double every box `draw_box` draws.
	testing.expect_value(t, tui.rune_width('─'), 1)
	testing.expect_value(t, tui.rune_width('│'), 1)
	testing.expect_value(t, tui.rune_width('╭'), 1)
	testing.expect_value(t, tui.rune_width('…'), 1) // the clipping ellipsis
	testing.expect_value(t, tui.rune_width('±'), 1)
}

@(test)
rune_width_ascii_and_controls :: proc(t: ^testing.T) {
	for r in rune(0x20) ..= rune(0x7e) {
		testing.expectf(t, tui.rune_width(r) == 1, "printable ASCII %v is not one column", r)
	}
	testing.expect_value(t, tui.rune_width(rune(0x00)), 0)
	testing.expect_value(t, tui.rune_width(rune(0x1b)), 0) // ESC
	// DEL and the C1 controls are dropped like the C0 ones: a control byte in
	// the grid would be written straight into the escape stream.
	testing.expect_value(t, tui.rune_width(rune(0x7f)), 0)
	testing.expect_value(t, tui.rune_width(rune(0x9b)), 0)
	testing.expect_value(t, tui.rune_width(rune(0x00ad)), 1) // soft hyphen: Cf, but drawn
}

@(test)
text_width_mixes_widths :: proc(t: ^testing.T) {
	// "cafe" + combining acute + space + CJK + emoji: 4 + 0 + 1 + 2 + 2.
	testing.expect_value(t, tui.text_width("cafe\u0301 \u4e16\U0001F600"), 9)
}

@(test)
draw_box_borders_are_one_column :: proc(t: ^testing.T) {
	// The concrete consequence of ambiguous -> 1: a box is exactly as wide as
	// it was asked to be, with no continuation cells anywhere in it.
	s: tui.Screen
	tui.screen_init(&s, 12, 4)
	defer tui.screen_destroy(&s)

	tui.draw_box(&s, 0, 0, 10, 4, {})
	testing.expect_value(t, s.cur[0].r, '╭')
	testing.expect_value(t, s.cur[9].r, '╮')  // top-right corner, not shifted
	testing.expect_value(t, s.cur[10].r, ' ') // nothing past the box
	for y in 0 ..< s.h {
		for x in 0 ..< s.w {
			testing.expectf(t, s.cur[y * s.w + x].r != tui.WIDE_CONT,
				"border glyph claimed two columns at (%d,%d)", x, y)
		}
	}
}

@(test)
text_width_is_not_byte_length :: proc(t: ^testing.T) {
	// The whole point: len() counts bytes, text_width counts columns.
	s := "héllo"
	testing.expect_value(t, tui.text_width(s), 5)
	testing.expect(t, len(s) != tui.text_width(s), "expected bytes != columns")

	testing.expect_value(t, tui.text_width("世界"), 4)
	testing.expect_value(t, tui.text_width(""), 0)
}

// --- input decoding ---------------------------------------------------------

@(test)
parse_plain_runes :: proc(t: ^testing.T) {
	ev, n, ok := tui.parse_input(transmute([]u8)string("a"))
	testing.expect(t, ok)
	testing.expect_value(t, n, 1)
	k := ev.(tui.Key)
	testing.expect_value(t, k.kind, tui.Key_Kind.Rune)
	testing.expect_value(t, k.r, 'a')
	testing.expect(t, !k.ctrl && !k.alt, "expected no modifiers")
}

@(test)
parse_utf8_rune :: proc(t: ^testing.T) {
	ev, n, ok := tui.parse_input(transmute([]u8)string("é"))
	testing.expect(t, ok)
	testing.expect_value(t, n, 2) // two bytes consumed, one key produced
	testing.expect_value(t, ev.(tui.Key).r, 'é')
}

@(test)
parse_incomplete_utf8_waits :: proc(t: ^testing.T) {
	// First byte of a two-byte sequence, nothing after it yet.
	_, _, ok := tui.parse_input([]u8{0xc3})
	testing.expect(t, !ok, "a partial rune must ask for more bytes, not guess")
}

@(test)
parse_c0_is_ctrl_letter :: proc(t: ^testing.T) {
	// 0x03 is what the terminal sends for Ctrl+C in raw mode.
	ev, n, ok := tui.parse_input([]u8{0x03})
	testing.expect(t, ok)
	testing.expect_value(t, n, 1)
	k := ev.(tui.Key)
	testing.expect_value(t, k.r, 'c')
	testing.expect(t, k.ctrl, "0x03 must decode as Ctrl+C")
}

@(test)
parse_named_keys :: proc(t: ^testing.T) {
	cases := []struct {
		bytes: string,
		kind:  tui.Key_Kind,
	} {
		{"\r", .Enter},
		{"\n", .Enter},
		{"\t", .Tab},
		{"\x7f", .Backspace},
		{" ", .Space},
		{"\x1b[A", .Up},
		{"\x1b[B", .Down},
		{"\x1b[C", .Right},
		{"\x1b[D", .Left},
		{"\x1b[H", .Home},
		{"\x1b[F", .End},
		{"\x1b[5~", .Page_Up},
		{"\x1b[6~", .Page_Down},
		{"\x1b[3~", .Delete},
		{"\x1b[Z", .Shift_Tab},
		{"\x1bOP", .F1},   // SS3
		{"\x1b[15~", .F5}, // CSI
	}
	for c in cases {
		ev, _, ok := tui.parse_input(transmute([]u8)c.bytes)
		testing.expectf(t, ok, "failed to parse %q", c.bytes)
		k, is_key := ev.(tui.Key)
		testing.expectf(t, is_key, "%q did not decode to a Key", c.bytes)
		testing.expectf(t, k.kind == c.kind, "%q -> %v, want %v", c.bytes, k.kind, c.kind)
	}
}

@(test)
parse_modified_arrow :: proc(t: ^testing.T) {
	// CSI 1;5A is Ctrl+Up.
	ev, _, ok := tui.parse_input(transmute([]u8)string("\x1b[1;5A"))
	testing.expect(t, ok)
	k := ev.(tui.Key)
	testing.expect_value(t, k.kind, tui.Key_Kind.Up)
	testing.expect(t, k.ctrl, "1;5 encodes Ctrl")
	testing.expect(t, !k.shift, "1;5 does not encode Shift")
}

@(test)
parse_alt_prefix :: proc(t: ^testing.T) {
	ev, n, ok := tui.parse_input(transmute([]u8)string("\x1bx"))
	testing.expect(t, ok)
	testing.expect_value(t, n, 2)
	k := ev.(tui.Key)
	testing.expect_value(t, k.r, 'x')
	testing.expect(t, k.alt, "ESC x is Alt+x")
}

@(test)
parse_lone_esc_is_incomplete :: proc(t: ^testing.T) {
	// A bare ESC is ambiguous until more bytes arrive or the timeout fires;
	// the parser must not guess. tui.run resolves it after two stalled frames.
	_, _, ok := tui.parse_input([]u8{0x1b})
	testing.expect(t, !ok, "a lone ESC must be reported incomplete")
}

@(test)
parse_sgr_mouse :: proc(t: ^testing.T) {
	// ESC [ < 0 ; 10 ; 5 M  — left press at column 10, row 5 (1-based on the wire).
	ev, _, ok := tui.parse_input(transmute([]u8)string("\x1b[<0;10;5M"))
	testing.expect(t, ok)
	m := ev.(tui.Mouse)
	testing.expect_value(t, m.kind, tui.Mouse_Kind.Press)
	testing.expect_value(t, m.x, 9) // zero-based
	testing.expect_value(t, m.y, 4)

	ev2, _, ok2 := tui.parse_input(transmute([]u8)string("\x1b[<64;1;1M"))
	testing.expect(t, ok2)
	testing.expect_value(t, ev2.(tui.Mouse).kind, tui.Mouse_Kind.Wheel_Up)
}

@(test)
key_name_round_trip :: proc(t: ^testing.T) {
	buf: [32]u8
	testing.expect_value(t, tui.key_name(tui.Key{kind = .Up}, buf[:]), "up")
	testing.expect_value(t, tui.key_name(tui.Key{kind = .Rune, r = 'a', ctrl = true}, buf[:]), "ctrl+a")
	testing.expect_value(t, tui.key_name(tui.Key{kind = .F12}, buf[:]), "f12")
}

// --- screen and the diffing renderer ----------------------------------------

@(test)
screen_clipping :: proc(t: ^testing.T) {
	s: tui.Screen
	tui.screen_init(&s, 10, 3)
	defer tui.screen_destroy(&s)

	// Out-of-bounds writes must be dropped, not wrap or crash.
	tui.set_cell(&s, -1, 0, 'x', {})
	tui.set_cell(&s, 99, 0, 'x', {})
	tui.set_cell(&s, 0, 99, 'x', {})
	tui.set_cell(&s, 0, 0, 'A', {})
	testing.expect_value(t, s.cur[0].r, 'A')
}

@(test)
draw_text_returns_columns :: proc(t: ^testing.T) {
	s: tui.Screen
	tui.screen_init(&s, 20, 2)
	defer tui.screen_destroy(&s)

	testing.expect_value(t, tui.draw_text(&s, 0, 0, "abc", {}), 3)
	// A wide glyph advances two columns and claims the cell to its right.
	testing.expect_value(t, tui.draw_text(&s, 0, 1, "世", {}), 2)
	testing.expect_value(t, s.cur[20].r, '世')
	testing.expect_value(t, s.cur[21].r, tui.WIDE_CONT)
}

@(test)
draw_text_clipped_ellipsis :: proc(t: ^testing.T) {
	s: tui.Screen
	tui.screen_init(&s, 20, 1)
	defer tui.screen_destroy(&s)

	// Fits: drawn whole, no ellipsis.
	testing.expect_value(t, tui.draw_text_clipped(&s, 0, 0, 10, "abc", {}), 3)
	testing.expect_value(t, s.cur[0].r, 'a')

	// Does not fit: truncated with an ellipsis, never wider than max_w.
	tui.screen_clear(&s)
	n := tui.draw_text_clipped(&s, 0, 0, 5, "abcdefghij", {})
	testing.expect(t, n <= 5, "clipped text must not exceed max_w")
	testing.expect_value(t, s.cur[4].r, '…')
}

@(test)
flush_emits_nothing_when_unchanged :: proc(t: ^testing.T) {
	s: tui.Screen
	tui.screen_init(&s, 20, 3)
	defer tui.screen_destroy(&s)

	tui.draw_text(&s, 0, 0, "hello", {})
	first := tui.flush(&s)
	testing.expect(t, len(first) > 0, "first paint must emit something")

	// Same frame again: the diff is empty. This is the property the whole
	// renderer exists for.
	tui.screen_clear(&s)
	tui.draw_text(&s, 0, 0, "hello", {})
	second := tui.flush(&s)
	testing.expect_value(t, len(second), 0)
}

@(test)
flush_emits_only_the_change :: proc(t: ^testing.T) {
	s: tui.Screen
	tui.screen_init(&s, 80, 24)
	defer tui.screen_destroy(&s)

	for y in 0 ..< 24 {
		tui.draw_text(&s, 0, y, "the quick brown fox jumps over the lazy dog", {})
	}
	full := len(tui.flush(&s))

	// Change one cell; the update must be a tiny fraction of a full repaint.
	tui.screen_clear(&s)
	for y in 0 ..< 24 {
		tui.draw_text(&s, 0, y, "the quick brown fox jumps over the lazy dog", {})
	}
	tui.set_cell(&s, 0, 0, 'X', {})
	delta := len(tui.flush(&s))

	testing.expect(t, delta > 0, "a changed cell must emit something")
	testing.expectf(t, delta < full / 10,
		"one-cell update was %d bytes vs %d for a full paint", delta, full)
}

@(test)
resize_forces_full_repaint :: proc(t: ^testing.T) {
	s: tui.Screen
	tui.screen_init(&s, 20, 3)
	defer tui.screen_destroy(&s)

	tui.draw_text(&s, 0, 0, "hello", {})
	tui.flush(&s)

	tui.screen_resize(&s, 30, 5)
	testing.expect_value(t, s.w, 30)
	testing.expect_value(t, s.h, 5)

	tui.draw_text(&s, 0, 0, "hello", {})
	out := tui.flush(&s)
	testing.expect(t, len(out) > 0, "a resize must repaint, not diff against the old size")
}

@(test)
style_helpers :: proc(t: ^testing.T) {
	base := tui.Style{}
	red := tui.with_fg(base, tui.rgb(255, 0, 0))
	testing.expect_value(t, red.fg.mode, tui.Color_Mode.True)
	testing.expect_value(t, red.fg.r, u8(255))
	// The original is untouched — these return copies.
	testing.expect_value(t, base.fg.mode, tui.Color_Mode.Default)

	bold := tui.with_attrs(base, {.Bold})
	testing.expect(t, .Bold in bold.attrs, "attr not set")
	testing.expect(t, .Bold not_in base.attrs, "original mutated")
}

// --- wide-glyph pairing -----------------------------------------------------
//
// `flush` walks the grid one index at a time while advancing the real terminal
// cursor by each rune's width. That only stays in step if every double-width
// lead is followed by exactly one continuation cell and every continuation has
// a lead. Overwriting half a wide glyph — a box border landing on a CJK label,
// say — used to break that and shift the rest of the row by a column, and
// because `prev` then recorded the wrong cells as painted, the corruption was
// permanent rather than fixed on the next frame.

@(test)
overwriting_right_half_of_wide_glyph :: proc(t: ^testing.T) {
	s: tui.Screen
	tui.screen_init(&s, 6, 1)
	defer tui.screen_destroy(&s)

	tui.set_cell(&s, 1, 0, '世', {}) // occupies 1 and 2
	testing.expect_value(t, s.cur[2].r, tui.WIDE_CONT)

	tui.set_cell(&s, 2, 0, 'a', {}) // lands on the continuation
	testing.expect(t, s.cur[1].r != '世', "the orphaned lead must be cleared")
	testing.expect_value(t, s.cur[1].r, ' ')
	testing.expect_value(t, s.cur[2].r, 'a')
}

@(test)
overwriting_left_half_of_wide_glyph :: proc(t: ^testing.T) {
	s: tui.Screen
	tui.screen_init(&s, 6, 1)
	defer tui.screen_destroy(&s)

	tui.set_cell(&s, 1, 0, '世', {})
	tui.set_cell(&s, 1, 0, 'a', {}) // lands on the lead
	testing.expect_value(t, s.cur[1].r, 'a')
	testing.expect(t, s.cur[2].r != tui.WIDE_CONT, "the orphaned continuation must be cleared")
	testing.expect_value(t, s.cur[2].r, ' ')
}

@(test)
no_orphans_survive_arbitrary_overdraw :: proc(t: ^testing.T) {
	// The invariant flush relies on, asserted over the kind of overlapping
	// drawing a real app does: a CJK label with a box and a fill over it.
	s: tui.Screen
	tui.screen_init(&s, 40, 3)
	defer tui.screen_destroy(&s)

	tui.draw_text(&s, 0, 1, "名前: 世界へようこそ", {})
	tui.fill_rect(&s, 5, 1, 8, 1, ' ', tui.Style{attrs = {.Reverse}})
	tui.draw_box(&s, 5, 0, 8, 3, {})

	for y in 0 ..< s.h {
		for x in 0 ..< s.w {
			c := s.cur[y * s.w + x]
			if c.r == tui.WIDE_CONT {
				testing.expectf(t, x > 0, "continuation at column 0 (%d,%d)", x, y)
				lead := s.cur[y * s.w + x - 1].r
				testing.expectf(t, tui.rune_width(lead) == 2,
					"continuation at (%d,%d) has no wide lead (found %v)", x, y, lead)
			}
			if tui.rune_width(c.r) == 2 {
				testing.expectf(t, x + 1 < s.w, "wide lead in the last column (%d,%d)", x, y)
				if x + 1 < s.w {
					testing.expectf(t, s.cur[y * s.w + x + 1].r == tui.WIDE_CONT,
						"wide lead at (%d,%d) lost its continuation", x, y)
				}
			}
		}
	}
}
