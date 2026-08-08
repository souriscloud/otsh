// help, version, flags — the commands that only print.
package main

import "core:fmt"
import "core:os"

print_help :: proc(to_stderr: bool) {
	text := fmt.aprintf(
		`otsh %s — SSH-served TUIs in Odin
%s

usage: otsh <command> [arguments]

  new <dir> [--port N]   scaffold a project that builds and serves as-is
                         (picks a free port unless you name one)
  build [dir] [flags]    build a project; extra flags go to ` +
		"`odin build`" + `
                         --static        link libssh from its archive, so the
                                         binary needs no libssh installed
                         --fully-static  no dynamic dependencies at all
                                         (Linux only — see docs)
  run [dir] [args]       build, then run it from its own directory
  test [dir] [flags]     run a package's tests (default: otsh's own suite)
  flags [--static]       print the -collection: and -extra-linker-flags:
                         values, for a Makefile, justfile or IDE
  install                put ` + "`otsh`" + ` on your $PATH (or --uninstall)
  use-odin [path]        record where your Odin compiler lives (or --unset)
  doctor                 check odin, libssh and clang
  version                version and checkout of this otsh
  help                   this

The first bare word is the package directory; everything starting with a dash
is passed through to the compiler.

  otsh new ~/src/myapp
  otsh run ~/src/myapp          # then: ssh -p 2222 localhost
  otsh build ~/src/myapp -o:speed

To have it on your PATH from anywhere, symlink it — the file stays here,
because this checkout is what your app compiles against:

  ln -s %s/otsh ~/.local/bin/otsh

docs: %s/docs/getting-started.md
`,
		otsh_version(),
		OTSH,
		OTSH,
		OTSH,
	)
	if to_stderr {
		os.write_string(os.stderr, text)
	} else {
		os.write_string(os.stdout, text)
	}
}

cmd_version :: proc() {
	// Two different questions, and a standalone binary can only answer the
	// first: which tool is this, and which source tree will it build against.
	v := otsh_version()
	if v == "(unknown)" && TOOL_VERSION != "" {
		fmt.printf("otsh %s (tool)\n", TOOL_VERSION)
		fmt.printf("  source   %s — no otsh checkout here\n", OTSH)
		fmt.printf("  hint     run it from a checkout, or set OTSH_ROOT=/path/to/otsh\n")
		return
	}
	if TOOL_VERSION != "" && TOOL_VERSION != v {
		fmt.printf("otsh %s  (tool built from %s)\n", v, TOOL_VERSION)
	} else {
		fmt.printf("otsh %s\n", v)
	}
	fmt.printf("  source   %s\n", OTSH)
	// The commit is the real pin: -collection:otsh= names a source tree, so
	// an app's version is whatever that tree is checked out at, not a tag it
	// once had. Absent outside a git checkout, which is fine — say nothing
	// then.
	if _, ok := lookup_path("git"); ok {
		out, described := run_capture({"git", "-C", OTSH, "describe", "--tags", "--always", "--dirty"})
		if described && chomp(out) != "" {
			fmt.printf("  commit   %s\n", chomp(out))
		}
	}
}

cmd_flags :: proc(args: []string) {
	static_mode := false
	full_static := false
	if len(args) > 0 {
		switch args[0] {
		case "--static":
			static_mode = true
		case "--fully-static":
			static_mode = true
			full_static = true
		case:
			die(fmt.tprintf("usage: %s flags [--static | --fully-static]", PROG))
		}
	}

	// Two lines normally, three with --static, nothing else on stdout, so
	// this can be read by eye or by a script. Paste these, do not
	// $(otsh flags) them — the linker value contains a space, so word
	// splitting turns it into two arguments and odin reports
	// `Unknown flag: 'Wl,-rpath,...'`. In a script use
	//   eval "odin build . $(otsh flags | tr '\n' ' ')"
	// which re-parses the quoting. Resolved before anything is printed, so a
	// mode this platform cannot do fails with an empty stdout rather than
	// half a flag list somebody might paste.
	if static_mode {
		resolve_libssh_static(full_static)
	} else {
		resolve_libssh()
	}

	fmt.printf("-collection:otsh=%s\n", OTSH)
	if static_mode {
		fmt.printf("-define:OTSH_LIBSSH=system:%s\n", LIBSSH_A)
		fmt.printf("-extra-linker-flags:\"%s\"\n", STATIC_LIBS)
	} else {
		fmt.printf("-extra-linker-flags:\"%s\"\n", LDFLAGS)
	}
}
