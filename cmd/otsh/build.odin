// build, run, test — the commands that drive the compiler.
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Every Odin flag is a single `-flag` or `-flag:value` token, so a bare word
// is unambiguously the package directory. That is what lets `otsh build
// ~/app -o:speed` and `otsh test -define:X` both do the obvious thing.
split_args :: proc(args: []string) -> (src: string, odin_args: [dynamic]string) {
	odin_args = make([dynamic]string, context.allocator)
	for a in args {
		if strings.has_prefix(a, "-") {
			append(&odin_args, a)
		} else if src == "" {
			src = a
		} else {
			append(&odin_args, a)
		}
	}
	return
}

// A directory with no .odin file in it is the mistake worth naming: a typo in
// a path, or a project that was never scaffolded.
require_package :: proc(dir: string) {
	if !os.is_directory(dir) {
		die(
			fmt.tprintf("no such directory: %s", dir),
			fmt.tprintf("otsh new %s   creates a project there", dir),
		)
	}
	pattern := strings.concatenate({dir, "/*.odin"}, context.allocator)
	matches, err := filepath.glob(pattern, context.allocator)
	if err != nil || len(matches) == 0 {
		die(
			fmt.tprintf("%s has no .odin files — not an Odin package.", dir),
			"otsh new <dir>   creates one that builds and serves as-is",
		)
	}
}

cmd_build :: proc(args: []string, quiet_for_run := false) {
	out, out_dir: string
	static_mode, full_static: bool
	plain := make([dynamic]string, context.allocator)

	i := 0
	for i < len(args) {
		switch args[i] {
		case "--out":
			if i + 1 >= len(args) {
				die("--out needs a path")
			}
			out = args[i + 1]
			i += 2
		case "--out-dir":
			if i + 1 >= len(args) {
				die("--out-dir needs a path")
			}
			out_dir = args[i + 1]
			i += 2
		case "--static":
			static_mode = true
			i += 1
		case "--fully-static":
			static_mode = true
			full_static = true
			i += 1
		case:
			append(&plain, args[i])
			i += 1
		}
	}

	src, odin_args := split_args(plain[:])
	if src == "" {
		src = "."
	}
	require_package(src)
	require_odin()

	define_flag := ""
	if static_mode {
		resolve_libssh_static(full_static)
		define_flag = strings.concatenate({"-define:OTSH_LIBSSH=system:", LIBSSH_A}, context.allocator)
		LDFLAGS = STATIC_LIBS
	} else {
		resolve_libssh()
	}

	// Odin takes exactly one -extra-linker-flags — a second is rejected with
	// "Previous flag set: 'extra-linker-flags'" — so a caller's own linker
	// flags have to be folded into ours rather than passed through beside
	// them. This is what lets somebody add the one library their
	// distribution's libssh happens to need without giving up everything otsh
	// resolved for them.
	passthrough := make([dynamic]string, context.allocator)
	for a in odin_args {
		if strings.has_prefix(a, "-extra-linker-flags:") {
			LDFLAGS = fmt.aprintf("%s %s", LDFLAGS, a[len("-extra-linker-flags:"):])
		} else {
			append(&passthrough, a)
		}
	}

	// The binary is named after the package directory and lands *in* it, so
	// that a project keeps its own build output, and so that `otsh run` can
	// start it from there — an app's host_key_path is relative to its working
	// directory, and a host key scattered wherever you happened to be
	// standing is how clients end up seeing key-mismatch warnings.
	src_abs := abs_path(src)
	name := strings.concatenate({filepath.base(src_abs), EXE_SUFFIX}, context.allocator)
	if out_dir != "" {
		out = fmt.aprintf("%s/%s", out_dir, name)
	}
	if out == "" {
		out = fmt.aprintf("%s/%s", src_abs, name)
	}

	// An explicit -out: in the passthrough flags wins; Odin would reject two.
	want_out_flag := true
	for a in passthrough {
		if strings.has_prefix(a, "-out:") {
			want_out_flag = false
			out = ""
		}
	}

	argv := make([dynamic]string, context.allocator)
	append(&argv, ODIN_BIN, "build", src)
	if want_out_flag {
		append(&argv, strings.concatenate({"-out:", out}, context.allocator))
	}
	append(&argv, strings.concatenate({"-collection:otsh=", OTSH}, context.allocator))
	if define_flag != "" {
		append(&argv, define_flag)
	}
	append(&argv, strings.concatenate({"-extra-linker-flags:", LDFLAGS}, context.allocator))
	append(&argv, ..passthrough[:])

	if code := run_inherit(argv[:]); code != 0 {
		os.exit(code)
	}

	quiet := quiet_for_run || os.get_env("OTSH_QUIET", context.allocator) == "1"
	if out != "" && !quiet {
		fmt.printf("%s: built %s\n", PROG, out)
	}
}

cmd_run :: proc(args: []string) {
	// Everything after the directory is the *program's* argv, not the
	// compiler's — `otsh run ~/src/myapp --local` is the whole point. Build
	// with flags via `otsh build` first if you need them.
	src := ""
	app_args := args
	if len(args) > 0 && !strings.has_prefix(args[0], "-") {
		src = args[0]
		app_args = args[1:]
	}
	if src == "" {
		src = "."
	}
	require_package(src)

	src_abs := abs_path(src)
	name := strings.concatenate({filepath.base(src_abs), EXE_SUFFIX}, context.allocator)
	cmd_build({src_abs}, quiet_for_run = true)

	fmt.printf("%s: running %s\n", PROG, fmt.aprintf("%s/%s", src_abs, name))
	// From the project's own directory: host keys, identity secrets and
	// anything else the app opens by relative path belong beside its source.
	if err := os.set_working_directory(src_abs); err != nil {
		die(fmt.tprintf("cannot enter %s", src_abs))
	}
	argv := make([dynamic]string, context.allocator)
	append(&argv, strings.concatenate({"./", name}, context.allocator))
	append(&argv, ..app_args)

	p, err := os.process_start(
		os.Process_Desc{
			command = argv[:],
			stdin   = os.stdin,
			stdout  = os.stdout,
			stderr  = os.stderr,
		},
	)
	if err != nil {
		die(fmt.tprintf("cannot run ./%s: %v", name, err))
	}
	// The script used `exec`, so Ctrl+C only ever reached the app. We wait on
	// it instead; shrug off the SIGINT the terminal sends the whole group and
	// let the app decide, then pass its exit code through.
	ignore_sigint()
	state, werr := os.process_wait(p)
	if werr != nil {
		os.exit(1)
	}
	os.exit(state.exit_code)
}

cmd_test :: proc(args: []string) {
	src, odin_args := split_args(args)
	if src == "" {
		src = path_join(OTSH, "tests")
	}
	require_odin()
	resolve_libssh()
	argv := make([dynamic]string, context.allocator)
	append(&argv, ODIN_BIN, "test", src)
	append(&argv, strings.concatenate({"-collection:otsh=", OTSH}, context.allocator))
	append(&argv, strings.concatenate({"-extra-linker-flags:", LDFLAGS}, context.allocator))
	append(&argv, ..odin_args[:])
	os.exit(run_inherit(argv[:]))
}
