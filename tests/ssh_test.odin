// Tests for the pure logic in otsh:ssh — the input ring, pseudonymous
// identity, resource limits, and audit line formatting. Nothing here opens a
// socket.
package otsh_tests

import "core:os"
import "core:testing"
import "core:time"
import "otsh:ssh"
import "otsh:sshtui"

// --- ring buffer ------------------------------------------------------------

@(test)
ring_push_pop :: proc(t: ^testing.T) {
	r: ssh.Ring
	testing.expect_value(t, ssh.ring_push(&r, transmute([]u8)string("hello")), 5)

	buf: [16]u8
	n := ssh.ring_pop(&r, buf[:])
	testing.expect_value(t, n, 5)
	testing.expect_value(t, string(buf[:n]), "hello")

	// Drained.
	testing.expect_value(t, ssh.ring_pop(&r, buf[:]), 0)
}

@(test)
ring_partial_pop :: proc(t: ^testing.T) {
	r: ssh.Ring
	ssh.ring_push(&r, transmute([]u8)string("abcdef"))

	small: [2]u8
	testing.expect_value(t, ssh.ring_pop(&r, small[:]), 2)
	testing.expect_value(t, string(small[:]), "ab")

	rest: [16]u8
	n := ssh.ring_pop(&r, rest[:])
	testing.expect_value(t, string(rest[:n]), "cdef")
}

@(test)
ring_reports_what_it_took :: proc(t: ^testing.T) {
	// Overfilling must be reported, not silently dropped: the return value is
	// what tells libssh to keep the remainder and re-offer it. That is the
	// protocol's flow control.
	r: ssh.Ring
	big := make([]u8, ssh.MAX_INPUT + 100)
	defer delete(big)

	took := ssh.ring_push(&r, big)
	testing.expect_value(t, took, ssh.MAX_INPUT)
	testing.expect_value(t, ssh.ring_push(&r, big), 0) // full: takes nothing
}

@(test)
ring_wraps_around :: proc(t: ^testing.T) {
	// Push/pop past the end of the backing array so start wraps, then verify
	// the bytes still come back in order.
	r: ssh.Ring
	chunk := make([]u8, ssh.MAX_INPUT - 4)
	defer delete(chunk)
	ssh.ring_push(&r, chunk)

	drain := make([]u8, ssh.MAX_INPUT - 4)
	defer delete(drain)
	ssh.ring_pop(&r, drain)

	// Now start is near the end; this push must straddle the boundary.
	ssh.ring_push(&r, transmute([]u8)string("wrapped"))
	out: [16]u8
	n := ssh.ring_pop(&r, out[:])
	testing.expect_value(t, string(out[:n]), "wrapped")
}

@(test)
session_stays_small :: proc(t: ^testing.T) {
	// One Session is allocated per accepted connection and the Ring lives inline
	// in it, so this size is multiplied by max_sessions — it used to be 17184
	// bytes with a 16 KiB ring, which is why the ring is 4 KiB now.
	//
	// A ceiling rather than an exact value: field order, alignment and padding
	// are the compiler's business and a new bool must not fail the suite. What
	// must fail is somebody re-growing the ring or parking a large buffer in
	// Session. 6 KiB leaves ~1.2 KB of headroom over the 4896 bytes measured
	// when this was written.
	testing.expectf(
		t,
		size_of(ssh.Session) <= 6 * 1024,
		"Session is %d bytes, past its 6 KiB budget; check what was added and whether it belongs inline",
		size_of(ssh.Session),
	)
}

// --- pseudonymous identity --------------------------------------------------

