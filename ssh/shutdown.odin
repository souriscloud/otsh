// Stopping a server without cutting anyone off mid-frame.
//
// A TUI over SSH has state on the far end that only the client can undo: the
// alternate screen, a hidden cursor, disabled autowrap. Killing the process
// leaves every connected user staring at a terminal that is still in that
// state, with no prompt and no cursor, until they work out that Ctrl+C or
// `reset` is what they need. `tui.run` already restores all of it on the way
// out — the whole problem is giving it the chance to run.
//
// So shutdown is cooperative rather than abrupt:
//
//  1. the accept loop stops taking new connections;
//  2. `draining` is set, so every session's next `read` reports the connection
//     as finished;
//  3. each app loop exits on its own, restores the terminal, and returns
//     through its Handler, which frees the session and releases its slot;
//  4. `serve` waits for the count to reach zero, then returns.
//
// A deadline bounds step 4, because an app is free to ignore its input and a
// server that will not stop is worse than one that stops rudely.
package ssh

import "core:fmt"
import "core:sync"
import "core:time"

// How long `serve` waits for connected sessions to finish once shutdown
// begins, when `Config.shutdown_seconds` is zero. Long enough for an app to
// notice its input has closed and paint one last frame, short enough not to
// hold up a service restart.
DEFAULT_SHUTDOWN_SECONDS :: 5

// Set by the signal handler, read by the accept loop.
//
// Package-level because a `proc "c"` signal handler receives nothing but the
// signal number: there is no way to hand it a Server pointer. That makes
// signal-driven shutdown process-wide, which is the right shape for it —
// SIGTERM means "this process is stopping", not "one of its listeners is".
// A process running two servers stops both, and `shutdown` remains the way to
// stop one of them on its own.
@(private)
signal_requested: bool

// True once a signal asked this process to stop. Useful to an app that wants
// to know why its loop is unwinding.
shutting_down :: proc "contextless" () -> bool {
	return sync.atomic_load(&signal_requested)
}

// Asks `srv` to stop: the accept loop exits, connected sessions are told their
// input has finished, and `serve` returns once they are gone or the deadline
// passes. Safe to call from any thread, including from inside a Handler.
shutdown :: proc(srv: ^Server) {
	if srv == nil {
		return
	}
	sync.atomic_store(&srv.running, false)
	sync.atomic_store(&srv.draining, true)
}

// What the platform handlers do, and all they may do.
//
// Everything a signal handler is allowed to touch is constrained to what is
// async-signal-safe, which rules out allocating, locking, and printing. A
// single atomic store is safe, and it is enough: the accept loop polls with a
// timeout, so it notices within that timeout without needing to be interrupted
// at all.
@(private)
request_stop :: proc "contextless" () {
	sync.atomic_store(&signal_requested, true)
}

// Waits for in-flight sessions to finish, up to `seconds`. Returns how many
// were still running when it gave up.
@(private)
drain_sessions :: proc(srv: ^Server, seconds: int) -> int {
	deadline := time.time_add(time.now(), time.Duration(seconds) * time.Second)
	for {
		sync.lock(&srv.limiter.mu)
		left := srv.limiter.total
		sync.unlock(&srv.limiter.mu)
		if left <= 0 {
			return 0
		}
		if time.diff(time.now(), deadline) <= 0 {
			return left
		}
		time.sleep(20 * time.Millisecond)
	}
}

// Prints what shutdown did. Separate from the mechanism so `serve` reads as a
// sequence of steps rather than a wall of formatting.
@(private)
report_shutdown :: proc(srv: ^Server, stragglers: int, seconds: int) {
	if stragglers == 0 {
		fmt.println("otsh: stopped; all sessions closed cleanly")
		return
	}
	fmt.eprintfln(
		"otsh: stopped with %d session(s) still running after %ds.\n" +
		"      Their terminals may be left in the alternate screen. An app whose\n" +
		"      update/view never returns cannot be waited for — check that yours\n" +
		"      exits when tui.run's loop ends, or raise Config.shutdown_seconds.",
		stragglers, seconds,
	)
}

@(private)
install_signal_handlers :: proc() {
	sync.atomic_store(&signal_requested, false)
	set_stop_handler()
}

// Restores whatever the process had before `install_signal_handlers`, so a
// caller that runs `serve` twice, or embeds it, is not left with handlers it
// did not ask for.
@(private)
restore_signal_handlers :: proc() {
	restore_stop_handler()
}
