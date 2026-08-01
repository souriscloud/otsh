// Terminal input decoding.
//
// A terminal delivers keys as a byte soup: printable UTF-8, C0 control codes,
// and escape sequences of several competing vintages (CSI, SS3, SGR mouse).
// This turns that back into events.
package tui

import "core:unicode/utf8"

// Which key was pressed. `.Rune` means an ordinary character, carried in
// `Key.r`; everything else is a named key with no rune.
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

// A keypress. Note that Ctrl+C arrives here rather than as a signal, because the
// client's terminal is in raw mode.
Key :: struct {
	kind:  Key_Kind,
	r:     rune, // valid when kind == .Rune
	ctrl:  bool,
	alt:   bool,
	shift: bool,
}

// What the mouse did. Wheel events carry no button.
Mouse_Kind :: enum u8 {
	Press,
	Release,
	Motion,
	Wheel_Up,
	Wheel_Down,
}

// A mouse event, in zero-based cell coordinates. Only delivered when
// `Program.mouse` was set before `run`.
Mouse :: struct {
	kind:   Mouse_Kind,
	button: int,
	x, y:   int, // zero-based cell coordinates
	ctrl:   bool,
	alt:    bool,
	shift:  bool,
}

// What `parse_input` decodes: either a key or a mouse event.
Input :: union {
	Key,
	Mouse,
}

// Decodes one event from the front of `buf`.
//
//	ok == false  -> incomplete sequence, wait for more bytes
//	n            -> bytes consumed
parse_input :: proc(buf: []u8) -> (ev: Input, n: int, ok: bool) {
	if len(buf) == 0 {
		return nil, 0, false
	}
	b := buf[0]

	if b == 0x1b {
		if len(buf) == 1 {
			return nil, 0, false // might be Esc, might be a sequence
		}
		switch buf[1] {
		case '[':
			return parse_csi(buf)
		case 'O':
			return parse_ss3(buf)
		case 0x1b:
			return Key{kind = .Esc}, 1, true
		case:
			// ESC <something> is Alt+<something>
			inner, m, inner_ok := parse_input(buf[1:])
			if !inner_ok {
				return nil, 0, false
			}
			if k, is_key := inner.(Key); is_key {
				k.alt = true
				return k, m + 1, true
			}
			return inner, m + 1, true
		}
	}

	switch {
	case b == 0x0d, b == 0x0a:
		return Key{kind = .Enter}, 1, true
	case b == 0x09:
		return Key{kind = .Tab}, 1, true
	case b == 0x7f, b == 0x08:
		return Key{kind = .Backspace}, 1, true
	case b == 0x00:
		return Key{kind = .Space, ctrl = true, r = ' '}, 1, true
	case b < 0x20:
		// C0 controls map back onto Ctrl+letter.
		return Key{kind = .Rune, r = rune('a' + b - 1), ctrl = true}, 1, true
	case b == 0x20:
		return Key{kind = .Space, r = ' '}, 1, true
	case b < 0x80:
		return Key{kind = .Rune, r = rune(b)}, 1, true
	}

	// Multi-byte UTF-8.
	need := utf8_len(b)
	if need == 0 {
		return Key{kind = .Rune, r = utf8.RUNE_ERROR}, 1, true // resync
	}
	if len(buf) < need {
		return nil, 0, false
	}
	r, sz := utf8.decode_rune(buf[:need])
	if sz == 0 {
		return Key{kind = .Rune, r = utf8.RUNE_ERROR}, 1, true
	}
	return Key{kind = .Rune, r = r}, sz, true
}

@(private)
utf8_len :: proc "contextless" (b: u8) -> int {
	switch {
	case b & 0xe0 == 0xc0:
		return 2
	case b & 0xf0 == 0xe0:
		return 3
	case b & 0xf8 == 0xf0:
		return 4
	}
	return 0
}

// CSI: ESC [ params intermediates final
@(private)
parse_csi :: proc(buf: []u8) -> (ev: Input, n: int, ok: bool) {
	// SGR mouse reporting is its own little grammar: ESC [ < b ; x ; y M|m
	if len(buf) >= 3 && buf[2] == '<' {
		return parse_sgr_mouse(buf)
	}

	params: [8]int
	nparams := 0
	has_param := false
	i := 2
	for i < len(buf) {
		c := buf[i]
		switch {
		case c >= '0' && c <= '9':
			if nparams < len(params) {
				params[nparams] = params[nparams] * 10 + int(c - '0')
				has_param = true
			}
			i += 1
		case c == ';':
			if nparams < len(params) - 1 {nparams += 1}
			i += 1
		case c >= 0x40 && c <= 0x7e:
			if has_param {nparams += 1}
			return csi_key(c, params[:nparams]), i + 1, true
		case:
			i += 1 // private markers and intermediates
		}
	}
	return nil, 0, false
}

@(private)
apply_mods :: proc "contextless" (k: Key, mod: int) -> Key {
	k := k
	if mod <= 1 {
		return k
	}
	m := mod - 1
	k.shift = m & 1 != 0
	k.alt = m & 2 != 0
	k.ctrl = m & 4 != 0
	return k
}

