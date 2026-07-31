// Tests for the input path's socket-free contracts.
//
// The large-paste defect itself — a 1 MiB paste stranding bytes in libssh's
// channel buffer and deafening the session — cannot be reproduced without a
// live SSH peer, so its regression test is the end-to-end paste harness
// described in docs/architecture.md ("Input flow"), not a unit test here.
// What can be pinned down without a socket is the contract `read` gives the
// code around it.
package otsh_tests

import "core:testing"
import "otsh:ssh"

@(test)
read_reports_drained_server_as_gone :: proc(t: ^testing.T) {
	// Shutdown depends on this: `serve` sets `draining` and every session's
	// `read` must immediately report the connection as finished, which is what
	// walks each app back out through its handler so terminals get restored.
	// If this ever blocks or reports "nothing typed", SIGTERM strands clients.
	srv: ssh.Server
	srv.draining = true
	s: ssh.Session
	s.server = &srv

	buf: [16]u8
	n, ok := ssh.read(&s, buf[:], 1000) // must not wait out the 1000 ms
	testing.expect_value(t, n, 0)
	testing.expect_value(t, ok, false)
}

@(test)
read_survives_unwired_session :: proc(t: ^testing.T) {
	// A Session whose channel and event are gone (torn down, or never opened)
	// must read as "connection gone", never crash and never spin. take_input
	// has to tolerate a nil channel because read runs right up until the
	// session thread frees everything.
	srv: ssh.Server
	s: ssh.Session
	s.server = &srv

	buf: [16]u8
	n, ok := ssh.read(&s, buf[:], 10)
	testing.expect_value(t, n, 0)
	testing.expect_value(t, ok, false)
}
