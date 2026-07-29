#+build windows
// The Windows half of the local Backend. See local.odin for the POSIX half and
// for what this is for; the four public names here are the same four, with the
// same signatures, so an app that builds on one platform builds on the other.
//
// EXPERIMENTAL. This file is type-checked for windows_amd64 and built by CI on
// windows-latest, and that is the whole of its validation — nobody has run it
// on a real Windows console. Accepted caveats are commented at each site and
// summarised in docs/getting-started.md.
package tui

import win32 "core:sys/windows"

// Saved terminal state for a local session, so raw mode can be undone. Zero
// value is fine; pass the same one to enter/exit/backend.
Local :: struct {
	stdin:         win32.HANDLE,
	stdout:        win32.HANDLE,
	orig_in_mode:  win32.DWORD,
	orig_out_mode: win32.DWORD,
	orig_cp:       win32.CODEPAGE,
	orig_out_cp:   win32.CODEPAGE,
	have_orig:     bool,
}

// The POSIX half names stdin and stdout by constant descriptor, so it needs no
// setup. Here they are handles that have to be fetched, and a zero-valued Local
// has none — so every entry point fetches them first. Re-fetching is cheap and
// a process with no console legitimately gets a null handle back, which is why
// this does not cache "already tried".
@(private)
local_handles :: proc "contextless" (l: ^Local) {
	if l.stdin == nil {
		l.stdin = win32.GetStdHandle(win32.STD_INPUT_HANDLE)
	}
	if l.stdout == nil {
		l.stdout = win32.GetStdHandle(win32.STD_OUTPUT_HANDLE)
	}
}

// A `Backend` over this process's own stdin/stdout.
local_backend :: proc(l: ^Local) -> Backend {
	local_handles(l)
	return Backend {
		data = l,
		write = proc(data: rawptr, buf: []u8) -> int {
			l := (^Local)(data)
			if len(buf) == 0 {return 0}
			n: win32.DWORD
			if !win32.WriteFile(l.stdout, raw_data(buf), win32.DWORD(len(buf)), &n, nil) {
				return 0
			}
			return int(n)
		},
		poll = proc(data: rawptr, buf: []u8, timeout_ms: int) -> (n: int, ok: bool) {
			l := (^Local)(data)
			if len(buf) == 0 {return 0, true}

			// Negative means "wait forever" for poll(2); INFINITE is the same
			// contract here. Nothing in tui asks for it, but the two halves must
			// not disagree about what a negative timeout means.
			ms := timeout_ms < 0 ? win32.INFINITE : win32.DWORD(timeout_ms)
			switch win32.WaitForSingleObject(l.stdin, ms) {
			case win32.WAIT_OBJECT_0:
			// readable, fall through
			case win32.WAIT_TIMEOUT:
				return 0, true
			case:
				return 0, false // handle closed or invalid: the session is over
			}

			if !drain_untranslatable(l.stdin) {
				return 0, true
			}
			got: win32.DWORD
			if !win32.ReadFile(l.stdin, raw_data(buf), win32.DWORD(len(buf)), &got, nil) {
				return 0, false
			}
			if got == 0 {return 0, false}
			return int(got), true
		},
		size = proc(data: rawptr) -> (cols, rows: int) {
			l := (^Local)(data)
			info: win32.CONSOLE_SCREEN_BUFFER_INFO
			if win32.GetConsoleScreenBufferInfo(l.stdout, &info) {
				// srWindow, not dwSize: dwSize is the whole scrollback buffer,
				// which is taller than the visible window and would put every row
				// tui draws in the wrong place.
				c := int(info.srWindow.Right) - int(info.srWindow.Left) + 1
				r := int(info.srWindow.Bottom) - int(info.srWindow.Top) + 1
				if c > 0 && r > 0 {
					return c, r
				}
			}
			return 80, 24
		},
	}
}

