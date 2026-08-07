// otsh doctor — check the three things that actually go wrong.
//
// The bootstrap script at the repository root carries a POSIX-sh copy of this
// checklist for the one machine state where this binary cannot exist: no Odin
// compiler to build it with. The two must say the same things — change one,
// change the other.
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

@(private = "file")
fails: int
@(private = "file")
warns: int

@(private = "file")
d_ok :: proc(what, detail: string) {
	fmt.printf("  ok    %-9s %s\n", what, detail)
}

@(private = "file")
d_no :: proc(what, detail: string, lines: ..string) {
	fmt.printf("  FAIL  %-9s %s\n", what, detail)
	for l in lines {
		fmt.printf("        %-9s %s\n", "", l)
	}
	fails += 1
}

@(private = "file")
d_warn :: proc(what, detail: string, lines: ..string) {
	fmt.printf("  warn  %-9s %s\n", what, detail)
	for l in lines {
		fmt.printf("        %-9s %s\n", "", l)
	}
	warns += 1
}

@(private = "file")
d_skip :: proc(what, detail: string) {
	fmt.printf("  --    %-9s %s\n", what, detail)
}

cmd_doctor :: proc() -> int {
	fmt.printf("otsh doctor — %s\n\n", OTSH)
	fails = 0
	warns = 0

	// 1. the compiler
	resolve_odin()
	if resolved, found := lookup_path(ODIN_BIN); found {
		// `odin version` prints "<path> version <tag>"; only the tag is news.
		tag := ""
		out, _ := run_capture({ODIN_BIN, "version"})
		fields := strings.fields(first_line(out), context.allocator)
		if len(fields) > 0 {
			tag = fields[len(fields) - 1]
		}
		d_ok("odin", fmt.tprintf("%s  (%s)", resolved, tag))
	} else {
		d_no(
			"odin",
			fmt.tprintf("not found (tried '%s')", ODIN_BIN),
			"install from https://odin-lang.org, or if it lives somewhere",
			fmt.tprintf("custom: %s use-odin /path/to/odin", PROG),
		)
	}

	// 2. libssh, against the floor ssh.serve enforces at runtime. 0.10.6 is
	//    where the CVE-2023-48795 (Terrapin) fix landed; anything older
	//    compiles and then refuses to bind.
	resolve_libssh()
	libssh_ver := libssh_version()
	if libssh_ver != "" && !version_ge(libssh_ver, "0.10.6") {
		d_no(
			"libssh",
			fmt.tprintf("%s is below the 0.10.6 floor — ssh.serve will refuse to start", libssh_ver),
			"0.10.6 carries the fix for CVE-2023-48795 (Terrapin).",
		)
	} else if !libssh_lib_present() {
		// LIBDIR is what otsh hands the linker, so "a version exists
		// somewhere" is not the same as "this build will link". Say which one
		// is true.
		if libssh_ver != "" {
			d_warn(
				"libssh",
				fmt.tprintf("headers say %s, but there is no libssh in %s", libssh_ver, LIBDIR),
				"that is the path otsh passes to the linker — install pkg-config so it is found properly",
			)
		} else {
			d_no(
				"libssh",
				fmt.tprintf("not found (looked in %s)", LIBDIR),
				"brew install libssh pkg-config     # macOS",
				"apt install libssh-dev pkg-config  # Debian/Ubuntu",
				"vcpkg install libssh:x64-windows   # Windows",
			)
		}
	} else if libssh_ver != "" {
		d_ok("libssh", fmt.tprintf("%s  (>= 0.10.6)  %s", libssh_ver, LIBDIR))
	} else {
		d_warn(
			"libssh",
			fmt.tprintf("%s has the library but no version to check", LIBDIR),
			"install pkg-config or the libssh headers; the 0.10.6 floor is enforced at run time regardless",
		)
	}

	// 3. clang. Odin shells out to it to link. On Linux nothing else will do
	//    — gcc is not a substitute, and the failure is an opaque
	//    "sh: 1: clang: not found" from inside the compiler. Elsewhere its
	//    absence is not fatal (macOS ships it with the Command Line Tools;
	//    Windows links with MSVC), so it is reported, not required.
	if clang, found := lookup_path("clang"); found {
		d_ok("clang", clang)
	} else if UNAME == "Linux" {
		d_no(
			"clang",
			"not found — Odin links with it on Linux",
			"apt install clang  (build-essential is not a substitute)",
		)
	} else {
		d_skip("clang", fmt.tprintf("not found — not required on %s", UNAME))
	}

	// 4. the collection itself, which is the thing a stale symlink breaks.
	missing := ""
	pkgs := [4]string{"libssh", "ssh", "tui", "sshtui"}
	for pkg in pkgs {
		if !os.is_directory(path_join(OTSH, pkg)) {
			missing = fmt.aprintf("%s %s", missing, pkg)
		}
	}
	if missing == "" {
		d_ok("otsh", fmt.tprintf("%s  (libssh, ssh, tui, sshtui)", otsh_version()))
	} else {
		d_no(
			"otsh",
			fmt.tprintf("%s is missing package(s):%s", OTSH, missing),
			"this file must stay inside the checkout; symlink it, do not copy it",
		)
	}

	fmt.printf("\n")
	if fails > 0 {
		fmt.printf("%d problem(s) — nothing will build until these are fixed\n", fails)
		return 1
	}
	if warns > 0 {
		fmt.printf("no blockers, %d warning(s)\n", warns)
		return 0
	}
	fmt.printf("all good\n")
	return 0
}
