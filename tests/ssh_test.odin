// Tests for the pure logic in otsh:ssh — the input ring, pseudonymous
// identity, and resource limits. Nothing here opens a socket.
package otsh_tests

import "core:os"
import "core:testing"
import "otsh:ssh"

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
