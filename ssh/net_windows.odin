#+build windows
// The winsock half of net_posix.odin: same two private procedures, same
// contracts.
//
// Winsock needs WSAStartup before any of this works. libssh does it inside
// ssh_init(), which `serve` calls before it can have a session to poll, so
// there is nothing to initialise here.
//
// Run against real clients on Windows 11 with vcpkg libssh 0.12.0 on
// 2026-07-31: WSAPoll carried the accept loop, and getpeername plus the
// inet_ntop below put a correct non-loopback address on every audit line of a
// session opened across the network. What that run did not cover — concurrent
// sessions, load, the hosted CI windows job, which has still never executed —
// is listed in docs/getting-started.md.
package ssh

import win32 "core:sys/windows"
import ls "../libssh"

// core:sys/windows binds most of Ws2_32 but not inet_ntop, so it is declared
// here. ws2tcpip.h:
//	PCSTR WSAAPI inet_ntop(INT Family, const VOID *pAddr, PSTR pStringBuf, size_t StringBufSize);
foreign import ws2_32 "system:Ws2_32.lib"

@(default_calling_convention = "system")
foreign ws2_32 {
	@(private)
	inet_ntop :: proc(family: win32.c_int, addr: rawptr, dst: [^]u8, size: win32.size_t) -> cstring ---
}

// Waits up to timeout_ms for `fd` to become readable.
//
// `alive` is false only when the wait itself failed for a reason that is not a
// signal — a signal interrupting the wait is not a disconnect.
//
// WSAPoll's documented defect is that it never reports a failed *connect*; this
// server only ever waits on an already-established socket, where a peer that
// goes away makes the socket readable and the read reports the EOF.
@(private)
wait_readable :: proc(fd: ls.Socket, timeout_ms: int) -> (readable: bool, alive: bool) {
	fds := [1]win32.WSA_POLLFD{{fd = win32.SOCKET(fd), events = win32.POLLIN}}
	rc := win32.WSAPoll(&fds[0], 1, win32.c_int(timeout_ms))
	if rc < 0 {
		return false, win32.WSAGetLastError() == win32.WSAEINTR
	}
	return rc > 0, true
}

// Formats the peer address of `fd` into `dst`, returning a string viewing it.
// Numeric only — no reverse DNS, which would leak the connection to a resolver
// and block the thread while doing it.
@(private)
peer_address :: proc(fd: ls.Socket, dst: []u8) -> string {
	if !ls.socket_valid(fd) || len(dst) < 46 {
		return ""
	}
	ss: win32.SOCKADDR_STORAGE_LH
	slen := win32.socklen_t(size_of(ss))
	if win32.getpeername(win32.SOCKET(fd), &ss, &slen) != 0 {
		return ""
	}

	src: rawptr
	af: win32.c_int
	switch win32.c_int(ss.ss_family) {
	case win32.AF_INET:
		sin := (^win32.sockaddr_in)(&ss)
		src = &sin.sin_addr
		af = win32.AF_INET
	case win32.AF_INET6:
		sin6 := (^win32.sockaddr_in6)(&ss)
		src = &sin6.sin6_addr
		af = win32.AF_INET6
	case:
		return ""
	}

	if inet_ntop(af, src, raw_data(dst), win32.size_t(len(dst))) == nil {
		return ""
	}
	n := 0
	for n < len(dst) && dst[n] != 0 {n += 1}
	return string(dst[:n])
}
