#+build windows
// The winsock half of net_posix.odin: same three private procedures, same
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

// Whether `fd` is an IPv6 socket the kernel has put in IPv6-only mode — one
// that will refuse every IPv4 client. See net_posix.odin for why `serve` asks.
//
// Windows is the platform where the answer is expected to be yes: winsock has
// defaulted IPV6_V6ONLY to 1 since Vista, so a "::" bind here should be found
// IPv6-only and `serve` should fall back to 0.0.0.0. That is a prediction from
// the documented default, not a measurement — no Windows machine was available
// for this change, and the code does not depend on the prediction being right:
// whatever getsockopt reports is what gets acted on.
@(private)
listener_is_v6only :: proc(fd: ls.Socket) -> bool {
	if !ls.socket_valid(fd) {
		return false
	}
	v: win32.c_int
	vlen := win32.c_int(size_of(v))
	if win32.getsockopt(
		   win32.SOCKET(fd),
		   win32.IPPROTO_IPV6,
		   win32.IPV6_V6ONLY,
		   ([^]win32.c_char)(&v),
		   &vlen,
	   ) != 0 {
		return false
	}
	return v != 0
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
		// Same normalisation as net_posix.odin: an IPv4 client on a dual-stack
		// listener arrives as ::ffff:a.b.c.d and must be reported as a.b.c.d, so
		// that an audit line, a limiter key and a fail2ban match do not depend on
		// which family the server's socket happens to be. core:sys/windows has no
		// IN6_IS_ADDR_V4MAPPED, so the test is written out: 80 zero bits then
		// 0xffff.
		a := sin6.sin6_addr.s6_addr
		mapped := a[10] == 0xff && a[11] == 0xff
		for i in 0 ..< 10 {
			mapped = mapped && a[i] == 0
		}
		if mapped {
			src = &sin6.sin6_addr.s6_addr[12]
			af = win32.AF_INET
		} else {
			src = &sin6.sin6_addr
			af = win32.AF_INET6
		}
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
