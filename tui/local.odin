#+build !windows
// A Backend backed by the local terminal.
//
// Not needed to serve over SSH — it exists so the exact same App can be run
// with `otsh --local` during development, without opening a connection.
//
// This is the POSIX half. local_windows.odin declares the same four public
// names against the Windows console API; the two must stay signature-identical
// or an app that builds on one platform stops building on the other.
package tui

import "core:c"
import "core:sys/posix"

when ODIN_OS == .Darwin {
	foreign import libc_ "system:System"
} else {
	foreign import libc_ "system:c"
}

@(default_calling_convention = "c")
foreign libc_ {
	@(private)
	ioctl :: proc(fd: c.int, request: c.ulong, #c_vararg args: ..any) -> c.int ---
}

@(private)
TIOCGWINSZ :: 0x40087468 when ODIN_OS == .Darwin else 0x5413

@(private)
Winsize :: struct {
	ws_row, ws_col, ws_xpixel, ws_ypixel: u16,
}

// Saved terminal state for a local session, so raw mode can be undone. Zero
// value is fine; pass the same one to enter/exit/backend.
Local :: struct {
	orig:      posix.termios,
	have_orig: bool,
}

// A `Backend` over this process's own stdin/stdout.
local_backend :: proc(l: ^Local) -> Backend {
	return Backend {
		data = l,
		write = proc(data: rawptr, buf: []u8) -> int {
			if len(buf) == 0 {return 0}
			return int(posix.write(posix.STDOUT_FILENO, raw_data(buf), c.size_t(len(buf))))
		},
		poll = proc(data: rawptr, buf: []u8, timeout_ms: int) -> (n: int, ok: bool) {
			fds := [1]posix.pollfd{{fd = posix.STDIN_FILENO, events = {.IN}}}
			rc := posix.poll(&fds[0], 1, c.int(timeout_ms))
			if rc < 0 {return 0, false}
			if rc == 0 {return 0, true}
			got := posix.read(posix.STDIN_FILENO, raw_data(buf), c.size_t(len(buf)))
			if got <= 0 {return 0, false}
			return int(got), true
		},
		size = proc(data: rawptr) -> (cols, rows: int) {
			ws: Winsize
			if ioctl(c.int(posix.STDOUT_FILENO), TIOCGWINSZ, &ws) == 0 &&
			   ws.ws_col > 0 &&
			   ws.ws_row > 0 {
				return int(ws.ws_col), int(ws.ws_row)
			}
			return 80, 24
		},
	}
}

// Puts the terminal into raw mode: no line buffering, no echo, no signal
// generation from Ctrl+C. Over SSH the *client* does this for us, which is why
// the server side never needs termios at all.
local_enter_raw :: proc(l: ^Local) -> bool {
	if posix.tcgetattr(posix.STDIN_FILENO, &l.orig) != .OK {
		return false
	}
	l.have_orig = true

	raw := l.orig
	raw.c_iflag -= {.BRKINT, .ICRNL, .INPCK, .ISTRIP, .IXON}
	raw.c_oflag -= {.OPOST}
	raw.c_lflag -= {.ECHO, .ICANON, .IEXTEN, .ISIG}
	raw.c_cflag += {.CS8}
	raw.c_cc[.VMIN] = 0
	raw.c_cc[.VTIME] = 0

	return posix.tcsetattr(posix.STDIN_FILENO, .TCSAFLUSH, &raw) == .OK
}

// Restores the terminal settings saved by `local_enter_raw`. Safe to call twice;
// always `defer` it, or the user's shell is left in raw mode.
local_exit_raw :: proc(l: ^Local) {
	if l.have_orig {
		posix.tcsetattr(posix.STDIN_FILENO, .TCSAFLUSH, &l.orig)
		l.have_orig = false
	}
}
