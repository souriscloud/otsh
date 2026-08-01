// Resource limits.
//
// Without these, one host can open connections until the process runs out of
// threads, and a client that completes the TCP handshake but never finishes key
// exchange pins a thread forever. Both are trivial to do by accident and
// trivial to do on purpose.
package ssh

import "base:runtime"
import "core:mem"
import "core:sync"

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
	// Failed `Authenticator` verdicts after which this connection stops being
	// asked. It does NOT drop the connection, and it does NOT bound guessing
	// across connections: the counter lives on the Session, so a client that
	// reconnects gets a fresh budget. Measured at roughly 37 guesses/second from
	// one address against a rejecting Authenticator. If you accept passwords,
	// rate-limit them yourself — this is not that control.
	max_auth_attempts: int,
	// Seconds a client may leave its flow-control window shut — i.e. simply stop
	// reading — before its session is torn down.
	//
	// `handshake_seconds` does not cover this: it is a socket timeout, and the
	// wait inside libssh's ssh_channel_write does not honour it. Measured before
	// this limit existed: three clients that authenticated, asked for a shell and
	// then never read held all three session slots for a full 60 seconds, past a
	// 20-second handshake timeout, while a fourth client was refused with
	// `limit=sessions`. Nothing about it is malformed — a slow reader is entitled
	// to stop reading — so it costs the attacker one idle socket per pinned
	// thread and is invisible to a protocol-level filter.
	//
	// The window closing is normal and harmless; only staying shut this long is
	// not. Raise it for clients on genuinely slow links.
	//
	// Negative disables the *disconnect*, not the protection: `write` never
	// blocks regardless of this setting. A stalled client then keeps its slot
	// for as long as it likes, but on a thread that is still responsive and
	// still notices shutdown, rather than one wedged inside libssh.
	write_stall_seconds: int,
}

// Applied to any `Limits` field left at zero. Deliberately conservative — raise
// them deliberately rather than discovering you had none.
DEFAULT_LIMITS :: Limits {
	max_sessions        = 256,
	max_per_ip          = 8,
	handshake_seconds   = 20,
	max_auth_attempts   = 6,
	// Generous: a real client on a bad link recovers in well under this, and an
	// app that draws at 30fps notices the window shut within one frame.
	write_stall_seconds = 30,
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
		write_stall_seconds = pick(l.write_stall_seconds, DEFAULT_LIMITS.write_stall_seconds),
	}
}

@(private)
Limiter :: struct {
	mu:        sync.Mutex,
	total:     int,
	per_ip:    map[string]int,
	limits:    Limits,
	inited:    bool,
	// Slots are taken by the accept loop and released by each connection's own
	// thread, so the map and its cloned keys outlive whichever context created
	// them. They get the heap allocator explicitly rather than context.allocator,
	// which may be an arena the other thread cannot free from.
	allocator: mem.Allocator,
}

@(private)
limiter_init :: proc(l: ^Limiter, limits: Limits) {
	l.limits = resolve_limits(limits)
	l.allocator = runtime.heap_allocator()
	l.per_ip = make(map[string]int, 16, l.allocator)
	l.inited = true
}

// Reserves a slot for `addr`. Returns ok=false when a limit is hit, in which
// case nothing was reserved and the caller must drop the connection. `tripped`
// names which limit refused it, because "we dropped you" and "we dropped you
// because one host already holds every slot" are different operational facts
// and the audit log has to be able to tell them apart.
@(private)
limiter_acquire :: proc(l: ^Limiter, addr: string) -> (ok: bool, tripped: Audit_Limit) {
	if !l.inited {
		return true, .None
	}
	sync.lock(&l.mu)
	defer sync.unlock(&l.mu)

	if l.limits.max_sessions > 0 && l.total >= l.limits.max_sessions {
		return false, .Sessions
	}
	if l.limits.max_per_ip > 0 && addr != "" {
		if l.per_ip[addr] >= l.limits.max_per_ip {
			return false, .Per_Ip
		}
	}

	l.total += 1
	if addr != "" {
		// The key is cloned because `addr` points into the session's buffer,
		// which dies with the session.
		if existing, found := l.per_ip[addr]; found {
			l.per_ip[addr] = existing + 1
		} else {
			l.per_ip[strings_clone(addr, l.allocator)] = 1
		}
	}
	return true, .None
}

// Releases the map and every key cloned into it. Only for the startup-failure
// path in `serve`, where no session thread exists yet — there is no locking
// here because there is nobody to lock against.
@(private)
limiter_destroy :: proc(l: ^Limiter) {
	if !l.inited {
		return
	}
	for key in l.per_ip {
		delete(key, l.allocator)
	}
	delete(l.per_ip)
	l.per_ip = nil
	l.inited = false
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
			delete(key, l.allocator)
		} else {
			l.per_ip[addr] = n - 1
		}
	}
}

@(private)
strings_clone :: proc(s: string, allocator: mem.Allocator) -> string {
	b := make([]u8, len(s), allocator)
	copy(b, s)
	return string(b)
}