@(test)
pseudonym_is_stable_and_distinct :: proc(t: ^testing.T) {
	path := "/tmp/otsh_test_secret"
	os.remove(path)
	defer os.remove(path)

	secret, ok := ssh.load_or_create_secret(path)
	testing.expect(t, ok, "failed to create identity secret")

	a1, a2, b1: [ssh.ID_SIZE]u8
	fp_a := "SHA256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	fp_b := "SHA256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

	id_a1 := ssh.pseudonym(&secret, fp_a, a1[:])
	id_a2 := ssh.pseudonym(&secret, fp_a, a2[:])
	id_b1 := ssh.pseudonym(&secret, fp_b, b1[:])

	testing.expect_value(t, len(id_a1), ssh.ID_SIZE)
	testing.expect_value(t, id_a1, id_a2) // same key -> same id, always
	testing.expect(t, id_a1 != id_b1, "different keys must not collide")
	// The id must not leak the fingerprint it came from.
	testing.expect(t, id_a1 != fp_a, "id must not be the fingerprint")
}

@(test)
pseudonym_differs_per_secret :: proc(t: ^testing.T) {
	// Two servers with different secrets must produce unlinkable ids for the
	// same key. This is the property that makes a leaked database useless
	// for correlating users across services.
	p1, p2 := "/tmp/otsh_test_secret1", "/tmp/otsh_test_secret2"
	os.remove(p1);os.remove(p2)
	defer os.remove(p1)
	defer os.remove(p2)

	s1, ok1 := ssh.load_or_create_secret(p1)
	s2, ok2 := ssh.load_or_create_secret(p2)
	testing.expect(t, ok1 && ok2)

	fp := "SHA256:cccccccccccccccccccccccccccccccccccccccccc"
	b1, b2: [ssh.ID_SIZE]u8
	testing.expect(t, ssh.pseudonym(&s1, fp, b1[:]) != ssh.pseudonym(&s2, fp, b2[:]),
		"the same key under two secrets must not produce the same id")
}

@(test)
pseudonym_needs_a_secret :: proc(t: ^testing.T) {
	// An unloaded secret yields no id rather than a weak one.
	empty: ssh.Identity_Secret
	buf: [ssh.ID_SIZE]u8
	testing.expect_value(t, ssh.pseudonym(&empty, "SHA256:x", buf[:]), "")
}

@(test)
pseudonym_survives_reload :: proc(t: ^testing.T) {
	// Restarting the server must not re-pseudonymise everybody.
	path := "/tmp/otsh_test_secret3"
	os.remove(path)
	defer os.remove(path)

	fp := "SHA256:dddddddddddddddddddddddddddddddddddddddddd"
	s1, _ := ssh.load_or_create_secret(path)
	b1: [ssh.ID_SIZE]u8
	first := ssh.pseudonym(&s1, fp, b1[:])

	s2, ok := ssh.load_or_create_secret(path) // reads the existing file
	testing.expect(t, ok)
	b2: [ssh.ID_SIZE]u8
	testing.expect_value(t, ssh.pseudonym(&s2, fp, b2[:]), first)
}

@(test)
ids_equal_compares_correctly :: proc(t: ^testing.T) {
	testing.expect(t, ssh.ids_equal("abc123", "abc123"))
	testing.expect(t, !ssh.ids_equal("abc123", "abc124"))
	testing.expect(t, !ssh.ids_equal("abc", "abc123")) // length mismatch
}

@(test)
ids_equal_rejects_empty :: proc(t: ^testing.T) {
	// An id is empty whenever the client did not authenticate with a key, or no
	// identity secret is configured. Two empties must NOT compare equal, or an
	// app checking against a record whose id was never populated would admit
	// every anonymous client.
	testing.expect(t, !ssh.ids_equal("", ""), "two empty ids must not match")
	testing.expect(t, !ssh.ids_equal("", "abc123"))
	testing.expect(t, !ssh.ids_equal("abc123", ""))
}

@(test)
identity_secret_rejects_all_zero :: proc(t: ^testing.T) {
	// An all-zero HMAC key is a published key: every id becomes computable by
	// anyone holding the fingerprint, which voids the point of pseudonymising.
	path := "/tmp/otsh_test_zero_secret"
	os.remove(path)
	defer os.remove(path)

	zeros := make([]u8, ssh.SECRET_SIZE)
	defer delete(zeros)
	werr := os.write_entire_file(path, zeros)
	testing.expect(t, werr == nil, "could not stage the zero-filled secret")

	_, ok := ssh.load_or_create_secret(path)
	testing.expect(t, !ok, "an all-zero identity secret must be refused")
}

