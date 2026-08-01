// Pseudonymous identity derived from a client's public key.
//
// The problem this solves: an SSH key fingerprint is a perfectly good stable
// account id, but it is also a *global* one. If you store raw fingerprints and
// your database leaks, anyone can correlate your users with any other service
// that saw the same keys, and can confirm "was person X a user here?" by
// hashing a public key they already have.
//
// So we never store the fingerprint. We store HMAC(server_secret, fingerprint),
// which is stable for as long as the secret lives, meaningless anywhere else,
// and unlinkable to a public key by anyone who does not hold the secret.
package ssh

import "core:crypto"
import "core:crypto/hash"
import "core:crypto/hmac"
import "core:fmt"
import "core:os"

// Length of the identity secret, in bytes.
SECRET_SIZE :: 32
// 128 bits of id. Collisions are not a practical concern and the shorter
// string is easier to eyeball in logs.
ID_BYTES :: 16
// Length of a pseudonymous id as hex text.
ID_SIZE :: ID_BYTES * 2

// The per-server HMAC key behind `Session.id`. Back it up with the host key:
// losing it re-pseudonymises every user, so everyone looks new.
Identity_Secret :: struct {
	bytes:  [SECRET_SIZE]u8,
	loaded: bool,
}

// Loads the secret from `path`, creating it on first run. Treat this file
// exactly like the host key: back it up, keep it 0600, never commit it.
// Losing it does not leak anything — it just re-pseudonymises everybody, which
// means every user looks like a new user.
//
// Most apps just set Config.identity_secret and never call this directly.
// It exists for tooling that needs the secret without starting a server:
//
// Example:
//
//	secret, ok := ssh.load_or_create_secret("identity-secret")
load_or_create_secret :: proc(path: string) -> (secret: Identity_Secret, ok: bool) {
	if data, read_err := os.read_entire_file_from_path(path, context.allocator); read_err == nil {
		// Zero it before freeing: this is the long-lived key every pseudonym
		// derives from, and leaving it in the heap outlives any use of it.
		defer {
			crypto.zero_explicit(raw_data(data), len(data))
			delete(data)
		}
		if len(data) < SECRET_SIZE {
			fmt.eprintfln("otsh: identity secret %s is truncated; refusing to start", path)
			return {}, false
		}
		copy(secret.bytes[:], data[:SECRET_SIZE])

		// An all-zero secret is not a secret. It is reachable by a truncated
		// write, a zero-filled restore, or a provisioning template that created
		// the file with dd — and it makes every id computable by anyone holding
		// the fingerprint, which is precisely what this key exists to prevent.
		if crypto.is_zero_constant_time(secret.bytes[:]) == 1 {
			fmt.eprintfln(
				"otsh: identity secret %s is all zeroes; refusing to start.\n" +
				"      Delete it to have a new one generated — note that doing so\n" +
				"      re-pseudonymises every user.", path)
			return {}, false
		}
		secret.loaded = true
		warn_if_world_readable(path)
		return secret, true
	}

	crypto.rand_bytes(secret.bytes[:])
	if !write_private_file(path, secret.bytes[:]) {
		return {}, false
	}
	secret.loaded = true
	fmt.printfln("otsh: generated new identity secret at %s (back this up)", path)
	return secret, true
}

// Stable per-server id for a verified key fingerprint. Writes into `dst`
// (needs ID_SIZE bytes) and returns a string viewing it, so this allocates
// nothing and can run on a session thread without touching an allocator.
pseudonym :: proc(secret: ^Identity_Secret, fingerprint: string, dst: []u8) -> string {
	if !secret.loaded || fingerprint == "" || len(dst) < ID_SIZE {
		return ""
	}
	mac: [32]u8
	hmac.sum(hash.Algorithm.SHA256, mac[:], transmute([]u8)fingerprint, secret.bytes[:])
	hex_digits := "0123456789abcdef"
	for b, i in mac[:ID_BYTES] {
		dst[i * 2] = hex_digits[b >> 4]
		dst[i * 2 + 1] = hex_digits[b & 0xf]
	}
	return string(dst[:ID_SIZE])
}

// Scrubs a loaded secret. Used on `serve`'s startup-failure paths, where the
// Server is handed back to the allocator and the HMAC key must not travel with
// it into freed memory.
@(private)
wipe_secret :: proc(s: ^Identity_Secret) {
	crypto.zero_explicit(raw_data(s.bytes[:]), SECRET_SIZE)
	s.loaded = false
}

// Compares two ids without leaking where they differ via timing. Use this
// rather than `==` when checking an id against a stored one.
ids_equal :: proc "contextless" (a, b: string) -> bool {
	// Two empty ids are NOT the same user. An id is empty whenever the client
	// did not authenticate with a key, or no identity secret is configured, so
	// treating "" == "" as a match would let every anonymous client satisfy a
	// comparison against any record whose id was never populated.
	if len(a) == 0 || len(b) == 0 {
		return false
	}
	if len(a) != len(b) {
		return false
	}
	return crypto.compare_constant_time(transmute([]u8)a, transmute([]u8)b) == 1
}

@(private)
write_private_file :: proc(path: string, data: []u8) -> bool {
	// O_EXCL so a race cannot make us clobber an existing secret, and 0600 from
	// the moment the file exists rather than fixed up afterwards.
	f, err := os.open(path, {.Write, .Create, .Excl}, {.Read_User, .Write_User})
	if err != nil {
		fmt.eprintfln("otsh: cannot create %s: %v", path, err)
		return false
	}
	defer os.close(f)
	if _, werr := os.write(f, data); werr != nil {
		fmt.eprintfln("otsh: cannot write %s: %v", path, werr)
		return false
	}
	return true
}
