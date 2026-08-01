// A pinned test vector for the id derivation.
//
// The existing identity tests assert *properties*: same key gives the same id,
// different keys give different ids, different secrets give unlinkable ids. All
// three still hold if the HMAC's key and message arguments are swapped, if the
// construction degrades to a plain SHA256(secret || fingerprint), or if the
// wrong end of the digest is kept. Each of those is a real weakening —
// SHA256(secret || fingerprint) is length-extendable and is not a MAC — and
// none of them would fail a property test.
//
// So the expected value below was produced by an implementation that is not
// this one: Python's hmac/hashlib.
//
//	secret = bytes(range(0x40, 0x60))            # 32 bytes, no internal symmetry
//	fp     = "SHA256:s2CahHFMPJgOFcvU0UuDHhvjF92wwZ+Q34H8iTpVeWY"
//	hmac.new(secret, fp.encode(), hashlib.sha256).hexdigest()[:32]
//	  -> 51e402f2d2105709aff8c1d5f54dfc65
//
// Measured against otsh: identical. The near misses, for contrast —
//
//	HMAC(key=fp, msg=secret) -> 102430788cb5e429da001b03b9832441
//	SHA256(secret || fp)     -> 0fc1e4fd9b93dc4d8260a93eda92a14a
//	last 16 bytes not first  -> 6b9c97bc65724cfcc7afa0383f3ebdb7
package otsh_tests

import "core:os"
import "core:path/filepath"
import "core:testing"
import "otsh:ssh"

@(test)
pseudonym_matches_an_independent_hmac :: proc(t: ^testing.T) {
	dir, err := os.temp_directory(context.temp_allocator)
	if err != nil {
		dir = "."
	}
	path, _ := filepath.join({dir, "otsh_test_hmac_vector"}, context.temp_allocator)
	os.remove(path)
	defer os.remove(path)

	// The exact 32 bytes the vector above was computed with.
	raw: [ssh.SECRET_SIZE]u8
	for i in 0 ..< ssh.SECRET_SIZE {
		raw[i] = u8(0x40 + i)
	}
	if werr := os.write_entire_file(path, raw[:]); werr != nil {
		testing.fail_now(t, "could not write the test secret")
	}

	secret, ok := ssh.load_or_create_secret(path)
	testing.expect(t, ok, "failed to load the pinned secret")

	buf: [ssh.ID_SIZE]u8
	got := ssh.pseudonym(&secret, "SHA256:s2CahHFMPJgOFcvU0UuDHhvjF92wwZ+Q34H8iTpVeWY", buf[:])
	testing.expect_value(t, got, "51e402f2d2105709aff8c1d5f54dfc65")
}

@(test)
pseudonym_rejects_what_it_should :: proc(t: ^testing.T) {
	buf: [ssh.ID_SIZE]u8

	// An unloaded secret must never produce an id — otherwise a server with no
	// identity_secret configured would hand every app a derived-looking value
	// keyed on an all-zero secret, which is a published key.
	empty: ssh.Identity_Secret
	testing.expect_value(t, ssh.pseudonym(&empty, "SHA256:whatever", buf[:]), "")

	dir, err := os.temp_directory(context.temp_allocator)
	if err != nil {
		dir = "."
	}
	path, _ := filepath.join({dir, "otsh_test_hmac_guards"}, context.temp_allocator)
	os.remove(path)
	defer os.remove(path)
	secret, ok := ssh.load_or_create_secret(path)
	testing.expect(t, ok, "failed to create a secret")

	// No fingerprint, no id.
	testing.expect_value(t, ssh.pseudonym(&secret, "", buf[:]), "")

	// An undersized destination must be refused rather than partly filled: a
	// short id compared with ids_equal would be a weaker check, not a failed one.
	short: [ssh.ID_SIZE - 1]u8
	testing.expect_value(t, ssh.pseudonym(&secret, "SHA256:whatever", short[:]), "")

	// A fingerprint is attacker-influenced (they choose the key it hashes).
	// Length must not matter to the construction.
	long := make([]u8, 4096, context.temp_allocator)
	for i in 0 ..< len(long) {
		long[i] = u8('A' + i % 26)
	}
	id_long := ssh.pseudonym(&secret, string(long), buf[:])
	testing.expect_value(t, len(id_long), ssh.ID_SIZE)
}