// --- limits -----------------------------------------------------------------

@(test)
limits_zero_value_is_the_default :: proc(t: ^testing.T) {
	// The zero value must be the safe default, not an accidental free-for-all.
	// Limits is resolved inside serve(), so assert the documented constants
	// that resolution is built on.
	testing.expect(t, ssh.DEFAULT_LIMITS.max_sessions > 0, "expected a session cap")
	testing.expect(t, ssh.DEFAULT_LIMITS.max_per_ip > 0, "expected a per-IP cap")
	testing.expect(t, ssh.DEFAULT_LIMITS.handshake_seconds > 0, "expected a handshake timeout")
	testing.expect(t, ssh.DEFAULT_LIMITS.max_auth_attempts > 0, "expected an auth attempt cap")
}

@(test)
auth_method_sets :: proc(t: ^testing.T) {
	testing.expect(t, .None in ssh.ALL_AUTH)
	testing.expect(t, .Password in ssh.ALL_AUTH)
	testing.expect(t, .Publickey in ssh.ALL_AUTH)

	// The set an identity app should use: no "none", so clients offer a key.
	keys_only := ssh.Auth_Methods{.Publickey}
	testing.expect(t, .None not_in keys_only)
	testing.expect(t, .Publickey in keys_only)
}

@(test)
server_defaults_are_usable :: proc(t: ^testing.T) {
	// A zero Config must not bind port 0 — these are what serve() falls back to.
	testing.expect_value(t, ssh.DEFAULT_PORT, 2222)
	testing.expect(t, ssh.DEFAULT_HOST != "", "expected a default bind address")
	testing.expect(t, ssh.DEFAULT_HOST_KEY != "", "expected a default host key path")
}

// --- audit ------------------------------------------------------------------
//
// The line format is a contract — log filters are written against it — so these
// assert whole lines byte for byte, not just that something was emitted.

// A fixed instant, so every expected line below can spell its own timestamp.
@(private = "file")
AUDIT_TS :: "2026-07-29T12:00:00Z"

// The width of a real pseudonymous id (ssh.ID_SIZE hex characters).
@(private = "file")
AUDIT_ID :: "0123456789abcdef0123456789abcdef"

// Client text past the 32-byte cap, and what must survive it.
@(private = "file")
AUDIT_LONG_USER :: AUDIT_LONG_USER_CAP + "GHIJKLMNOPQRSTUVWXYZ"
@(private = "file")
AUDIT_LONG_USER_CAP :: "abcdefghijklmnopqrstuvwxyzABCDEF"

@(private = "file")
audit_at :: proc() -> time.Time {
	t, _ := time.components_to_time(2026, 7, 29, 12, 0, 0)
	return t
}

// `audit_stderr` is this plus a newline and one write; testing the format proc
// tests the line every sink produces, without a socket or a captured fd.
@(private = "file")
audit_line :: proc(buf: []u8, e: ssh.Audit_Event) -> string {
	e := e
	e.at = audit_at()
	return ssh.audit_format(e, buf)
}

