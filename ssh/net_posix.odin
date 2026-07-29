#+build !windows
// The socket calls the server needs that are not in libssh: waiting on a
// session's own fd, and naming the peer. POSIX half; net_windows.odin declares
// the same two against winsock.
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
		src = &sin6.sin6_addr
		af = .INET6
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
