// Regression tests for algorithm-list handling.
//
// The defect these were written for: libssh's `ssh_bind_options_set` only fails
// a list when *every* name in it is unknown. Give it a list with one typo and
// five good names and it returns OK, silently drops the typo, and negotiates
// with what is left. Measured on libssh 0.12.0 before the fix:
//
//	ciphers = "chacha20-poly1305@openssh.comTYPO,aes128-ctr" -> aes128-ctr
//	macs    = "hmac-sha2-256-etm@openssh.comTYPO,hmac-sha1"  -> hmac-sha1
//	kex     = "curve25519-sha256TYPO,diffie-hellman-group14-sha1"
//	                                -> a server offering only a SHA-1 exchange
//
// One typo, no error anywhere, weaker crypto than the operator wrote down.
// `set_algorithms` now validates every name on its own.
package otsh_tests

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import ls "otsh:libssh"
import "otsh:ssh"

@(private = "file")
scratch_path :: proc(name: string) -> string {
	dir, err := os.temp_directory(context.temp_allocator)
	if err != nil {
		dir = "."
	}
	joined, _ := filepath.join({dir, name}, context.temp_allocator)
	return joined
}

// Offers one algorithm name to libssh on a throwaway bind. This is the same
// probe `set_algorithms` uses, asserted here directly so the tests below rest on
// measured libssh behaviour rather than on an assumption about it.
@(private = "file")
libssh_knows :: proc(opt: ls.Bind_Option, name: string) -> bool {
	b := ls.bind_new()
	if b == nil {
		return false
	}
	defer ls.bind_free(b)
	cv := strings.clone_to_cstring(name, context.temp_allocator)
	return ls.bind_options_set(b, opt, rawptr(cv)) == ls.OK
}

@(test)
libssh_accepts_partially_unknown_lists :: proc(t: ^testing.T) {
	// The premise of the whole fix. If this ever fails, libssh started
	// rejecting mixed lists on its own and `set_algorithms` could be simplified
	// — but until it does, per-name validation is the only thing standing
	// between a typo and a downgrade.
	testing.expect(
		t,
		libssh_knows(.Ciphers_C_S, "aes128-gcm@openssh.com"),
		"expected libssh to know aes128-gcm",
	)
	testing.expect(
		t,
		!libssh_knows(.Ciphers_C_S, "aes128-gcm@openssh.comTYPO"),
		"expected libssh to reject a typo'd name on its own",
	)
	testing.expect(
		t,
		libssh_knows(.Ciphers_C_S, "aes128-gcm@openssh.com,aes128-gcm@openssh.comTYPO"),
		"libssh is expected to ACCEPT a mixed list and silently drop the bad name — " +
		"this is the behaviour set_algorithms defends against",
	)
}

@(test)
shipped_defaults_are_fully_supported :: proc(t: ^testing.T) {
	// Every name in otsh's own defaults must be known to the libssh being built
	// against, so the hardened list is applied whole rather than silently
	// narrowed to a subset. A failure here is not necessarily a bug — a libssh
	// built on a backend without chacha20-poly1305 legitimately lacks one — but
	// it means this build does not negotiate what docs/security.md says it does,
	// and that is worth failing the suite to surface.
	check :: proc(t: ^testing.T, opt: ls.Bind_Option, list, what: string) {
		rest := list
		for name in strings.split_iterator(&rest, ",") {
			testing.expectf(
				t,
				libssh_knows(opt, name),
				"this libssh does not know the %s %q from otsh's defaults; " +
				"the shipped list would be silently narrowed",
				what,
				name,
			)
		}
	}
	check(t, .Key_Exchange, ssh.DEFAULT_KEX, "key exchange")
	check(t, .Ciphers_C_S, ssh.DEFAULT_CIPHERS, "cipher")
	check(t, .Hmac_C_S, ssh.DEFAULT_MACS, "MAC")
	check(t, .Hostkey_Algorithms, ssh.DEFAULT_HOSTKEYS, "host key algorithm")
}

@(test)
defaults_exclude_the_weak_families :: proc(t: ^testing.T) {
	// Assert the exclusions docs/security.md claims, rather than trusting the
	// prose. libssh knows all of these names; none may appear in a default.
	weak_ciphers := []string{"aes128-cbc", "aes256-cbc", "3des-cbc"}
	for bad in weak_ciphers {
		testing.expectf(t, !strings.contains(ssh.DEFAULT_CIPHERS, bad),
			"DEFAULT_CIPHERS must not offer %s", bad)
	}
	weak_macs := []string{"hmac-sha1", "hmac-md5"}
	for bad in weak_macs {
		testing.expectf(t, !strings.contains(ssh.DEFAULT_MACS, bad),
			"DEFAULT_MACS must not offer %s", bad)
	}
	// Every default MAC must be encrypt-then-MAC.
	rest := ssh.DEFAULT_MACS
	for name in strings.split_iterator(&rest, ",") {
		testing.expectf(t, strings.has_suffix(name, "-etm@openssh.com"),
			"DEFAULT_MACS entry %q is not encrypt-then-MAC", name)
	}
	weak_kex := []string{"sha1", "nistp", "group1-", "group14-sha1"}
	for bad in weak_kex {
		testing.expectf(t, !strings.contains(ssh.DEFAULT_KEX, bad),
			"DEFAULT_KEX must not offer anything matching %s", bad)
	}
}

@(test)
serve_refuses_a_list_with_an_unknown_name :: proc(t: ^testing.T) {
	// End to end through the public entry point: a cipher list whose strong
	// entry is misspelled must stop the server rather than quietly serve the
	// weak one that survives.
	//
	// port 1 is deliberate. `set_algorithms` runs before `ssh_bind_listen`, so
	// this returns before anything is bound — but if the check ever regressed,
	// binding a privileged port fails immediately instead of leaving the suite
	// blocked forever in an accept loop.
	key := scratch_path("otsh_algcheck_hostkey")
	os.remove(key)
	defer os.remove(key)

	testing.expect(
		t,
		!ssh.serve(ssh.Config{port = 1, host_key_path = key,
			ciphers = "chacha20-poly1305@openssh.comTYPO,aes128-ctr"}),
		"a cipher list with an unknown name must refuse to start",
	)
	testing.expect(
		t,
		!ssh.serve(ssh.Config{port = 1, host_key_path = key,
			macs = "hmac-sha2-256-etm@openssh.comTYPO,hmac-sha1"}),
		"a MAC list with an unknown name must refuse to start",
	)
	testing.expect(
		t,
		!ssh.serve(ssh.Config{port = 1, host_key_path = key,
			key_exchange = "curve25519-sha256TYPO,diffie-hellman-group14-sha1"}),
		"a kex list with an unknown name must refuse to start",
	)
	testing.expect(
		t,
		!ssh.serve(ssh.Config{port = 1, host_key_path = key, ciphers = "all,of,these,are,bogus"}),
		"a wholly unknown cipher list must refuse to start",
	)
}
