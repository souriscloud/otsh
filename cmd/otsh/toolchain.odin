// Finding the Odin compiler, and remembering where it is.
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// What the script called $ODIN after resolve_odin ran.
ODIN_BIN: string
@(private = "file")
odin_resolved: bool

// Where a user-level compiler path lives. This is the one a *consumer* of
// otsh should use: the checkout is a dependency, and configuration does not
// belong inside a dependency — pin a second version, or re-clone, and an
// .odin-path written in there is gone. `otsh use-odin` writes this file.
odin_conf_path :: proc() -> string {
	xdg := os.get_env("XDG_CONFIG_HOME", context.allocator)
	if xdg == "" {
		xdg = path_join(home_dir(), ".config")
	}
	return path_join(xdg, "otsh", "odin-path")
}

// Compiler resolution, most specific first:
//   $ODIN                     this invocation only
//   $OTSH/.odin-path          this checkout (gitignored; for otsh's own devs)
//   the use-odin config file  this user, every checkout and project
//   odin                      $PATH
// Each file is only taken when what it names actually resolves. One checkout
// can be seen by two machines at once — a container with the worktree bind
// mounted in, for instance — and a path written on the other one must not
// shadow a perfectly good `odin` on this one's $PATH.
resolve_odin :: proc() {
	if odin_resolved {
		return
	}
	odin_resolved = true

	ODIN_BIN = os.get_env("ODIN", context.allocator)
	if ODIN_BIN == "" {
		files := [2]string{
			path_join(OTSH, ".odin-path"),
			odin_conf_path(),
		}
		for f in files {
			if !os.is_file(f) {
				continue
			}
			data, err := os.read_entire_file(f, context.allocator)
			if err != nil {
				continue
			}
			candidate := chomp(string(data))
			if _, ok := lookup_path(candidate); ok {
				ODIN_BIN = candidate
				break
			}
		}
	}

	// Nothing configured and nothing on $PATH: look where Odin actually ends
	// up when people build it from source or unpack a nightly. Getting this
	// right is the difference between "it just worked" and a first run that
	// stops to ask a question the tool could have answered itself. Explicit
	// settings above always win; this only ever fires as a last resort.
	if ODIN_BIN == "" {
		if _, on_path := lookup_path("odin"); !on_path {
			home := home_dir()
			odin_root := os.get_env("ODIN_ROOT", context.allocator)
			candidates := [?]string{
				strings.concatenate({odin_root, "/odin"}, context.allocator),
				path_join(home, "odin", "odin"),
				path_join(home, ".odin", "odin"),
				path_join(home, "src", "Odin", "odin"),
				path_join(home, "src", "odin", "odin"),
				path_join(home, "Odin", "odin"),
				path_join(home, "dev", "Odin", "odin"),
				"/usr/local/odin/odin",
				"/opt/odin/odin",
				"/opt/Odin/odin",
			}
			for cand in candidates {
				if cand == "/odin" { // empty $ODIN_ROOT
					continue
				}
				if is_executable_file(cand) && run_ok({cand, "version"}) {
					ODIN_BIN = cand
					break
				}
			}
		}
	}

	if ODIN_BIN == "" {
		ODIN_BIN = "odin"
	}
}

require_odin :: proc() {
	resolve_odin()
	if _, ok := lookup_path(ODIN_BIN); !ok {
		die(
			fmt.tprintf("odin compiler not found (tried '%s').", ODIN_BIN),
			"Install it from https://odin-lang.org, or if you have it somewhere",
			"custom, record that once for every project:",
			fmt.tprintf("    %s use-odin /path/to/odin", PROG),
			fmt.tprintf("For a single command, ODIN=/path/to/odin %s ... also works.", PROG),
		)
	}
}

// What this binary was built from, stamped in at compile time by the release
// job (-define:OTSH_TOOL_VERSION=0.4.0). Empty for a locally built tool, where
// the checkout below is the better answer anyway. It exists because a binary
// downloaded from a release and run on its own could otherwise not say what it
// was — the release smoke test never caught that, because it runs `version`
// from inside a checkout.
TOOL_VERSION :: #config(OTSH_TOOL_VERSION, "")

// The version of this checkout, read off the source of truth rather than
// repeated here: ssh/version.odin is what an app's #assert compares against.
// Absent only when this binary is outside any checkout — say so rather than
// inventing a number.
otsh_version :: proc() -> string {
	path := path_join(OTSH, "ssh", "version.odin")
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return "(unknown)"
	}
	for line in strings.split_lines(string(data), context.allocator) {
		if strings.has_prefix(line, "VERSION ::") {
			parts := strings.split(line, "\"", context.allocator)
			if len(parts) >= 2 {
				return parts[1]
			}
			return ""
		}
	}
	return ""
}

otsh_version_minor :: proc() -> string {
	path := path_join(OTSH, "ssh", "version.odin")
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return "0"
	}
	for line in strings.split_lines(string(data), context.allocator) {
		if strings.has_prefix(line, "VERSION_MINOR ::") {
			fields := strings.fields(line, context.allocator)
			if len(fields) >= 3 {
				return fields[2]
			}
		}
	}
	return ""
}

// Record a compiler path for this user, once, for every checkout and project.
cmd_use_odin :: proc(args: []string) {
	conf := odin_conf_path()
	path := ""
	if len(args) > 0 {
		path = args[0]
	}

	if path == "" {
		resolve_odin()
		if os.is_file(conf) {
			data, _ := os.read_entire_file(conf, context.allocator)
			fmt.printf("%s -> %s\n", conf, chomp(string(data)))
		} else {
			fmt.printf("no user setting (%s does not exist)\n", conf)
		}
		if resolved, ok := lookup_path(ODIN_BIN); ok {
			fmt.printf("currently resolving to: %s\n", resolved)
		} else {
			fmt.printf("currently resolving to: %s (not found)\n", ODIN_BIN)
		}
		fmt.printf("\nusage: %s use-odin /path/to/odin   (or --unset)\n", PROG)
		return
	}
	if path == "--unset" {
		os.remove(conf)
		fmt.printf("%s: removed %s\n", PROG, conf)
		return
	}
	// Refuse a path that will not work, rather than writing it and failing on
	// the next build with a message pointing somewhere else.
	if _, ok := lookup_path(path); !ok {
		die(fmt.tprintf("not an executable: %s", path))
	}
	ver_out, ver_ok := run_capture({path, "version"})
	if !ver_ok {
		die(fmt.tprintf("%s does not answer `odin version`; is it the Odin compiler?", path))
	}
	conf_dir := filepath.dir(conf)
	if !mkdir_p(conf_dir) {
		die(fmt.tprintf("cannot create %s", conf_dir))
	}
	content := strings.concatenate({path, "\n"}, context.allocator)
	if err := os.write_entire_file(conf, transmute([]u8)content); err != nil {
		die(fmt.tprintf("cannot write %s", conf))
	}
	fmt.printf("%s: %s -> %s (%s)\n", PROG, conf, path, first_line(ver_out))
}
