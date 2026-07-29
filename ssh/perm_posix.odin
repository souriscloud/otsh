#+build !windows
// File-permission handling for the two secrets on disk, the host key and the
// identity secret. POSIX half; perm_windows.odin declares the same two names
// and does nothing, for the reason stated there.
package ssh

import "core:fmt"
import "core:strings"
import "core:sys/posix"

// A host key or identity secret that other local users can read is not a
// secret. Say so loudly rather than failing silently.
warn_if_world_readable :: proc(path: string) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	st: posix.stat_t
	if posix.stat(cpath, &st) != .OK {
		return
	}
	mode := transmute(posix.mode_t)(st.st_mode)
	if .IRGRP in mode || .IWGRP in mode || .IROTH in mode || .IWOTH in mode {
		fmt.eprintfln(
			"otsh: WARNING %s is readable by other users; run: chmod 600 %s",
			path,
			path,
		)
	}
}

// Belt and braces after libssh has written a private key: confirm the mode
// really is 0600 rather than assuming libssh left the O_EXCL creation mode
// alone.
@(private)
ensure_private_mode :: proc(path: string) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if posix.chmod(cpath, {.IRUSR, .IWUSR}) != .OK {
		fmt.eprintfln("otsh: WARNING could not chmod 600 %s", path)
	}
}
