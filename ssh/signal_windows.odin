#+build windows
// Installing and restoring the stop handler. Windows half; signal_posix.odin
// declares the same two against sigaction.
//
// Windows has no SIGTERM worth the name. The console control handler is the
// equivalent: it fires for Ctrl+C, Ctrl+Break, and for the close/logoff/
// shutdown events a closed console window or a service manager produces.
//
// Returning TRUE does not mean the same thing for all five, and the difference
// is what decides whether anyone gets a clean shutdown. For Ctrl+C and
// Ctrl+Break it means "handled": the default killer is suppressed, and the
// accept loop is left to wind down in its own time. For the other three there
// is nothing to suppress — MSDN's HandlerRoutine page says of a close, logoff
// or shutdown event: "Return TRUE. In this case, no other handler functions are
// called and the system terminates the process." The process dies the instant
// the handler returns, so returning straight away would skip the cooperative
// drain in shutdown.odin and leave every connected client's terminal sitting in
// the alternate screen — the one thing this whole package tries to avoid.
//
// So for those three the handler asks for the stop and then blocks until
// `serve` reports the drain finished. Blocking is legal precisely here: the
// system runs the handler on a thread it created for it, not on the accept
// loop. The wait is bounded, because the OS only lends so much time before
// killing the process anyway — around 5000 ms for a close (the
// SPI_GETHUNGAPPTIMEOUT value), 5000 to 20000 for logoff and shutdown — and a
// bounded wait that loses that race ends no worse than not waiting at all.
//
// https://learn.microsoft.com/en-us/windows/console/handlerroutine
//
// Verified on real Windows 11 hardware on 2026-07-31: Ctrl+C at the server
// console drained the server and restored a connected client's terminal. The
// close/logoff/shutdown path has NOT been run — it is modelled on the documented
// contract quoted above.
package ssh

import "core:sync"
import win "core:sys/windows"

@(private)
handlers_installed: bool

// How long the close-type events will wait for the drain, and how often they
// look. Comfortably under the ~5000 ms the OS grants before it terminates the
// process regardless; the margin absorbs the scheduling slop of getting here.
// A `Config.shutdown_seconds` at or above the 5 s default can therefore outlast
// this wait — the OS budget binds, not ours, and stopping late is not an option
// the handler has.
@(private)
CLOSE_WAIT_MS :: 4500
@(private)
CLOSE_POLL_MS :: 50

@(private)
console_handler :: proc "system" (ctrl_type: win.DWORD) -> win.BOOL {
	switch ctrl_type {
	case win.CTRL_C_EVENT, win.CTRL_BREAK_EVENT:
		// No timeout and no automatic termination on these two: setting the flag
		// is enough, and the accept loop notices within one poll.
		request_stop()
		return win.TRUE
	case win.CTRL_CLOSE_EVENT, win.CTRL_LOGOFF_EVENT, win.CTRL_SHUTDOWN_EVENT:
		// Returning here *is* the process exiting, so hold this thread until
		// `serve` has given the sessions their chance, or until the budget runs
		// out — whichever comes first.
		request_stop()
		waited := 0
		for waited < CLOSE_WAIT_MS && !sync.atomic_load(&stop_complete) {
			win.Sleep(CLOSE_POLL_MS)
			waited += CLOSE_POLL_MS
		}
		return win.TRUE
	}
	return win.FALSE
}

@(private)
set_stop_handler :: proc() {
	win.SetConsoleCtrlHandler(console_handler, win.TRUE)
	handlers_installed = true
}

@(private)
restore_stop_handler :: proc() {
	if !handlers_installed {
		return
	}
	win.SetConsoleCtrlHandler(console_handler, win.FALSE)
	handlers_installed = false
}
