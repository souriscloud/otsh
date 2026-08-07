// Locating libssh — dynamically for a normal build, as archives for a static
// one — and everything doctor needs to say about it.
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Set by resolve_libssh / resolve_libssh_static, exactly like the script's
// shell variables of the same names.
LIBDIR: string
LDFLAGS: string
LIBSSH_A: string
STATIC_LIBS: string

pkg_config_available :: proc() -> bool {
	_, ok := lookup_path("pkg-config")
	return ok
}

// libssh is not on the default linker search path on macOS/Homebrew, and on
// Windows it is not on any path at all. Sets LIBDIR and LDFLAGS.
resolve_libssh :: proc() {
	when ODIN_OS == .Windows {
		// This branch exists so the tool behaves identically to the script CI
		// and Git Bash ran on Windows 11 with vcpkg libssh 0.12.0 on
		// 2026-07-31. vcpkg is the expected libssh provider on Windows, and
		// the MSVC linker spells a library search path /LIBPATH:, not -L.
		// There is no rpath equivalent — ssh.dll has to be on %PATH% at run
		// time.
		vcpkg := os.get_env("VCPKG_ROOT", context.allocator)
		if vcpkg == "" {
			vcpkg = os.get_env("VCPKG_INSTALLATION_ROOT", context.allocator)
		}
		if vcpkg == "" {
			vcpkg = "C:/vcpkg"
		}
		LIBDIR = strings.concatenate({vcpkg, "/installed/x64-windows/lib"}, context.allocator)
		LDFLAGS = strings.concatenate({"/LIBPATH:", LIBDIR}, context.allocator)
	} else {
		if pkg_config_available() && run_ok({"pkg-config", "--exists", "libssh"}) {
			out, _ := run_capture({"pkg-config", "--variable=libdir", "libssh"})
			LIBDIR = chomp(out)
		} else if os.is_directory("/opt/homebrew/opt/libssh/lib") {
			LIBDIR = "/opt/homebrew/opt/libssh/lib"
		} else {
			LIBDIR = "/usr/local/lib"
		}
		LDFLAGS = fmt.aprintf("-L%s -Wl,-rpath,%s", LIBDIR, LIBDIR)
	}
}

// --- static linking -----------------------------------------------------------
//
// Two modes, because the platforms genuinely differ and pretending otherwise
// would ship a flag that fails confusingly on one of them:
//
//   --static        libssh and its crypto/compression dependencies come from
//                   archives; the platform C library stays dynamic. Works on
//                   macOS and Linux. On macOS this is the most that exists.
//   --fully-static  the above plus `-static`: no dynamic dependencies at all.
//                   Linux only.
//
// The mechanism is libssh/libssh.odin's OTSH_LIBSSH define. `-lssh` resolves
// to the shared library before an archive on every linker tested, so adding
// libssh.a to the command line does nothing while the `-l` is still there;
// the define replaces the `-l` with the archive's own path. See the comment
// on LIB in libssh/libssh.odin and docs/static-linking.md.
//
// Everything below is a search for archives that a package manager may or may
// not have installed. It reports what is missing rather than handing the
// linker a half-built command line, because the linker's version of "you are
// missing libcrypto.a" is four hundred lines of undefined BN_* symbols.

// Directories worth searching for an archive, most specific first.
static_search_dirs :: proc() -> []string {
	dirs := make([dynamic]string, context.allocator)
	append(&dirs, LIBDIR)
	if pkg_config_available() {
		mods := [3]string{"libcrypto", "zlib", "libzstd"}
		for m in mods {
			if run_ok({"pkg-config", "--exists", m}) {
				if out, ok := run_capture({"pkg-config", "--variable=libdir", m}); ok {
					append(&dirs, chomp(out))
				}
			}
		}
	}
	// Homebrew keeps OpenSSL outside its main prefix on purpose — macOS ships
	// its own ancient libcrypto in /usr/lib and Homebrew will not shadow it —
	// so the keg has to be named separately.
	append(
		&dirs,
		"/opt/homebrew/opt/openssl@3/lib",
		"/usr/local/opt/openssl@3/lib",
		"/opt/homebrew/lib",
		"/usr/local/lib",
	)
	// Debian/Ubuntu multiarch, then the usual suspects.
	if matches, err := filepath.glob("/usr/lib/*-linux-gnu*", context.allocator); err == nil {
		for m in matches {
			if os.is_directory(m) {
				append(&dirs, m)
			}
		}
	}
	tail := [2]string{"/usr/lib64", "/usr/lib"}
	for d in tail {
		if os.is_directory(d) {
			append(&dirs, d)
		}
	}
	return dirs[:]
}

