// Audit logging: a record of who connected, when, and what happened to them.
//
// Opt-in, and deliberately so. Every line produced here carries the client's
// numeric address, and keeping a file of who talked to your server and when is
// a privacy decision the operator has to make on purpose — not something a
// library should start doing on their behalf. `Config.audit` is nil by default,
// a nil sink emits nothing at all, and the zero-valued Config therefore behaves
// exactly as it did before this file existed.
//
// What is never logged: passwords, and the client's public key fingerprint. A
// fingerprint is a *global* identifier (see identity.odin), so audit lines
// carry the pseudonymous `id` instead — stable here, meaningless anywhere else.
package ssh

import "core:os"
import "core:time"

// What happened. One value per line handed to the sink.
Audit_Kind :: enum u8 {
	Listen,        // the port is bound and the accept loop is running
	Accept,        // a TCP connection was accepted, before any crypto
	Reject,        // a connection was dropped by Limits, before any crypto
	Kex_Fail,      // key exchange failed; there is no client identity yet
	Auth,          // one authentication attempt, accepted or refused
	Session_Start, // authenticated, pty requested, shell granted
	Session_End,   // the handler returned and the connection is closing
}

// Which limit refused a connection. Only meaningful on `.Reject`.
Audit_Limit :: enum u8 {
	None,
	Sessions, // Limits.max_sessions, the process-wide cap
	Per_Ip,   // Limits.max_per_ip, the per-source-address cap
}

// One auditable thing that happened.
//
// A flat struct rather than a tagged union: this is copied on the accept path
// and on every session thread, and a struct of borrowed strings copies without
// a branch and without an allocator. Fields that a kind does not carry stay
// zero and are not formatted.
//
// Every string here borrows memory owned by the connection and dies with it.
// A sink that keeps an event past its own return must copy what it keeps.
Audit_Event :: struct {
	kind:     Audit_Kind,
	// Stamped by the emitter rather than the call site, so every line's clock
	// comes from one place. UTC.
	at:       time.Time,
	// Numeric peer address. Present on every kind except `.Listen` — this is
	// the field a fail2ban-style filter keys on.
	addr:     string,
	host:     string,       // .Listen: the bind address
	port:     int,          // .Listen
	limit:    Audit_Limit,  // .Reject: which limit tripped
	user:     string,       // .Auth, .Session_Start: client-offered, unverified
	method:   Auth_Method,  // .Auth
	ok:       bool,         // .Auth: the verdict
	// Pseudonymous account id, empty when there is none. Carried by `.Auth`,
	// `.Session_Start` and `.Session_End`. Never the fingerprint.
	id:       string,
	term:     string,       // .Session_Start: client-reported $TERM
	cols:     int,          // .Session_Start
	rows:     int,          // .Session_Start
	duration: time.Duration, // .Session_End: how long the handler ran
}

// Where audit events go. Set it on `Config.audit`; nil disables auditing.
//
// Called from the accept loop, from every session thread, and from inside
// libssh's authentication callbacks — concurrently, and on the connection's
// critical path. A sink must therefore be thread-safe, must not block, and
// should not allocate. `audit_stderr` satisfies all three; a sink that writes
// to a database or a network service wants a queue in front of it.
Audit_Sink :: #type proc(e: Audit_Event)

// --- line format ------------------------------------------------------------
//
// One event, one line, never wrapped or continued. This grammar is a contract:
// log filters are written against it, so changing it breaks them.
//
//	otsh: audit ts=<rfc3339> event=<name> <key>=<value> ...
//
//   - The line always begins with the literal "otsh: audit ".
//   - `ts` is RFC 3339 in UTC at second resolution, always exactly the 20
//     characters YYYY-MM-DDTHH:MM:SSZ.
//   - `event` is one of: listen, accept, reject, kex_fail, auth, session_start,
//     session_end.
//   - Fields are separated by exactly one space, appear in the fixed order
//     listed below for their event, and no key repeats within a line.
//   - A field whose value is unknown or empty is written as `-`. The only
//     optional field is `id`, which is omitted entirely when absent and is
//     always last on the line.
//   - Values never contain a space, an `=`, or a control character. Every byte
//     outside [A-Za-z0-9.:_@/+,%-] becomes `?`, and values are capped: addr and
//     host at 64 bytes, user, term and id at 32. A username and a $TERM are
//     client-controlled text, so without this a client could forge fields or
//     whole extra lines.
//
// The events and their fields, in order:
//
//	listen         host port
//	accept         addr
//	reject         addr limit                 limit is "sessions" or "per_ip"
//	kex_fail       addr
//	auth           addr method user ok [id]   method is none|password|publickey
//	                                          ok is true|false
//	session_start  addr user term cols rows [id]
//	session_end    addr secs [id]             secs is seconds.milliseconds
//
// What a parser may rely on: `event=` names the record; `addr=` is present on
// every event except listen and holds the peer address in numeric form (IPv4
// dotted quad, or IPv6 with an optional %zone); and every record a filter cares
// about — reject, kex_fail, and auth with ok=false — carries addr. A client key
// fingerprint is never logged anywhere in this format.

