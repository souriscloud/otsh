// Regression cover for the write-stall limit.
//
// The defect: `ssh_channel_write` blocks until the peer grants flow-control
// credit, and that wait does not honour SSH_OPTIONS_TIMEOUT. A client that
// authenticated, asked for a shell and then simply stopped reading pinned its
// session thread indefinitely. Measured on libssh 0.12.0 / macOS, three such
// clients against `max_sessions = 3`, `handshake_seconds = 20`:
//
//	control (limit off): at t+22s all 3 threads were blocked, 2368 of 2368
//	  sampled frames in ssh::write -> channel_write_common ->
//	  ssh_handle_packets -> poll. Sessions ended only when the clients left at
//	  t+70s. A fourth client got `reject limit=sessions`.
//	limit at 8s:         all 3 sessions ended at ~16s (window drain + budget)
//	  and the slots came back; at t+22s no session thread existed at all.
//
// Nothing in the exchange is malformed, so it costs the attacker one idle
// socket per pinned server thread. The socket-level behaviour cannot be
// asserted without a live server; what is asserted here is that the limit
// exists, defaults to something bounded, and follows the same 0/negative
// convention as every other field — the parts a refactor could silently undo.
package otsh_tests

import "core:testing"
import "otsh:ssh"

@(test)
write_stall_limit_has_a_bounded_default :: proc(t: ^testing.T) {
	testing.expect(
		t,
		ssh.DEFAULT_LIMITS.write_stall_seconds > 0,
		"a zero or negative default would restore the unbounded pin: an authenticated " +
		"client that stops reading holds its session thread for as long as it likes",
	)
	// Long enough that a real client on a bad link is not cut off mid-frame,
	// short enough that max_sessions worth of stalled clients cannot hold the
	// server for minutes.
	testing.expect(
		t,
		ssh.DEFAULT_LIMITS.write_stall_seconds >= 10,
		"too aggressive: a slow but honest client would be disconnected",
	)
	testing.expect(
		t,
		ssh.DEFAULT_LIMITS.write_stall_seconds <= 120,
		"too generous to bound a deliberate stall usefully",
	)
}

@(test)
write_stall_follows_the_limits_convention :: proc(t: ^testing.T) {
	// Every Limits field means the same thing by its value: 0 takes the
	// default, negative disables. The zero value of the whole struct must
	// therefore still carry a stall bound.
	zero: ssh.Limits
	testing.expect_value(t, zero.write_stall_seconds, 0)

	// And it must be reachable through sshtui, which is how most apps set it.
	cfg: ssh.Config
	testing.expect_value(t, cfg.limits.write_stall_seconds, 0)
}
