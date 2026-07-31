#+build !windows
// Tests for the POSIX-only halves of otsh, written because the Linux paths had
// never executed: every one of them was a prediction until they were run in a
// Debian/Ubuntu container.
//
// Unlike the other files in tests/, these are not pure logic — they open a
// pty and briefly point this process's stdout at it, because that is the only
// way to reach `tui.local_backend`'s `size`, which reads STDOUT_FILENO. The
// swap is restored before the test returns.
//
//	./test.sh -define:ODIN_TEST_NAMES=otsh_tests.local_size_reads_the_pty
package otsh_tests

import "core:c"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "otsh:tui"

when ODIN_OS == .Darwin {
	foreign import libc_ "system:System"
} else {
	foreign import libc_ "system:c"
}

@(default_calling_convention = "c")
foreign libc_ {
	@(private = "file")
	ioctl :: proc(fd: c.int, request: c.ulong, #c_vararg args: ..any) -> c.int ---
}

// The write half of the pair tui/local.odin reads with TIOCGWINSZ. Same
// per-kernel encoding, one number lower: Linux 0x5414, BSD/macOS
// _IOW('t', 103, struct winsize) == 0x80087467. Declared here rather than
// imported so that this file is an independent statement of the platform's
// values — if tui/local.odin's TIOCGWINSZ is wrong, `size` cannot see what
// this sets and the test fails.
@(private = "file")
TIOCSWINSZ :: 0x5414 when ODIN_OS == .Linux else 0x80087467

@(private = "file")
Winsize :: struct {
	ws_row, ws_col, ws_xpixel, ws_ypixel: u16,
}

@(private = "file")
Pty :: struct {
	master, slave: posix.FD,
}

// Opens a pty pair. Returns ok=false rather than failing the test if the
// sandbox has no ptys at all, so a container without /dev/pts does not read as
// a code defect.
@(private = "file")
open_pty :: proc() -> (p: Pty, ok: bool) {
	m := posix.posix_openpt({.RDWR, .NOCTTY})
	if m < 0 {
		return {}, false
	}
	if posix.grantpt(m) != .OK || posix.unlockpt(m) != .OK {
		posix.close(m)
		return {}, false
	}
	name := posix.ptsname(m)
	if name == nil {
		posix.close(m)
		return {}, false
	}
	s := posix.open(name, {.RDWR, .NOCTTY})
	if s < 0 {
		posix.close(m)
		return {}, false
	}
	return Pty{master = m, slave = s}, true
}

@(private = "file")
close_pty :: proc(p: Pty) {
	posix.close(p.slave)
	posix.close(p.master)
}

// Serialises the stdout swap below. `STDOUT_FILENO` is process-wide and the
// test runner is multi-threaded, so without this the tests here corrupt each
// other: one test's /dev/null lands under another's ioctl and it reads back
// 80x24 — indistinguishable from the wrong-TIOCGWINSZ failure this file exists
// to catch. Measured at roughly 1 failure in 15 runs on Linux, never on macOS.
//
// After this lock: 1 failure in 75 Linux runs, and not reproduced in the last
// 55 consecutive ones. That residual is not explained. If it resurfaces, the
// next thing to try is `-define:ODIN_TEST_THREADS=1`, which serialises the
// whole suite — every test here mutates process-global state (stdout, files
// under /tmp), so this file is inherently hostile to a parallel runner.
@(private = "file")
stdout_mu: sync.Mutex

// Runs `tui.local_backend(...).size` with `fd` temporarily installed as this
// process's stdout, since that is the descriptor it queries.
@(private = "file")
size_with_stdout :: proc(fd: posix.FD) -> (cols, rows: int) {
	sync.lock(&stdout_mu)
	defer sync.unlock(&stdout_mu)

	saved := posix.dup(posix.STDOUT_FILENO)
	if saved < 0 {
		return 0, 0
	}
	defer {
		posix.dup2(saved, posix.STDOUT_FILENO)
		posix.close(saved)
	}
	if posix.dup2(fd, posix.STDOUT_FILENO) < 0 {
		return 0, 0
	}
	l: tui.Local
	b := tui.local_backend(&l)
	return b.size(b.data)
}

// The regression this file exists for. TIOCGWINSZ's value differs between
// Linux and the BSDs, and a wrong one does not fail loudly — `size` just
// returns the 80x24 fallback forever, so every app silently renders at the
// wrong geometry. Setting a size the fallback cannot equal is what makes that
// visible.
@(test)
local_size_reads_the_pty :: proc(t: ^testing.T) {
	p, ok := open_pty()
	if !testing.expect(t, ok, "could not open a pty") {
		return
	}
	defer close_pty(p)

	want := Winsize {
		ws_row = 37,
		ws_col = 101,
	}
	if !testing.expect(
		t,
		ioctl(c.int(p.slave), TIOCSWINSZ, &want) == 0,
		"TIOCSWINSZ failed on a pty",
	) {
		return
	}

	cols, rows := size_with_stdout(p.slave)
	testing.expect_value(t, cols, 101)
	testing.expect_value(t, rows, 37)
	// Spelled out because this is the exact failure a wrong TIOCGWINSZ
	// produces, and 80x24 looks like a plausible answer rather than an error.
	testing.expectf(
		t,
		!(cols == 80 && rows == 24),
		"size fell back to 80x24: TIOCGWINSZ is wrong for %v",
		ODIN_OS,
	)
}

// A second, different geometry, so a constant answer cannot pass both, and one
// with an odd row count in case a struct-layout mistake pairs the fields up.
@(test)
local_size_tracks_a_resize :: proc(t: ^testing.T) {
	p, ok := open_pty()
	if !testing.expect(t, ok, "could not open a pty") {
		return
	}
	defer close_pty(p)

	for want in ([2]Winsize{{ws_row = 24, ws_col = 80}, {ws_row = 9, ws_col = 203}}) {
		w := want
		if !testing.expect(t, ioctl(c.int(p.slave), TIOCSWINSZ, &w) == 0, "TIOCSWINSZ failed") {
			return
		}
		cols, rows := size_with_stdout(p.slave)
		testing.expect_value(t, cols, int(want.ws_col))
		testing.expect_value(t, rows, int(want.ws_row))
	}
}

// The other half of the contract: when stdout is not a terminal at all the
// ioctl fails and `size` must answer 80x24 rather than 0x0, which would make
// `screen_init` allocate an empty screen and every draw clip to nothing.
@(test)
local_size_falls_back_without_a_tty :: proc(t: ^testing.T) {
	fd := posix.open("/dev/null", {.RDWR})
	if !testing.expect(t, fd >= 0, "could not open /dev/null") {
		return
	}
	defer posix.close(fd)

	cols, rows := size_with_stdout(fd)
	testing.expect_value(t, cols, 80)
	testing.expect_value(t, rows, 24)
}

// ssh/perm_posix.odin reads st_mode through `transmute(posix.mode_t)`, and the
// permission bits it looks for have to survive that on every POSIX target. A
// wrong reading here is silent in exactly the wrong direction: a host key left
// world-readable would never be warned about.
@(test)
perm_bits_survive_stat :: proc(t: ^testing.T) {
	path :: "/tmp/otsh_linux_test_mode"
	cpath :: cstring(path)
	posix.unlink(cpath)
	fd := posix.open(cpath, {.WRONLY, .CREAT, .TRUNC}, {.IRUSR, .IWUSR})
	if !testing.expect(t, fd >= 0, "could not create the probe file") {
		return
	}
	posix.close(fd)
	defer posix.unlink(cpath)

	read_mode :: proc() -> (m: posix.mode_t, ok: bool) {
		st: posix.stat_t
		if posix.stat(cpath, &st) != .OK {
			return {}, false
		}
		return transmute(posix.mode_t)(st.st_mode), true
	}

	// Created 0600: owner bits set, nobody else's.
	m, got := read_mode()
	if !testing.expect(t, got, "stat failed") {
		return
	}
	testing.expect(t, .IRUSR in m && .IWUSR in m, "0600 file is missing its owner bits")
	testing.expect(t, !(.IRGRP in m), "0600 file reads as group-readable")
	testing.expect(t, !(.IROTH in m), "0600 file reads as world-readable")

	// The condition warn_if_world_readable actually tests, in both directions.
	testing.expect_value(t, posix.chmod(cpath, {.IRUSR, .IWUSR, .IRGRP, .IROTH}), posix.result.OK)
	m, got = read_mode()
	if !testing.expect(t, got, "stat failed after chmod") {
		return
	}
	testing.expect(t, .IRGRP in m, "0644 file does not read as group-readable")
	testing.expect(t, .IROTH in m, "0644 file does not read as world-readable")
	testing.expect(t, !(.IWOTH in m), "0644 file reads as world-writable")
}
