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
// Verified on real Windows 11 hardware (Pro 10.0.26200, 2026-07-31 and
// 2026-08-01):
//
//   - Ctrl+C at the server console drained the server and restored a
//     connected client's terminal (2026-07-31, by hand; re-run 2026-08-01
//     with GenerateConsoleCtrlEvent after fixing the inherited-flag bug
//     documented at set_stop_handler below).
//   - CTRL_CLOSE_EVENT, delivered by posting WM_CLOSE to the server's real
//     console window: the connected client received the full restore
//     sequence (?7h ?25h SGR reset ?1049l, mouse reporting off) before the
//     connection closed, and the process exited 255 ms after the close —
//     "otsh: stopped; all sessions closed cleanly". The OS grace period was
//     measured on the same machine with a handler that never returns: it was
//     killed between 4980 and 5018 ms, so the documented ~5000 ms holds and
//     CLOSE_WAIT_MS below keeps ~500 ms of margin.
//
// CTRL_LOGOFF_EVENT and CTRL_SHUTDOWN_EVENT have still NEVER executed: testing
// them means logging out or rebooting the machine, which was not safe to do on
// the hardware available. Their handling is modelled on the documented
// contract quoted above, no more.
package ssh

import "core:sync"
import win "core:sys/windows"

@(private)
handlers_installed: bool

// How long the close-type events will wait for the drain, and how often they
// look. Comfortably under the ~5000 ms the OS grants before it terminates the
// process regardless; the margin absorbs the scheduling slop of getting here.
// The 5000 is not folklore: measured for CTRL_CLOSE_EVENT on Windows 11 Pro
// 10.0.26200 (2026-08-01) with a handler that never returns, the process was
// terminated between 4980 and 5018 ms after the event.
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
	// Installing the handler is not enough for Ctrl+C. A process whose
	// ancestor was created with CREATE_NEW_PROCESS_GROUP — PowerShell's
	// Start-Process, cmd's `start`, most service wrappers — inherits an
	// "ignore Ctrl+C" flag, and that flag gates CTRL_C_EVENT delivery before
	// the handler list is ever consulted. Found on real Windows 11 hardware
	// on 2026-08-01: a tracker launched via Start-Process ignored Ctrl+C
	// entirely — it neither drained nor died — while the same binary launched
	// by hand stopped cleanly. Passing nil/FALSE clears the flag and restores
	// normal Ctrl+C processing for this process.
	//
	// restore_stop_handler cannot undo this: there is no getter for the flag,
	// so its prior state is unknowable. Leaving Ctrl+C enabled errs on the
	// side of a process that can be stopped.
	win.SetConsoleCtrlHandler(nil, win.FALSE)
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