// WaitForSingleObject signals as soon as *any* record is queued on a console
// input handle, but ReadFile in virtual-terminal-input mode only returns once it
// has bytes to give. A wake carrying nothing but key-up or focus records would
// therefore leave ReadFile blocking well past the caller's timeout, stalling the
// frame loop — so those records are consumed here instead and the poll reports
// "nothing typed", which is what a POSIX poll timeout reports too.
//
// Returns true when the record at the head of the queue is one ReadFile can turn
// into bytes.
//
// Residual caveat, accepted: a key-down that produces no VT sequence and is not
// a plain modifier — a dead key, an IME composition — still reaches ReadFile and
// can block it until the next real keystroke. That costs late frames, not input.
@(private)
drain_untranslatable :: proc(h: win32.HANDLE) -> bool {
	for {
		avail: win32.DWORD
		if !win32.GetNumberOfConsoleInputEvents(h, &avail) {
			// Not a console — stdin redirected from a pipe or a file. There is no
			// record queue to filter and ReadFile reads the ready bytes directly.
			return true
		}
		if avail == 0 {
			return false
		}
		rec: win32.INPUT_RECORD
		count: win32.DWORD
		if !win32.PeekConsoleInputW(h, &rec, 1, &count) || count == 0 {
			return false
		}
		if translates_to_bytes(rec) {
			return true
		}
		if !win32.ReadConsoleInputW(h, &rec, 1, &count) {
			return false
		}
	}
}

@(private)
translates_to_bytes :: proc "contextless" (rec: win32.INPUT_RECORD) -> bool {
	if rec.EventType != .KEY_EVENT {
		return false
	}
	k := rec.Event.KeyEvent
	if !bool(k.bKeyDown) {
		return false
	}
	// A modifier pressed on its own emits no escape sequence; it only shows up in
	// dwControlKeyState on the next real key.
	switch k.wVirtualKeyCode {
	case win32.VK_SHIFT, win32.VK_CONTROL, win32.VK_MENU, win32.VK_CAPITAL,
	     win32.VK_NUMLOCK, win32.VK_SCROLL, win32.VK_LWIN, win32.VK_RWIN:
		return false
	}
	return true
}

// Puts the terminal into raw mode: no line buffering, no echo, no signal
// generation from Ctrl+C. Over SSH the *client* does this for us, which is why
// the server side never needs any of this.
local_enter_raw :: proc(l: ^Local) -> bool {
	local_handles(l)

	in_mode, out_mode: win32.DWORD
	if !win32.GetConsoleMode(l.stdin, &in_mode) || !win32.GetConsoleMode(l.stdout, &out_mode) {
		return false // not a console
	}
	l.orig_in_mode = in_mode
	l.orig_out_mode = out_mode
	l.orig_cp = win32.GetConsoleCP()
	l.orig_out_cp = win32.GetConsoleOutputCP()
	l.have_orig = true

	// ENABLE_VIRTUAL_TERMINAL_INPUT is the point of the whole file: with it the
	// console host hands us the same escape sequences an xterm sends, so key.odin
	// decodes both platforms with one parser instead of two.
	raw_in := in_mode
	raw_in &~= win32.ENABLE_LINE_INPUT | win32.ENABLE_ECHO_INPUT | win32.ENABLE_PROCESSED_INPUT
	// Mouse and window-size records would wake the poll without producing bytes,
	// and neither is needed: geometry is re-read from srWindow every frame, and
	// mouse reporting is not supported on this backend (see getting-started.md).
	raw_in &~= win32.ENABLE_MOUSE_INPUT | win32.ENABLE_WINDOW_INPUT
	raw_in |= win32.ENABLE_VIRTUAL_TERMINAL_INPUT
	if !win32.SetConsoleMode(l.stdin, raw_in) {
		l.have_orig = false
		return false
	}

	// Without VIRTUAL_TERMINAL_PROCESSING every escape tui writes is printed as
	// literal text. Restore the input mode first if this half fails, or the
	// console is left uncooked with nothing able to draw on it.
	if !win32.SetConsoleMode(
		l.stdout,
		out_mode | win32.ENABLE_PROCESSED_OUTPUT | win32.ENABLE_VIRTUAL_TERMINAL_PROCESSING,
	) {
		win32.SetConsoleMode(l.stdin, in_mode)
		l.have_orig = false
		return false
	}

	// Screen content is UTF-8 and the code page decides how the console decodes
	// the bytes we write. The originals are saved above and put back on exit,
	// because this setting outlives the process in the parent shell.
	win32.SetConsoleCP(.UTF8)
	win32.SetConsoleOutputCP(.UTF8)
	return true
}

// Restores the terminal settings saved by `local_enter_raw`. Safe to call twice;
// always `defer` it, or the user's shell is left in raw mode.
local_exit_raw :: proc(l: ^Local) {
	if !l.have_orig {
		return
	}
	win32.SetConsoleMode(l.stdin, l.orig_in_mode)
	win32.SetConsoleMode(l.stdout, l.orig_out_mode)
	win32.SetConsoleCP(l.orig_cp)
	win32.SetConsoleOutputCP(l.orig_out_cp)
	l.have_orig = false
}
