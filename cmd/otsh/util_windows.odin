#+build windows
package main

import "core:os"

// What `uname -s` stood for in the script. The script saw MINGW64_NT-… from
// Git Bash; the compiled tool runs native, so say the honest thing.
UNAME :: "Windows"

// Executability is not a file bit on Windows; existing as a file is the
// usable test, and lookup_path already tries the .exe spelling.
is_executable_file :: proc(path: string) -> bool {
	return os.is_file(path)
}

is_writable_dir :: proc(path: string) -> bool {
	return os.is_directory(path)
}

// Ctrl+C on Windows is delivered per console; the child gets its own event
// and the wrapper exiting early is harmless there.
ignore_sigint :: proc() {
}

// GetModuleFileName is already the real path.
real_path :: proc(path: string) -> string {
	return path
}