@(test)
audit_lines_are_exact :: proc(t: ^testing.T) {
	buf: [ssh.AUDIT_LINE_MAX]u8

	testing.expect_value(
		t,
		audit_line(buf[:], ssh.Audit_Event{kind = .Listen, host = "0.0.0.0", port = 2229}),
		"otsh: audit ts=" + AUDIT_TS + " event=listen host=0.0.0.0 port=2229",
	)
	testing.expect_value(
		t,
		audit_line(buf[:], ssh.Audit_Event{kind = .Accept, addr = "203.0.113.7"}),
		"otsh: audit ts=" + AUDIT_TS + " event=accept addr=203.0.113.7",
	)
	testing.expect_value(
		t,
		audit_line(buf[:], ssh.Audit_Event{kind = .Kex_Fail, addr = "203.0.113.7"}),
		"otsh: audit ts=" + AUDIT_TS + " event=kex_fail addr=203.0.113.7",
	)
	testing.expect_value(
		t,
		audit_line(
			buf[:],
			ssh.Audit_Event{kind = .Reject, addr = "203.0.113.7", limit = .Per_Ip},
		),
		"otsh: audit ts=" + AUDIT_TS + " event=reject addr=203.0.113.7 limit=per_ip",
	)
	testing.expect_value(
		t,
		audit_line(
			buf[:],
			ssh.Audit_Event{kind = .Reject, addr = "203.0.113.7", limit = .Sessions},
		),
		"otsh: audit ts=" + AUDIT_TS + " event=reject addr=203.0.113.7 limit=sessions",
	)
	// The line the task's example spells out, and the one a filter keys on.
	testing.expect_value(
		t,
		audit_line(
			buf[:],
			ssh.Audit_Event {
				kind = .Auth,
				addr = "203.0.113.7",
				method = .Publickey,
				user = "git",
				ok = false,
			},
		),
		"otsh: audit ts=" + AUDIT_TS +
		" event=auth addr=203.0.113.7 method=publickey user=git ok=false",
	)
	testing.expect_value(
		t,
		audit_line(
			buf[:],
			ssh.Audit_Event {
				kind = .Session_Start,
				addr = "203.0.113.7",
				user = "git",
				term = "xterm-256color",
				cols = 120,
				rows = 40,
				id = AUDIT_ID,
			},
		),
		"otsh: audit ts=" + AUDIT_TS +
		" event=session_start addr=203.0.113.7 user=git term=xterm-256color cols=120 rows=40 id=" +
		AUDIT_ID,
	)
	testing.expect_value(
		t,
		audit_line(
			buf[:],
			ssh.Audit_Event {
				kind = .Session_End,
				addr = "203.0.113.7",
				id = AUDIT_ID,
				duration = 12_345_678_901,
			},
		),
		"otsh: audit ts=" + AUDIT_TS +
		" event=session_end addr=203.0.113.7 secs=12.345 id=" + AUDIT_ID,
	)
}

@(test)
audit_timestamp_shape :: proc(t: ^testing.T) {
	// A filter matches on the ts field's shape, so it is fixed: exactly 20
	// characters of RFC 3339 in UTC, second resolution, zero-padded.
	buf: [ssh.AUDIT_LINE_MAX]u8
	line := audit_line(buf[:], ssh.Audit_Event{kind = .Accept, addr = "203.0.113.7"})

	prefix := "otsh: audit ts="
	ts := line[len(prefix):len(prefix) + len(AUDIT_TS)]
	testing.expect_value(t, len(ts), 20)
	testing.expect_value(t, ts, AUDIT_TS)
	for c, i in transmute([]u8)ts {
		switch i {
		case 4, 7:
			testing.expect_value(t, c, '-')
		case 10:
			testing.expect_value(t, c, 'T')
		case 13, 16:
			testing.expect_value(t, c, ':')
		case 19:
			testing.expect_value(t, c, 'Z')
		case:
			testing.expect(t, c >= '0' && c <= '9', "expected a digit")
		}
	}

	// A single-digit component must still be padded, or the field changes width.
	early, _ := time.components_to_time(2026, 1, 2, 3, 4, 5)
	line = ssh.audit_format(ssh.Audit_Event{kind = .Accept, addr = "1.2.3.4", at = early}, buf[:])
	testing.expect_value(
		t,
		line,
		"otsh: audit ts=2026-01-02T03:04:05Z event=accept addr=1.2.3.4",
	)
}

@(test)
audit_scrubs_client_text :: proc(t: ^testing.T) {
	// A username is whatever the client typed. Left alone it could inject a
	// space, an '=' or a newline and forge fields — or whole extra records — in
	// somebody else's log.
	buf: [ssh.AUDIT_LINE_MAX]u8
	line := audit_line(
		buf[:],
		ssh.Audit_Event {
			kind = .Auth,
			addr = "203.0.113.7",
			method = .Password,
			user = "ev il=x\nok=true",
			ok = false,
		},
	)
	testing.expect_value(
		t,
		line,
		"otsh: audit ts=" + AUDIT_TS +
		" event=auth addr=203.0.113.7 method=password user=ev?il?x?ok?true ok=false",
	)

	// Over-long client text is capped, not allowed to push the line around.
	line = audit_line(
		buf[:],
		ssh.Audit_Event {
			kind = .Auth,
			addr = "203.0.113.7",
			method = .None,
			user = AUDIT_LONG_USER,
			ok = true,
		},
	)
	testing.expect_value(
		t,
		line,
		"otsh: audit ts=" + AUDIT_TS +
		" event=auth addr=203.0.113.7 method=none user=" + AUDIT_LONG_USER_CAP + " ok=true",
	)
}

