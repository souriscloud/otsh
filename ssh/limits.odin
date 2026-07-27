// Resource limits.
//
// Without these, one host can open connections until the process runs out of
// threads, and a client that completes the TCP handshake but never finishes key
// exchange pins a thread forever. Both are trivial to do by accident and
// trivial to do on purpose.
package ssh

import "core:c"
import "core:sync"
import "core:sys/posix"

// Per field: 0 means "use the default below", negative means "no limit".
// That way the zero value of the whole struct is the safe default rather than
// an accidental free-for-all, and you can still opt out of any single limit.
Limits :: struct {
	// Total concurrent sessions.
	max_sessions:      int,
	// Concurrent sessions from one source address.
	max_per_ip:        int,
	// Seconds a client gets to complete key exchange and authentication before
	// the socket times out. Without this, a client that connects and then says
	// nothing holds a thread indefinitely.
	handshake_seconds: int,
	// Failed authentication attempts before the connection is dropped.
	max_auth_attempts: int,
}

// Applied to any `Limits` field left at zero. Deliberately conservative — raise
// them deliberately rather than discovering you had none.
DEFAULT_LIMITS :: Limits {
	max_sessions      = 256,
	max_per_ip        = 8,
	handshake_seconds = 20,
	max_auth_attempts = 6,
}

// Resolves 0 -> default, negative -> unlimited (stored as 0, which every
// check below treats as "no limit").
@(private)
resolve_limits :: proc "contextless" (l: Limits) -> Limits {
	pick :: proc "contextless" (v, dflt: int) -> int {
		switch {
		case v < 0:
			return 0 // explicitly unlimited
		case v == 0:
			return dflt
		}
		return v
	}
	return Limits {
		max_sessions = pick(l.max_sessions, DEFAULT_LIMITS.max_sessions),
		max_per_ip = pick(l.max_per_ip, DEFAULT_LIMITS.max_per_ip),
		handshake_seconds = pick(l.handshake_seconds, DEFAULT_LIMITS.handshake_seconds),
		max_auth_attempts = pick(l.max_auth_attempts, DEFAULT_LIMITS.max_auth_attempts),
	}
}

@(private)
Limiter :: struct {
	mu:       sync.Mutex,
	total:    int,
	per_ip:   map[string]int,
	limits:   Limits,
	inited:   bool,
}

@(private)
limiter_init :: proc(l: ^Limiter, limits: Limits) {
	l.limits = resolve_limits(limits)
	l.per_ip = make(map[string]int)
	l.inited = true
}

// Reserves a slot for `addr`. Returns false when a limit is hit, in which case
// nothing was reserved and the caller must drop the connection.
@(private)
limiter_acquire :: proc(l: ^Limiter, addr: string) -> bool {
	if !l.inited {
		return true
	}
	sync.lock(&l.mu)
	defer sync.unlock(&l.mu)

	if l.limits.max_sessions > 0 && l.total >= l.limits.max_sessions {
		return false
	}
	if l.limits.max_per_ip > 0 && addr != "" {
		if l.per_ip[addr] >= l.limits.max_per_ip {
			return false
		}
	}

	l.total += 1
	if addr != "" {
		// The key is cloned because `addr` points into the session's buffer,
		// which dies with the session.
		if existing, found := l.per_ip[addr]; found {
			l.per_ip[addr] = existing + 1
		} else {
			l.per_ip[strings_clone(addr)] = 1
		}
	}
	return true
}

@(private)
limiter_release :: proc(l: ^Limiter, addr: string) {
	if !l.inited {
		return
	}
	sync.lock(&l.mu)
	defer sync.unlock(&l.mu)

	l.total = max(l.total - 1, 0)
	if addr == "" {
		return
	}
	if n, found := l.per_ip[addr]; found {
		if n <= 1 {
			// Delete the entry (and its cloned key) so the map cannot grow
			// without bound across many distinct source addresses.
			key, _ := delete_key(&l.per_ip, addr)
			delete(key)
		} else {
			l.per_ip[addr] = n - 1
		}
	}
}

@(private)
strings_clone :: proc(s: string) -> string {
	b := make([]u8, len(s))
	copy(b, s)
	return string(b)
}

// Formats the peer address of `fd` into `dst`, returning a string viewing it.
// Numeric only — no reverse DNS, which would leak the connection to a resolver
// and block the thread while doing it.
@(private)
peer_address :: proc(fd: c.int, dst: []u8) -> string {
	if fd < 0 || len(dst) < 46 {
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
