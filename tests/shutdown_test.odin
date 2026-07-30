// Tests for graceful shutdown's pure logic. Nothing here opens a socket; the
// end-to-end behaviour (a real client's terminal being restored when the
// server is signalled) is exercised by hand — see docs/ssh.md, "Shutdown".
package otsh_tests

import "core:testing"
import "otsh:ssh"
import "otsh:sshtui"

@(test)
shutdown_defaults_are_sane :: proc(t: ^testing.T) {
	// The wait has to be long enough for an app to notice its input closed and
	// paint a final frame, and short enough that a service restart is not held
	// up. Measured shutdown with live sessions is ~0.55s, well inside this.
	testing.expect(t, ssh.DEFAULT_SHUTDOWN_SECONDS > 0, "expected a positive drain window")
	testing.expect(t, ssh.DEFAULT_SHUTDOWN_SECONDS <= 30, "drain window should not stall a restart")
}

@(test)
shutdown_zero_config_opts_in :: proc(t: ^testing.T) {
	// The zero value must mean "handle signals, wait the default" — a server
	// that ignores SIGTERM by default would strand every connected terminal on
	// the first `systemctl restart`.
	cfg: ssh.Config
	testing.expect(t, !cfg.no_signal_handlers, "signal handling must be on by default")
	testing.expect_value(t, cfg.shutdown_seconds, 0) // 0 resolves to the default

	tcfg: sshtui.Config
	testing.expect(t, !tcfg.no_signal_handlers, "sshtui must inherit the same default")
	testing.expect_value(t, tcfg.shutdown_seconds, 0)
}

@(test)
shutdown_flag_starts_clear :: proc(t: ^testing.T) {
	// Nothing has signalled this test process, so the flag every session reads
	// to decide whether to wind down must be false.
	testing.expect(t, !ssh.shutting_down(), "shutdown flag must start clear")
}

@(test)
shutdown_is_safe_on_nil :: proc(t: ^testing.T) {
	// shutdown() is reachable from application code, including from a Handler
	// during teardown. A nil server must be a no-op rather than a crash.
	ssh.shutdown(nil)
}
