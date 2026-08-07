// Process spawning and `command -v` — the primitives everything else uses.
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Run argv and capture stdout, discarding stderr (the callers that use this
// all wrote `2>/dev/null` in the script). ok means started *and* exited 0;
// out is whatever was printed either way, because a couple of call sites —
// doctor's `odin version` tag — take the output regardless of status.
run_capture :: proc(argv: []string) -> (out: string, ok: bool) {
	state, stdout, _, err := os.process_exec(
		os.Process_Desc{command = argv},
		context.allocator,
	)
	if err != nil {
		return "", false
	}
	return string(stdout), state.exited && state.exit_code == 0
}

run_ok :: proc(argv: []string) -> bool {
	_, ok := run_capture(argv)
	return ok
}

// Run argv with our own stdin/stdout/stderr and return its exit code.
run_inherit :: proc(argv: []string) -> int {
	p, err := os.process_start(
		os.Process_Desc{
			command = argv,
			stdin   = os.stdin,
			stdout  = os.stdout,
			stderr  = os.stderr,
		},
	)
	if err != nil {
		die(fmt.tprintf("cannot run %s: %v", argv[0], err))
	}
	state, werr := os.process_wait(p)
	if werr != nil {
		return 1
	}
	return state.exit_code
}

// `command -v`: a word containing a path separator must itself be an
// executable file; a bare word is searched for on $PATH. Returns what would
// run — which is also what doctor prints.
lookup_path :: proc(name: string) -> (resolved: string, found: bool) {
	when ODIN_OS == .Windows {
		has_sep := strings.contains_any(name, "/\\")
	} else {
		has_sep := strings.contains_rune(name, '/')
	}
	if has_sep {
		if is_executable_file(name) {
			return name, true
		}
		when ODIN_OS == .Windows {
			if !strings.has_suffix(name, ".exe") && is_executable_file(strings.concatenate({name, ".exe"}, context.allocator)) {
				return strings.concatenate({name, ".exe"}, context.allocator), true
			}
		}
		return "", false
	}
	path_env := os.get_env("PATH", context.allocator)
	sep := ";" when ODIN_OS == .Windows else ":"
	for dir in strings.split(path_env, sep, context.allocator) {
		if dir == "" {
			continue
		}
		cand := path_join(dir, name)
		if is_executable_file(cand) {
			return cand, true
		}
		when ODIN_OS == .Windows {
			if !strings.has_suffix(name, ".exe") {
				cand_exe := strings.concatenate({cand, ".exe"}, context.allocator)
				if is_executable_file(cand_exe) {
					return cand_exe, true
				}
			}
		}
	}
	return "", false
}

path_join :: proc(elems: ..string) -> string {
	s, _ := filepath.join(elems, context.allocator)
	return s
}

// `mkdir -p`: success includes "it was already there", which
// os.make_directory_all treats as an error.
mkdir_p :: proc(dir: string) -> bool {
	err := os.make_directory_all(dir)
	return err == nil || os.is_directory(dir)
}

// What $( ) did: strip trailing newlines.
chomp :: proc(s: string) -> string {
	return strings.trim_right(s, "\r\n")
}

first_line :: proc(s: string) -> string {
	if i := strings.index_byte(s, '\n'); i >= 0 {
		return strings.trim_right(s[:i], "\r")
	}
	return s
}

home_dir :: proc() -> string {
	home := os.get_env("HOME", context.allocator)
	when ODIN_OS == .Windows {
		if home == "" {
			home = os.get_env("USERPROFILE", context.allocator)
		}
	}
	return home
}

// `cd "$dir" && pwd`. The directory is known to exist by the time this runs.
abs_path :: proc(p: string) -> string {
	abs, err := os.get_absolute_path(p, context.allocator)
	if err != nil {
		die(fmt.tprintf("cannot resolve path: %s", p))
	}
	return abs
}

is_symlink :: proc(p: string) -> bool {
	fi, err := os.lstat(p, context.allocator)
	if err != nil {
		return false
	}
	return fi.type == .Symlink
}
