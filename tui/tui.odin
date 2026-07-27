// The runtime: an Elm-style update/view loop driven by an abstract byte
// backend. The app never learns whether it is talking to a local terminal or
// to an SSH channel — that is the whole point.
package tui

import "core:time"

// A source of terminal bytes and a sink for them.
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

// Sent when the terminal geometry changes. The screen buffer has already been
// resized by the time your `update` sees this.
Resize :: struct {
	cols, rows: int,
}

// Sent once per frame. Drive animation off `dt` (real seconds since the previous
// tick), never off `frame` — see docs/cookbook.md.
Tick :: struct {
	dt:    f64, // seconds since the previous tick
	total: f64,
	frame: u64,
}

// Everything `update` can receive.
Msg :: union {
	Key,
	Mouse,
	Resize,
	Tick,
}

// Your application: a model pointer plus up to three callbacks. `init` is
// optional; `update` handles messages, `view` paints a complete frame.
App :: struct {
	data:   rawptr,
	init:   proc(p: ^Program),
	update: proc(p: ^Program, msg: Msg),
	view:   proc(p: ^Program, s: ^Screen),
}

// One running app: its backend, its screen, and the loop's own bookkeeping.
// Set `fps` and `mouse` before `run`; read `frame`, `elapsed`, `bytes_out` and
// `bytes_in` any time.
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

// Ends the loop after the current tick, before the next frame is drawn.
quit :: proc(p: ^Program) {
	p.quit = true
}

@(private)
emit :: proc(p: ^Program, s: string) {
	if p.backend.write != nil {
		p.backend.write(p.backend.data, transmute([]u8)s)
	}
}

// Runs `app` until it quits or the connection drops. Sets up the alternate
// screen, hides the cursor, disables autowrap, and restores all of it on exit.
// Blocks for the lifetime of the app.
run :: proc(p: ^Program, app: App) {
	p.app = app
	if p.fps <= 0 {p.fps = 30}
	p.pending = make([dynamic]u8, 0, 256)
	defer delete(p.pending)

	// Enter the alternate screen so the user's scrollback survives, hide the
	// cursor, and turn off autowrap so writing the bottom-right cell does not
	// scroll the view.
	emit(p, "\x1b[?1049h\x1b[?25l\x1b[?7l\x1b[2J")
	if p.mouse {
		emit(p, "\x1b[?1000h\x1b[?1002h\x1b[?1006h")
	}
	defer {
		if p.mouse {
			emit(p, "\x1b[?1006l\x1b[?1002l\x1b[?1000l")
		}
		emit(p, "\x1b[?7h\x1b[?25h\x1b[0m\x1b[?1049l")
	}

	cols, rows := p.backend.size(p.backend.data)
	screen_init(&p.screen, cols, rows)
	defer screen_destroy(&p.screen)

	if app.init != nil {
		app.init(p)
	}

	budget := time.Duration(int(time.Second) / p.fps)
	last := time.tick_now()

	for !p.quit {
		frame_start := time.tick_now()

		n, ok := p.backend.poll(p.backend.data, p.read_buf[:], int(budget / time.Millisecond))
		if !ok {
			break
		}
		if n > 0 {
			p.bytes_in += u64(n)
			append(&p.pending, ..p.read_buf[:n])
			p.stalls = 0
		} else if len(p.pending) > 0 {
			p.stalls += 1
		}

		dispatch_input(p)

		nc, nr := p.backend.size(p.backend.data)
		if nc != p.screen.w || nr != p.screen.h {
			screen_resize(&p.screen, nc, nr)
			send(p, Resize{nc, nr})
		}

		now := time.tick_now()
		dt := time.duration_seconds(time.tick_diff(last, now))
		last = now
		p.elapsed += dt
		p.frame += 1
		send(p, Tick{dt = dt, total = p.elapsed, frame = p.frame})

		if p.quit {
			break
		}

		screen_clear(&p.screen)
		if app.view != nil {
			app.view(p, &p.screen)
		}
		out := flush(&p.screen)
		if len(out) > 0 {
			p.bytes_out += u64(len(out))
			p.backend.write(p.backend.data, out)
		}

		// A backend whose poll returns early must not turn this into a spin
		// loop. If the frame came in under budget, sleep the difference.
		if spent := time.tick_since(frame_start); spent < budget {
			time.sleep(budget - spent)
		}
	}
}

@(private)
send :: proc(p: ^Program, msg: Msg) {
	if p.app.update != nil {
		p.app.update(p, msg)
	}
}

// The longest input sequence worth waiting to complete. Real ones are a
// handful of bytes; the longest this parser recognises is well under 32.
//
// Without a cap here, a client that sends "ESC [" followed by an endless run of
// digits and never a final byte parks the parser: nothing is consumable, so
// nothing is removed, `pending` grows forever, and `parse_csi` rescans all of it
// every frame — one connection reaching >100% CPU on trivial bandwidth. The
// stall timeout below does not save us, because it only fires when input
// *pauses*, and a slow trickle keeps resetting it.
@(private)
MAX_INCOMPLETE :: 256

@(private)
dispatch_input :: proc(p: ^Program) {
	for len(p.pending) > 0 {
		ev, n, ok := parse_input(p.pending[:])
		if !ok {
			// An incomplete sequence. A lone ESC that stays lone for two
			// frames is just the Escape key — this is the classic terminal
			// ambiguity, resolved the classic way, with a timeout.
			if p.stalls >= 2 {
				if p.pending[0] == 0x1b {
					send(p, Key{kind = .Esc})
				}
				ordered_remove(&p.pending, 0)
				p.stalls = 0
				continue
			}
			// Too long to be a real sequence: this is garbage or an attack.
			// Drop the leading byte and resync rather than buffering forever.
			if len(p.pending) > MAX_INCOMPLETE {
				ordered_remove(&p.pending, 0)
				continue
			}
			return
		}
		if n <= 0 {
			ordered_remove(&p.pending, 0)
			continue
		}
		remove_front(&p.pending, n)
		switch e in ev {
		case Key:
			send(p, e)
		case Mouse:
			send(p, e)
		}
		if p.quit {
			return
		}
	}
}

@(private)
remove_front :: proc(arr: ^[dynamic]u8, n: int) {
	if n >= len(arr) {
		clear(arr)
		return
	}
	copy(arr[:], arr[n:])
	resize(arr, len(arr) - n)
}
