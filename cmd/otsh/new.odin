// otsh new — scaffold a project that builds and serves as-is.
//
// The templates live in templates/ beside this file and are embedded at
// compile time, so the built tool is one self-contained binary and a symlink
// on $PATH cannot go stale against a half-copied tree. Placeholders are
// substituted by cmd_new below.
package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strings"

MAIN_TMPL :: #load("templates/main_odin.tmpl", string)
BUILD_TMPL :: #load("templates/build_sh.tmpl", string)
IGNORE_TMPL :: #load("templates/gitignore.tmpl", string)

// True when something is already listening on this port. A plain TCP dial
// needs nothing installed; a refused connection means the port is free.
port_in_use :: proc(port: int) -> bool {
	sock, err := net.dial_tcp_from_endpoint(net.Endpoint{address = net.IP4_Loopback, port = port})
	if err != nil {
		return false
	}
	net.close(sock)
	return true
}

// The first free port at or above `from`. A generated project that collides
// with something already running fails on its first `otsh run` with "address
// in use", which is a rotten way to meet a library — and the fix is one
// probe.
first_free_port :: proc(from: int) -> int {
	for p := from; p < from + 40; p += 1 {
		if !port_in_use(p) {
			return p
		}
	}
	return from
}

all_digits :: proc(s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	for c in s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

// The directory name becomes an Odin file's contents, a binary name and a
// host key filename. Keep it to characters all three tolerate. Byte-wise,
// like `tr -c 'A-Za-z0-9_-' '_'` was.
sanitize_name :: proc(s: string) -> string {
	b := strings.builder_make(context.allocator)
	for i in 0 ..< len(s) {
		c := s[i]
		ok :=
			(c >= 'A' && c <= 'Z') ||
			(c >= 'a' && c <= 'z') ||
			(c >= '0' && c <= '9') ||
			c == '_' ||
			c == '-'
		strings.write_byte(&b, c if ok else '_')
	}
	return strings.to_string(b)
}

@(private = "file")
subst :: proc(s: string, pairs: ..[2]string) -> string {
	out := s
	for p in pairs {
		out, _ = strings.replace_all(out, p[0], p[1], context.allocator)
	}
	return out
}

// What `printf '%s\n' "$body"` produced: the template body with exactly one
// trailing newline.
@(private = "file")
write_scaffold :: proc(path, body: string) {
	content := strings.concatenate({strings.trim_right(body, "\n"), "\n"}, context.allocator)
	if err := os.write_entire_file(path, transmute([]u8)content); err != nil {
		die(fmt.tprintf("cannot write %s", path))
	}
}

cmd_new :: proc(args: []string) {
	dir := ""
	port := ""
	port_explicit := false

	i := 0
	for i < len(args) {
		a := args[i]
		switch {
		case a == "--port":
			if i + 1 >= len(args) {
				die("--port needs a number")
			}
			port = args[i + 1]
			port_explicit = true
			i += 2
		case strings.has_prefix(a, "-"):
			die(
				fmt.tprintf("unknown option for `otsh new`: %s", a),
				"usage: otsh new <dir> [--port N]",
			)
		case:
			dir = a
			i += 1
		}
	}
	if dir == "" {
		die("otsh new needs a directory", "usage: otsh new <dir> [--port N]")
	}
	if port_explicit {
		if !all_digits(port) {
			die(fmt.tprintf("--port must be a number, got '%s'", port))
		}
	} else {
		// Not 2222 by assumption: 2222 is what examples/tracker uses, so a
		// reader following the README and then making their own app would
		// collide on their very first run. Pick one that is actually free.
		port = fmt.aprintf("%d", first_free_port(2222))
	}

	// Refuse rather than merge: overwriting somebody's main.odin because they
	// reused a path is not a mistake worth being clever about.
	if os.exists(dir) {
		empty := false
		if os.is_directory(dir) {
			entries, err := os.read_all_directory_by_path(dir, context.allocator)
			empty = err == nil && len(entries) == 0
		}
		if !empty {
			die(
				fmt.tprintf("%s already exists", dir),
				"pick a path that does not, or empty this one first",
			)
		}
	}

	if !mkdir_p(dir) {
		die(fmt.tprintf("cannot create %s", dir))
	}
	dir_abs := abs_path(dir)
	name := sanitize_name(filepath.base(dir_abs))
	minor := otsh_version_minor()

	write_scaffold(
		fmt.aprintf("%s/main.odin", dir_abs),
		subst(MAIN_TMPL, {"@NAME@", name}, {"@PORT@", port}, {"@MINOR@", minor}),
	)

	build_sh := fmt.aprintf("%s/build.sh", dir_abs)
	write_scaffold(build_sh, subst(BUILD_TMPL, {"@OTSH@", OTSH}))
	// What `chmod +x` did to a fresh 0644 file: 0755.
	mode_0755 := os.Permissions{
		.Read_User, .Write_User, .Execute_User,
		.Read_Group, .Execute_Group,
		.Read_Other, .Execute_Other,
	}
	if err := os.change_mode(build_sh, mode_0755); err != nil {
		die(fmt.tprintf("cannot chmod %s", build_sh))
	}

	write_scaffold(
		fmt.aprintf("%s/.gitignore", dir_abs),
		subst(IGNORE_TMPL, {"@NAME@", name}),
	)

	fmt.printf(
		`%s: created %s

  main.odin    three procs and a config — start here
  build.sh     builds against %s
  .gitignore   host key, identity secret, build output

next:
  cd %s
  ./build.sh && ./%s
  ssh -p %s localhost        # from another terminal

or, without leaving this one:
  otsh run %s --local
`,
		PROG,
		dir_abs,
		OTSH,
		dir_abs,
		name,
		port,
		dir_abs,
	)
}
