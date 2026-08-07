// otsh — one command for starting, building and running SSH-served TUIs.
//
//	otsh new ~/src/myapp      scaffold a project that builds and serves as-is
//	otsh run ~/src/myapp      build it and start it
//	otsh build ~/src/myapp    build it
//	otsh flags                print the two flags, for your own build system
//	otsh doctor               check the three things that actually go wrong
//
// This is the compiled tool behind the `otsh` entry point at the repository
// root. It used to be a ~900-line bash script; it is Odin now because the
// script did not merely degrade off bash — it did not run at all on a stock
// Alpine, on FreeBSD, or on any Linux stripped to essentials, and macOS's
// /bin/bash is a 3.2 whose heredoc parsing has already cost this project one
// real bug. Every command, message and exit code here is a port of that
// script; the script's comments explaining *why* each behaviour exists have
// moved with the code they explain.
//
// The `otsh` file at the repository root is now a small POSIX-sh bootstrap:
// it builds this package into bin/ on first use and execs it thereafter, so
// having Odin installed is the only requirement — which it always was, since
// the whole point of the tool is driving that compiler. See the bootstrap's
// own comments for what happens when Odin is missing.
//
// The tool needs to know where the otsh checkout is, because
// -collection:otsh= names a source tree. Resolution order:
//
//   $OTSH_ROOT              explicit, for a prebuilt binary living elsewhere
//   walk up from the executable's real path (through symlinks) to the first
//   directory containing ssh/version.odin — covers bin/otsh inside the
//   checkout, and a symlink on $PATH pointing into one
//
// Nothing here changes how otsh is distributed: -collection:otsh= still
// points at a source tree, and the version your app uses is still whatever
// commit that checkout is on.
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// build.sh and test.sh set OTSH_PROG so their diagnostics still say
// "build.sh:" rather than pointing at a wrapper the caller never invoked.
PROG: string

// The checkout root. See resolve_checkout.
OTSH: string

EXE_SUFFIX :: ".exe" when ODIN_OS == .Windows else ""

die :: proc(msg: string, lines: ..string) -> ! {
	fmt.eprintf("%s: %s\n", PROG, msg)
	for l in lines {
		fmt.eprintf("  %s\n", l)
	}
	os.exit(1)
}

// Not argv[0]: the supported install is a symlink on $PATH, and
// -collection:otsh= has to name the checkout it points at, not ~/.local/bin.
// The executable's real path (symlinks resolved) is inside the checkout —
// bin/otsh — so the checkout is the first ancestor carrying ssh/version.odin.
// $OTSH_ROOT overrides for a prebuilt binary that lives nowhere near one; it
// is the same variable the scaffolded build.sh already honours.
resolve_checkout :: proc() -> string {
	if root := os.get_env("OTSH_ROOT", context.allocator); root != "" {
		if abs, err := os.get_absolute_path(root, context.allocator); err == nil {
			return abs
		}
		return root
	}
	exe, err := os.get_executable_path(context.allocator)
	if err != nil {
		return "."
	}
	exe_dir := filepath.dir(real_path(exe))
	dir := exe_dir
	for _ in 0 ..< 8 {
		marker := path_join(dir, "ssh", "version.odin")
		if os.is_file(marker) {
			return dir
		}
		parent := filepath.dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	// Outside any checkout — a prebuilt binary with no $OTSH_ROOT. Behave the
	// way the old script did when copied out of its checkout: version reports
	// "(unknown)" and doctor's collection check names what is missing.
	return exe_dir
}

main :: proc() {
	PROG = os.get_env("OTSH_PROG", context.allocator)
	if PROG == "" {
		PROG = "otsh"
	}
	OTSH = resolve_checkout()

	cmd := "help"
	rest: []string
	if len(os.args) > 1 {
		cmd = os.args[1]
		rest = os.args[2:]
	}

	switch cmd {
	case "new":
		cmd_new(rest)
	case "build":
		cmd_build(rest)
	case "run":
		cmd_run(rest)
	case "test":
		cmd_test(rest)
	case "flags":
		cmd_flags(rest)
	case "install":
		cmd_install(rest)
	case "use-odin", "use_odin":
		cmd_use_odin(rest)
	case "doctor":
		os.exit(cmd_doctor())
	case "version", "--version", "-v":
		cmd_version()
	case "help", "--help", "-h":
		print_help(false)
	case:
		fmt.eprintf("%s: unknown command: %s\n\n", PROG, cmd)
		print_help(true)
		os.exit(1)
	}
}