// Formats `e` into `buf` and returns a string viewing the bytes written. No
// newline is appended — `audit_stderr` adds one so it can write the whole line
// in a single call. Allocates nothing and needs no context, so a sink can run
// it on a stack buffer from anywhere. Output is truncated rather than
// overflowing if `buf` is shorter than AUDIT_LINE_MAX.
audit_format :: proc "contextless" (e: Audit_Event, buf: []u8) -> string {
	n := 0
	audit_put_raw(buf, &n, "otsh: audit ts=")
	audit_put_ts(buf, &n, e.at)
	audit_put_key(buf, &n, "event")
	audit_put_raw(buf, &n, audit_kind_name(e.kind))

	switch e.kind {
	case .Listen:
		audit_put_field(buf, &n, "host", e.host, AUDIT_ADDR_MAX)
		audit_put_num(buf, &n, "port", e.port)
	case .Accept, .Kex_Fail:
		audit_put_field(buf, &n, "addr", e.addr, AUDIT_ADDR_MAX)
	case .Reject:
		audit_put_field(buf, &n, "addr", e.addr, AUDIT_ADDR_MAX)
		audit_put_key(buf, &n, "limit")
		audit_put_raw(buf, &n, audit_limit_name(e.limit))
	case .Auth:
		audit_put_field(buf, &n, "addr", e.addr, AUDIT_ADDR_MAX)
		audit_put_key(buf, &n, "method")
		audit_put_raw(buf, &n, audit_method_name(e.method))
		audit_put_field(buf, &n, "user", e.user, AUDIT_TEXT_MAX)
		audit_put_key(buf, &n, "ok")
		audit_put_raw(buf, &n, e.ok ? "true" : "false")
		audit_put_id(buf, &n, e.id)
	case .Session_Start:
		audit_put_field(buf, &n, "addr", e.addr, AUDIT_ADDR_MAX)
		audit_put_field(buf, &n, "user", e.user, AUDIT_TEXT_MAX)
		audit_put_field(buf, &n, "term", e.term, AUDIT_TEXT_MAX)
		audit_put_num(buf, &n, "cols", e.cols)
		audit_put_num(buf, &n, "rows", e.rows)
		audit_put_id(buf, &n, e.id)
	case .Session_End:
		audit_put_field(buf, &n, "addr", e.addr, AUDIT_ADDR_MAX)
		audit_put_key(buf, &n, "secs")
		audit_put_secs(buf, &n, e.duration)
		audit_put_id(buf, &n, e.id)
	}
	return string(buf[:n])
}

// Upper bound on one formatted line, newline included. The longest line is a
// session_start with every field at its cap.
AUDIT_LINE_MAX :: 320

// A ready-made `Audit_Sink` writing the format above to stderr, one line per
// event.
//
// The line is assembled in a stack buffer and handed to a single `os.write`,
// because events fire from the accept loop and from every session thread at
// once: two partial writes would interleave into a line no filter can parse.
// Nothing here allocates, so it is safe on the connection's critical path.
//
// Example:
//
//	ssh.serve(ssh.Config{audit = ssh.audit_stderr, handler = handler})
audit_stderr :: proc(e: Audit_Event) {
	buf: [AUDIT_LINE_MAX]u8
	// One byte held back so the newline always fits, even in the (unreachable)
	// case of a line that filled the buffer.
	n := len(audit_format(e, buf[:AUDIT_LINE_MAX - 1]))
	buf[n] = '\n'
	os.write(os.stderr, buf[:n + 1])
}

// --- emission ---------------------------------------------------------------

// Hands one event to the configured sink, stamping it with the current time.
// A nil sink — the default — costs one predictable branch and nothing else.
@(private)
audit_emit :: proc(srv: ^Server, e: Audit_Event) {
	if srv == nil || srv.audit == nil {
		return
	}
	e := e
	e.at = time.now()
	srv.audit(e)
}

// `audit_emit` with the connection's identifying fields filled in, so the call
// sites in session_thread stay one line each. Only safe while the session's
// buffers are still live, i.e. before the teardown block zeroes them.
@(private)
audit_session :: proc(s: ^Session, e: Audit_Event) {
	if s.server == nil || s.server.audit == nil {
		return
	}
	e := e
	e.addr = remote_addr(s)
	e.user = user(s)
	e.id = id(s)
	audit_emit(s.server, e)
}

// --- formatting helpers -----------------------------------------------------
//
// All contextless and allocation-free: they run inside libssh callbacks and on
// the accept path, where neither a context nor an allocator is guaranteed.

// Caps on client- and operator-supplied values; see the format contract above.
@(private)
AUDIT_ADDR_MAX :: 64
@(private)
AUDIT_TEXT_MAX :: 32

@(private)
audit_kind_name :: proc "contextless" (k: Audit_Kind) -> string {
	switch k {
	case .Listen:
		return "listen"
	case .Accept:
		return "accept"
	case .Reject:
		return "reject"
	case .Kex_Fail:
		return "kex_fail"
	case .Auth:
		return "auth"
	case .Session_Start:
		return "session_start"
	case .Session_End:
		return "session_end"
	}
	return "unknown"
}

