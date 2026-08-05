#+build !windows
// The socket calls the server needs that are not in libssh: waiting on a
// session's own fd, naming the peer, and asking a listening socket whether it
// is IPv6-only. POSIX half; net_windows.odin declares the same three against
// winsock.
package ssh

import "core:c"
import "core:sys/posix"
import ls "../libssh"

// Waits up to timeout_ms for `fd` to become readable.
//
// `alive` is false only when the wait itself failed for a reason that is not a
// signal — a signal interrupting the wait is not a disconnect.
@(private)
wait_readable :: proc(fd: ls.Socket, timeout_ms: int) -> (readable: bool, alive: bool) {
	fds := [1]posix.pollfd{{fd = posix.FD(fd), events = {.IN}}}
	rc := posix.poll(&fds[0], 1, c.int(timeout_ms))
	if rc < 0 {
		return false, posix.errno() == .EINTR
	}
	return rc > 0, true
}

// Whether `fd` is an IPv6 socket the kernel has put in IPv6-only mode — one
// that will refuse every IPv4 client. `serve` asks this of the listening socket
// because the answer is not the same everywhere: libssh never sets
// IPV6_V6ONLY itself (verified in libssh 0.10.6 and 0.12.0: `bind_socket` in
// src/bind.c sets SO_REUSEADDR and nothing else), so the value is whatever the
// kernel default is — 0 on Linux with net.ipv6.bindv6only=0 and on macOS with
// net.inet6.ip6.v6only=0, but 1 on Linux with bindv6only=1, on FreeBSD, and on
// Windows.
//
// False when the question does not apply (an IPv4 socket, where getsockopt
// fails with ENOPROTOOPT) and also when the query itself fails. Not being able
// to tell is treated as "not v6-only" on purpose: the socket is already bound
// and listening at this point, and falling back to IPv4 on every platform that
// cannot answer would give up IPv6 for no evidence at all.
@(private)
listener_is_v6only :: proc(fd: ls.Socket) -> bool {
	if !ls.socket_valid(fd) {
		return false
	}
	v: c.int
	vlen := posix.socklen_t(size_of(v))
	if posix.getsockopt(
		   posix.FD(fd),
		   posix.IPPROTO_IPV6,
		   posix.Sock_Option(posix.IPV6_V6ONLY),
		   &v,
		   &vlen,
	   ) != .OK {
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
	ss: posix.sockaddr_storage
	slen := posix.socklen_t(size_of(ss))
	if posix.getpeername(posix.FD(fd), (^posix.sockaddr)(&ss), &slen) != .OK {
		return ""
	}

	src: rawptr
	af: posix.AF
	#partial switch ss.ss_family {
	case .INET:
		sin := (^posix.sockaddr_in)(&ss)
		src = &sin.sin_addr
		af = .INET
	case .INET6:
		sin6 := (^posix.sockaddr_in6)(&ss)
		// An IPv4 client on a dual-stack listener — which is what DEFAULT_HOST
		// gets you — is reported by getpeername as an IPv4-mapped IPv6 address,
		// and inet_ntop renders that "::ffff:127.0.0.1". Report the dotted quad
		// instead. Measured before this normalisation existed: an OpenSSH client
		// on 127.0.0.1 produced `event=accept addr=::ffff:127.0.0.1`, which is a
		// different string from the `addr=127.0.0.1` the same client produced on
		// an IPv4 listener — a different fail2ban match, a different limiter key
		// and a different audit record for the same peer. The address family the
		// server happens to be listening on is not a fact about the client.
		if posix.IN6_IS_ADDR_V4MAPPED(sin6.sin6_addr) {
			src = &sin6.sin6_addr.s6_addr[12]
			af = .INET
		} else {
			src = &sin6.sin6_addr
			af = .INET6
		}
	case:
		return ""
	}

	if posix.inet_ntop(af, src, raw_data(dst), posix.socklen_t(len(dst))) == nil {
		return ""
	}
	n := 0
	for n < len(dst) && dst[n] != 0 {n += 1}
	return string(dst[:n])
}
