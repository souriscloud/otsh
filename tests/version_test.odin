// The version constants, and the one way they can go wrong.
package otsh_tests

import "core:fmt"
import "core:testing"
import "otsh:ssh"
import "otsh:sshtui"

// `sshtui` aliases `ssh`'s constants rather than declaring its own, so these
// cost nothing at run time and fail the build rather than the suite if that ever
// becomes a second copy. Written out anyway: the whole point of the aliases is
// that an app importing only `otsh:sshtui` sees the same number.
#assert(sshtui.VERSION_MAJOR == ssh.VERSION_MAJOR)
#assert(sshtui.VERSION_MINOR == ssh.VERSION_MINOR)
#assert(sshtui.VERSION_PATCH == ssh.VERSION_PATCH)

@(test)
version_string_matches_the_numbers :: proc(t: ^testing.T) {
	// Odin has no compile-time integer-to-string, so ssh.VERSION is written out
	// by hand next to the triple it must agree with. Bumping one and forgetting
	// the other is the release mistake this exists to catch; docs/releasing.md
	// points at it.
	testing.expect_value(
		t,
		ssh.VERSION,
		fmt.tprintf("%d.%d.%d", ssh.VERSION_MAJOR, ssh.VERSION_MINOR, ssh.VERSION_PATCH),
	)
	testing.expect_value(t, sshtui.VERSION, ssh.VERSION)
}