@(test)
audit_missing_values_are_marked :: proc(t: ^testing.T) {
	// A field a parser expects is never simply absent: an unknown value is "-",
	// so `addr=` always has something after it. Only `id` is ever omitted, and
	// only from the end of the line.
	buf: [ssh.AUDIT_LINE_MAX]u8
	testing.expect_value(
		t,
		audit_line(buf[:], ssh.Audit_Event{kind = .Kex_Fail}),
		"otsh: audit ts=" + AUDIT_TS + " event=kex_fail addr=-",
	)
	// IPv6, including a zone id, must survive scrubbing intact.
	testing.expect_value(
		t,
		audit_line(buf[:], ssh.Audit_Event{kind = .Accept, addr = "fe80::1%en0"}),
		"otsh: audit ts=" + AUDIT_TS + " event=accept addr=fe80::1%en0",
	)
}

@(test)
audit_line_fits_the_buffer :: proc(t: ^testing.T) {
	// AUDIT_LINE_MAX is what `audit_stderr` puts on the stack, and it holds one
	// byte back for the newline. The worst case is session_start with every
	// field at its cap.
	buf: [ssh.AUDIT_LINE_MAX]u8
	wide := "0123456789012345678901234567890123456789012345678901234567890123" // 64
	line := audit_line(
		buf[:ssh.AUDIT_LINE_MAX - 1],
		ssh.Audit_Event {
			kind = .Session_Start,
			addr = wide,
			user = wide,
			term = wide,
			cols = 1000,
			rows = 300,
			id = wide,
		},
	)
	testing.expectf(
		t,
		len(line) < ssh.AUDIT_LINE_MAX - 1,
		"the widest line is %d bytes, which fills AUDIT_LINE_MAX (%d)",
		len(line),
		ssh.AUDIT_LINE_MAX,
	)
}

@(test)
audit_is_off_by_default :: proc(t: ^testing.T) {
	// The zero value must keep the pre-audit behaviour exactly: nothing is
	// recorded unless an operator opts in, because every line carries a peer
	// address.
	cfg: ssh.Config
	testing.expect(t, cfg.audit == nil, "ssh.Config must not audit by default")

	tui_cfg: sshtui.Config
	testing.expect(t, tui_cfg.audit == nil, "sshtui.Config must not audit by default")

	// And the sink that ships is a real one, so opting in is one assignment.
	cfg.audit = ssh.audit_stderr
	testing.expect(t, cfg.audit != nil)
}

@(test)
crypto_defaults_exclude_legacy :: proc(t: ^testing.T) {
	// Guard the hardening: no SHA-1, no CBC, no non-AEAD ciphers.
	contains :: proc(haystack, needle: string) -> bool {
		if len(needle) > len(haystack) {return false}
		for i in 0 ..= len(haystack) - len(needle) {
			if haystack[i:i + len(needle)] == needle {return true}
		}
		return false
	}
	testing.expect(t, !contains(ssh.DEFAULT_CIPHERS, "cbc"), "CBC must not be offered")
	testing.expect(t, !contains(ssh.DEFAULT_MACS, "sha1"), "SHA-1 MACs must not be offered")
	testing.expect(t, !contains(ssh.DEFAULT_KEX, "sha1"), "SHA-1 kex must not be offered")
	testing.expect(t, contains(ssh.DEFAULT_KEX, "curve25519"), "expected curve25519 kex")
	testing.expect(t, contains(ssh.DEFAULT_HOSTKEYS, "ed25519"), "expected an ed25519 host key")
}
