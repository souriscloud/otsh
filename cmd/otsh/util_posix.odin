#+build !windows
package main

import "core:os"
import "core:strings"
import "core:sys/posix"

UNAME :: "Darwin" when ODIN_OS == .Darwin else "Linux" when ODIN_OS == .Linux else "FreeBSD" when ODIN_OS == .FreeBSD else "Unknown"

is_executable_file :: proc(path: string) -> bool {
	if !os.is_file(path) {
		return false
	}
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	return posix.access(cpath, {.X_OK}) == .OK
}

is_writable_dir :: proc(path: string) -> bool {
	if !os.is_directory(path) {
		return false
	}
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	return posix.access(cpath, {.W_OK}) == .OK
}

// `otsh run` waits on the app it spawned; Ctrl+C goes to the whole foreground
// process group, so without this the wrapper would die mid-wait and return
// the prompt while the app is still restoring the terminal. Installed *after*
// the spawn so the app inherits a default SIGINT, not an ignored one.
ignore_sigint :: proc() {
	posix.signal(.SIGINT, auto_cast posix.SIG_IGN)
}

// Symlinks resolved, like the `while [ -L "$self" ]` walk the script did.
real_path :: proc(path: string) -> string {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	res := posix.realpath(cpath)
	if res == nil {
		return path
	}
	return strings.clone_from_cstring(res, context.allocator)
}