// Absolute path of lib<name>.a if one exists.
find_archive :: proc(name: string) -> (path: string, found: bool) {
	for d in static_search_dirs() {
		p := fmt.aprintf("%s/lib%s.a", d, name)
		if os.is_file(p) {
			return p, true
		}
	}
	return "", false
}

// Whether libssh.a was built with GSSAPI is a property of how it was built,
// not of the platform. Ask the archive rather than guessing.
libssh_a_wants_gssapi :: proc(archive: string) -> bool {
	out, _ := run_capture({"nm", "-u", archive})
	return strings.contains(out, "gss_acquire_cred")
}

// Sets LIBSSH_A and STATIC_LIBS.
resolve_libssh_static :: proc(want_full: bool) {
	resolve_libssh()

	when ODIN_OS == .Windows {
		die(
			"static linking is not supported on Windows.",
			"vcpkg's libssh:x64-windows triplet is a DLL plus an import library;",
			"there is no libssh.lib to link. x64-windows-static builds one, but",
			"otsh has never been tested against it — see docs/static-linking.md.",
		)
	}

	if want_full && UNAME == "Darwin" {
		die(
			"macOS cannot link a fully static executable.",
			"Apple ships no static libSystem or libc.a — the SDK has neither, and",
			"clang stops at `ld: library 'crt0.o' not found`. Statically linked",
			"binaries are unsupported on Darwin and have been for many releases.",
			"Use --static instead: it removes the libssh, libcrypto and Kerberos",
			"dependencies and leaves only libSystem, which every mac already has.",
		)
	}

	LIBSSH_A = strings.concatenate({LIBDIR, "/libssh.a"}, context.allocator)
	if !os.is_file(LIBSSH_A) {
		die(
			fmt.tprintf("no libssh.a in %s — nothing to link statically.", LIBDIR),
			"That directory has the shared library otsh normally links against,",
			"but no archive beside it. Some distributions ship one and some do not:",
			"  brew install libssh              # macOS: ships libssh.a",
			"  apt install libssh-dev           # Debian/Ubuntu: ships libssh.a",
			"  Alpine's libssh-dev ships only libssh.so — build libssh yourself",
			"See docs/static-linking.md for building libssh as an archive.",
		)
	}

	// libssh cannot do anything without a crypto backend.
	crypto_a, crypto_found := find_archive("crypto")
	if !crypto_found {
		die(
			"found libssh.a but no libcrypto.a to go with it.",
			"libssh's crypto backend is OpenSSL on every platform otsh is built on.",
			"  brew install openssl@3           # macOS",
			"  apt install libssl-dev           # Debian/Ubuntu",
			"  apk add openssl-libs-static      # Alpine",
		)
	}
	libs := make([dynamic]string, context.allocator)
	append(&libs, crypto_a)

	// zlib. Linux distributions ship libz.a; macOS ships only the dylib (the
	// SDK has libz.tbd stubs and no archive at all), so there it stays
	// dynamic — which is harmless, because libz is part of the OS.
	if z_a, z_found := find_archive("z"); z_found {
		append(&libs, z_a)
	} else {
		append(&libs, "-lz")
	}

	// Whatever else this OpenSSL was built against. libssh's own .pc file
	// declares no static dependencies whatsoever — `pkg-config --static
	// --libs libssh` prints just `-lssh` on Homebrew 0.12.2 and Debian 0.11.5
	// alike — but libcrypto's does, and on Debian it names zstd, without
	// which the link dies on ZSTD_decompressStream. Each -l becomes an
	// archive where one exists, because passing `-lfoo` next to libfoo.a
	// still records a dependency on the shared object and produces a
	// "static" binary that is nothing of the sort.
	if pkg_config_available() && run_ok({"pkg-config", "--exists", "libcrypto"}) {
		out, _ := run_capture({"pkg-config", "--static", "--libs", "libcrypto"})
		for tok in strings.fields(out, context.allocator) {
			switch {
			case tok == "-lcrypto" || tok == "-lz" || strings.has_prefix(tok, "-L"):
			// already placed above
			case strings.has_prefix(tok, "-l"):
				if a, found := find_archive(tok[2:]); found {
					append(&libs, a)
				} else {
					append(&libs, tok)
				}
			case:
				append(&libs, tok) // -pthread and friends
			}
		}
	}

	// GSSAPI. Whether libssh.a needs Kerberos is a property of how it was
	// built, not of the platform: Debian builds it with GSSAPI on, Alpine has
	// no packaged archive at all, and a source build defaults to on wherever
	// krb5 headers were present.
	if libssh_a_wants_gssapi(LIBSSH_A) {
		if UNAME == "Darwin" {
			append(&libs, "-framework", "Kerberos")
		} else if gss_a, gss_found := find_archive("gssapi_krb5"); gss_found {
			append(&libs, gss_a)
		} else if want_full {
			die(
				fmt.tprintf("%s was built with GSSAPI, and there is no libgssapi_krb5.a to link.", LIBSSH_A),
				"MIT Kerberos ships no static libraries on Debian or Ubuntu —",
				"libkrb5-dev contains not one .a file — so a GSSAPI-enabled",
				"libssh.a cannot go into a fully static binary at all.",
				"Either use --static, which links krb5 dynamically and still",
				"drops the libssh dependency, or build libssh yourself with",
				"-DWITH_GSSAPI=OFF. docs/static-linking.md has the cmake line.",
			)
		} else {
			append(&libs, "-lgssapi_krb5")
		}
	}

	if want_full {
		append(&libs, "-static")
	}

	STATIC_LIBS = strings.join(libs[:], " ", context.allocator)
}

