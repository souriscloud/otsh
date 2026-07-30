#+build windows
// Installing and restoring the stop handler. Windows half; signal_posix.odin
// declares the same two against sigaction.
//
// Windows has no SIGTERM worth the name. The console control handler is the
// equivalent: it fires for Ctrl+C, Ctrl+Break, and for the close/logoff/
// shutdown events a service manager produces. Returning TRUE means "handled",
// which suppresses the default behaviour of killing the process outright and
// lets the accept loop wind down instead.
//
// EXPERIMENTAL, like the rest of the Windows port: this compiles and is
// modelled on the documented API, but has never run on Windows.
package ssh

import win "core:sys/windows"

@(private)
handlers_installed: bool

@(private)
console_handler :: proc "system" (ctrl_type: win.DWORD) -> win.BOOL {
	switch ctrl_type {
	case win.CTRL_C_EVENT, win.CTRL_BREAK_EVENT, win.CTRL_CLOSE_EVENT,
	     win.CTRL_LOGOFF_EVENT, win.CTRL_SHUTDOWN_EVENT:
		request_stop()
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
