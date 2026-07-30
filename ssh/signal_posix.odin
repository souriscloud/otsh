#+build !windows
// Installing and restoring the SIGINT/SIGTERM handlers. POSIX half;
// signal_windows.odin declares the same two against the console control API.
package ssh

import "core:sys/posix"

// What SIGINT and SIGTERM did before we touched them, so it can be put back.
@(private)
prev_int, prev_term: posix.sigaction_t
@(private)
handlers_installed: bool

@(private)
stop_handler :: proc "c" (sig: posix.Signal) {
	request_stop()
}

@(private)
set_stop_handler :: proc() {
	act: posix.sigaction_t
	act.sa_handler = stop_handler
	// No signals blocked while it runs, and deliberately no SA_RESTART: the
	// accept loop polls with a timeout and re-checks the flag either way, so
	// an interrupted syscall is expected rather than a problem.
	posix.sigemptyset(&act.sa_mask)
	act.sa_flags = {}

	posix.sigaction(.SIGINT, &act, &prev_int)
	posix.sigaction(.SIGTERM, &act, &prev_term)
	handlers_installed = true
}

@(private)
restore_stop_handler :: proc() {
	if !handlers_installed {
		return
	}
	posix.sigaction(.SIGINT, &prev_int, nil)
	posix.sigaction(.SIGTERM, &prev_term, nil)
	handlers_installed = false
}