@(private)
csi_key :: proc(final: u8, params: []int) -> Input {
	mod := len(params) >= 2 ? params[1] : 0
	k := Key{}
	switch final {
	case 'A':
		k.kind = .Up
	case 'B':
		k.kind = .Down
	case 'C':
		k.kind = .Right
	case 'D':
		k.kind = .Left
	case 'H':
		k.kind = .Home
	case 'F':
		k.kind = .End
	case 'Z':
		return Key{kind = .Shift_Tab, shift = true}
	case '~':
		code := len(params) >= 1 ? params[0] : 0
		switch code {
		case 1, 7:
			k.kind = .Home
		case 2:
			k.kind = .Insert
		case 3:
			k.kind = .Delete
		case 4, 8:
			k.kind = .End
		case 5:
			k.kind = .Page_Up
		case 6:
			k.kind = .Page_Down
		case 11:
			k.kind = .F1
		case 12:
			k.kind = .F2
		case 13:
			k.kind = .F3
		case 14:
			k.kind = .F4
		case 15:
			k.kind = .F5
		case 17:
			k.kind = .F6
		case 18:
			k.kind = .F7
		case 19:
			k.kind = .F8
		case 20:
			k.kind = .F9
		case 21:
			k.kind = .F10
		case 23:
			k.kind = .F11
		case 24:
			k.kind = .F12
		case:
			k.kind = .None
		}
	case:
		k.kind = .None
	}
	return apply_mods(k, mod)
}

// SS3: ESC O <final> — used by some terminals for arrows in application mode
// and for F1–F4 nearly everywhere.
@(private)
parse_ss3 :: proc(buf: []u8) -> (ev: Input, n: int, ok: bool) {
	if len(buf) < 3 {
		return nil, 0, false
	}
	k := Key{}
	switch buf[2] {
	case 'A':
		k.kind = .Up
	case 'B':
		k.kind = .Down
	case 'C':
		k.kind = .Right
	case 'D':
		k.kind = .Left
	case 'H':
		k.kind = .Home
	case 'F':
		k.kind = .End
	case 'P':
		k.kind = .F1
	case 'Q':
		k.kind = .F2
	case 'R':
		k.kind = .F3
	case 'S':
		k.kind = .F4
	case:
		k.kind = .None
	}
	return k, 3, true
}

// ESC [ < button ; col ; row (M=press, m=release)
@(private)
parse_sgr_mouse :: proc(buf: []u8) -> (ev: Input, n: int, ok: bool) {
	vals: [3]int
	vi := 0
	i := 3
	for i < len(buf) {
		c := buf[i]
		switch {
		case c >= '0' && c <= '9':
			if vi < 3 {vals[vi] = vals[vi] * 10 + int(c - '0')}
			i += 1
		case c == ';':
			vi += 1
			i += 1
		case c == 'M' || c == 'm':
			btn := vals[0]
			// The wire values are attacker-controlled and accumulate without a
			// digit cap, so they can arrive absurd or wrapped. Clamp to the
			// largest screen this package will ever allocate — all that can be
			// done here, since `parse_input` is not told the screen size.
			//
			// That bound is the package maximum, NOT the caller's geometry: these
			// numbers come off the wire rather than from the client's real
			// terminal, so this still admits (998, 298) on an 80x24 session.
			// `run` narrows them to the live screen before any app sees them; a
			// caller driving `parse_input` itself must do the same.
			m := Mouse {
				x     = clamp(vals[1] - 1, 0, MAX_COLS - 1),
				y     = clamp(vals[2] - 1, 0, MAX_ROWS - 1),
				shift = btn & 4 != 0,
				alt   = btn & 8 != 0,
				ctrl  = btn & 16 != 0,
			}
			switch {
			case btn & 64 != 0:
				m.kind = btn & 1 != 0 ? .Wheel_Down : .Wheel_Up
			case btn & 32 != 0:
				m.kind = .Motion
				m.button = btn & 3
			case c == 'm':
				m.kind = .Release
				m.button = btn & 3
			case:
				m.kind = .Press
				m.button = btn & 3
			}
			return m, i + 1, true
		case:
			return nil, i + 1, true // malformed; skip it
		}
	}
	return nil, 0, false
}

// Human-readable name, handy for help bars and debugging.
key_name :: proc(k: Key, buf: []u8) -> string {
	n := 0
	put :: proc(buf: []u8, n: ^int, s: string) {
		for i in 0 ..< len(s) {
			if n^ < len(buf) {
				buf[n^] = s[i]
				n^ += 1
			}
		}
	}
	if k.ctrl {put(buf, &n, "ctrl+")}
	if k.alt {put(buf, &n, "alt+")}
	if k.shift && k.kind != .Shift_Tab {put(buf, &n, "shift+")}

	switch k.kind {
	case .Rune:
		bytes, sz := utf8.encode_rune(k.r)
		put(buf, &n, string(bytes[:sz]))
	case .None:
		put(buf, &n, "unknown")
	case .Enter:
		put(buf, &n, "enter")
	case .Tab:
		put(buf, &n, "tab")
	case .Shift_Tab:
		put(buf, &n, "shift+tab")
	case .Backspace:
		put(buf, &n, "backspace")
	case .Esc:
		put(buf, &n, "esc")
	case .Space:
		put(buf, &n, "space")
	case .Delete:
		put(buf, &n, "delete")
	case .Insert:
		put(buf, &n, "insert")
	case .Up:
		put(buf, &n, "up")
	case .Down:
		put(buf, &n, "down")
	case .Left:
		put(buf, &n, "left")
	case .Right:
		put(buf, &n, "right")
	case .Home:
		put(buf, &n, "home")
	case .End:
		put(buf, &n, "end")
	case .Page_Up:
		put(buf, &n, "pgup")
	case .Page_Down:
		put(buf, &n, "pgdn")
	case .F1 ..= .F12:
		put(buf, &n, "f")
		d := int(k.kind) - int(Key_Kind.F1) + 1
		if d >= 10 {
			put(buf, &n, "1")
			d -= 10
		}
		if n < len(buf) {
			buf[n] = u8('0' + d)
			n += 1
		}
	}
	return string(buf[:n])
}