@(private)
audit_limit_name :: proc "contextless" (l: Audit_Limit) -> string {
	switch l {
	case .None:
		return "-"
	case .Sessions:
		return "sessions"
	case .Per_Ip:
		return "per_ip"
	}
	return "-"
}

@(private)
audit_method_name :: proc "contextless" (m: Auth_Method) -> string {
	switch m {
	case .None:
		return "none"
	case .Password:
		return "password"
	case .Publickey:
		return "publickey"
	}
	return "unknown"
}

@(private)
audit_put_byte :: proc "contextless" (dst: []u8, n: ^int, c: u8) {
	if n^ < len(dst) {
		dst[n^] = c
		n^ += 1
	}
}

// Appends text this package chose itself — keys, event names, method names.
// Never use it for anything a client supplied.
@(private)
audit_put_raw :: proc "contextless" (dst: []u8, n: ^int, s: string) {
	for i in 0 ..< len(s) {
		audit_put_byte(dst, n, s[i])
	}
}

@(private)
audit_put_key :: proc "contextless" (dst: []u8, n: ^int, key: string) {
	audit_put_byte(dst, n, ' ')
	audit_put_raw(dst, n, key)
	audit_put_byte(dst, n, '=')
}

// " key=value", with the value scrubbed to the safe byte set and capped. An
// empty value becomes "-" so a parser never sees a bare key.
@(private)
audit_put_field :: proc "contextless" (dst: []u8, n: ^int, key, value: string, max_len: int) {
	audit_put_key(dst, n, key)
	if value == "" {
		audit_put_byte(dst, n, '-')
		return
	}
	for i in 0 ..< min(len(value), max_len) {
		switch c := value[i]; c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '.', ':', '_', '@', '/', '+', ',', '%', '-':
			audit_put_byte(dst, n, c)
		case:
			// A space, an '=', a newline or a control byte here would let a
			// client forge fields or whole lines in someone else's log.
			audit_put_byte(dst, n, '?')
		}
	}
}

// The one optional field: omitted entirely when the client has no id, always
// last on the line.
@(private)
audit_put_id :: proc "contextless" (dst: []u8, n: ^int, id: string) {
	if id == "" {
		return
	}
	audit_put_field(dst, n, "id", id, AUDIT_TEXT_MAX)
}

@(private)
audit_put_num :: proc "contextless" (dst: []u8, n: ^int, key: string, v: int) {
	audit_put_key(dst, n, key)
	audit_put_int(dst, n, v)
}

@(private)
audit_put_int :: proc "contextless" (dst: []u8, n: ^int, v: int) {
	// No audited number can be negative; a stray one becomes 0 rather than
	// adding a sign to the grammar.
	v := max(v, 0)
	digits: [20]u8
	i := len(digits)
	for {
		i -= 1
		digits[i] = u8('0' + v % 10)
		v /= 10
		if v == 0 || i == 0 {
			break
		}
	}
	audit_put_raw(dst, n, string(digits[i:]))
}

// Zero-padded to exactly `width` digits. The ts field is a fixed 20 characters
// by contract, so an out-of-range component is clamped rather than widening it.
@(private)
audit_put_pad :: proc "contextless" (dst: []u8, n: ^int, v, width: int) {
	place := 1
	for _ in 1 ..< width {
		place *= 10
	}
	v := clamp(v, 0, place * 10 - 1)
	for place > 0 {
		audit_put_byte(dst, n, u8('0' + (v / place) % 10))
		place /= 10
	}
}

// RFC 3339, UTC, second resolution. core:time counts from the Unix epoch with
// no zone applied, so the components are already UTC and the trailing Z is a
// statement of fact rather than a conversion.
@(private)
audit_put_ts :: proc "contextless" (dst: []u8, n: ^int, t: time.Time) {
	year, month, day := time.date(t)
	hour, minute, second := time.clock_from_time(t)
	audit_put_pad(dst, n, year, 4)
	audit_put_byte(dst, n, '-')
	audit_put_pad(dst, n, int(month), 2)
	audit_put_byte(dst, n, '-')
	audit_put_pad(dst, n, day, 2)
	audit_put_byte(dst, n, 'T')
	audit_put_pad(dst, n, hour, 2)
	audit_put_byte(dst, n, ':')
	audit_put_pad(dst, n, minute, 2)
	audit_put_byte(dst, n, ':')
	audit_put_pad(dst, n, second, 2)
	audit_put_byte(dst, n, 'Z')
}

// Seconds with three decimals, truncated rather than rounded. Integer maths
// throughout: float formatting would want an allocator.
@(private)
audit_put_secs :: proc "contextless" (dst: []u8, n: ^int, d: time.Duration) {
	ms := max(i64(d) / 1_000_000, 0)
	audit_put_int(dst, n, int(ms / 1000))
	audit_put_byte(dst, n, '.')
	audit_put_pad(dst, n, int(ms % 1000), 3)
}