// libssh's version, from pkg-config where there is one and from the installed
// header where there is not — a Homebrew or vcpkg install without pkg-config
// on PATH is common enough to be worth the second path.
libssh_version :: proc() -> string {
	if pkg_config_available() && run_ok({"pkg-config", "--exists", "libssh"}) {
		out, ok := run_capture({"pkg-config", "--modversion", "libssh"})
		if ok {
			return chomp(out)
		}
		return ""
	}
	incs := [?]string{
		strings.concatenate({strings.trim_suffix(LIBDIR, "/lib"), "/include"}, context.allocator),
		"/opt/homebrew/opt/libssh/include",
		"/usr/local/opt/libssh/include",
		"/opt/homebrew/include",
		"/usr/local/include",
		"/usr/include",
		"/opt/local/include",
	}
	for inc in incs {
		h := strings.concatenate({inc, "/libssh/libssh_version.h"}, context.allocator)
		if !os.is_file(h) {
			continue
		}
		data, err := os.read_entire_file(h, context.allocator)
		if err != nil {
			return ""
		}
		maj, min, mic: string
		for line in strings.split_lines(string(data), context.allocator) {
			fields := strings.fields(line, context.allocator)
			if len(fields) < 3 {
				continue
			}
			if fields[0] == "#define" {
				switch fields[1] {
				case "LIBSSH_VERSION_MAJOR":
					maj = fields[2]
				case "LIBSSH_VERSION_MINOR":
					min = fields[2]
				case "LIBSSH_VERSION_MICRO":
					mic = fields[2]
				}
			}
		}
		if maj != "" {
			return fmt.aprintf("%s.%s.%s", maj, min, mic)
		}
		return ""
	}
	return ""
}

// Is there actually a libssh in LIBDIR? Testing that the directory exists is
// not enough and the difference is not academic: a bare ubuntu:24.04 with no
// libssh at all still has an empty /usr/local/lib, which is where
// resolve_libssh falls back to, so a directory test reported "found" to
// precisely the reader who has nothing installed. Measured in a container
// before this was first written.
libssh_lib_present :: proc() -> bool {
	if matches, err := filepath.glob(strings.concatenate({LIBDIR, "/libssh.so*"}, context.allocator), context.allocator); err == nil && len(matches) > 0 {
		return true
	}
	names := [3]string{"libssh.dylib", "libssh.a", "ssh.lib"}
	for n in names {
		if os.exists(strings.concatenate({LIBDIR, "/", n}, context.allocator)) {
			return true
		}
	}
	return false
}

// a >= b, both dotted numeric. Trailing non-numeric junk is dropped rather
// than guessed at: a "0.11.0rc1" is treated as 0.11.0.
version_ge :: proc(a, b: string) -> bool {
	numeric_key :: proc(v: string) -> int {
		end := len(v)
		for c, i in v {
			if !(c >= '0' && c <= '9') && c != '.' {
				end = i
				break
			}
		}
		parts := strings.split(v[:end], ".", context.allocator)
		key := 0
		mults := [3]int{10000, 100, 1}
		for m, i in mults {
			n := 0
			if i < len(parts) {
				for c in parts[i] {
					if c >= '0' && c <= '9' {
						n = n*10 + int(c - '0')
					}
				}
			}
			key += n * m
		}
		return key
	}
	return numeric_key(a) >= numeric_key(b)
}
