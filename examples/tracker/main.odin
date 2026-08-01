// tracker — a shared issue tracker, served over SSH.
//
//	./build.sh examples/tracker && ./tracker
//	ssh -p 2222 localhost
//	./tracker --local          same app, this terminal, no SSH
//
// Everyone who connects sees the same issues. Open one, close it, file a new
// one, and every other connected session sees the change on its next frame —
// the board lives in this process, not in any one connection.
//
// The issues it ships with are otsh's own, which is a convenient way to keep
// the demo honest: the closed ones are bugs that were really found and fixed
// while building this library.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import "core:unicode/utf8"
import "otsh:sshtui"
import "otsh:tui"

// --- palette ----------------------------------------------------------------
//
// tui.rgb is a procedure, not a compile-time constant, so these are `:=`
// package variables rather than `::` constants.

C_TEXT := tui.rgb(222, 218, 226)
C_MUTED := tui.rgb(148, 142, 156)
C_DIM := tui.rgb(100, 96, 108)
C_ACCENT := tui.rgb(233, 166, 88)
C_OPEN := tui.rgb(126, 196, 144)
C_CLOSED := tui.rgb(176, 148, 224)
C_BORDER := tui.rgb(78, 74, 88)
C_SEL_BG := tui.rgb(40, 38, 48)

// --- shared state -----------------------------------------------------------
//
// One board, many connections. Every field below is reachable from any
// connection's thread, so nothing here is touched without holding `mu`.

Issue_State :: enum {
	Open,
	Closed,
}

Issue :: struct {
	id:       int,
	title:    string, // owned
	body:     string, // owned
	author:   string, // owned; pseudonymous id, never a fingerprint
	state:    Issue_State,
	comments: int,
	// When this issue last changed; drives the "just changed" marker, so a
	// session can see edits made by somebody else land in real time. A wall
	// clock reading, NOT an accumulated per-frame age: every connected session
	// runs its own update loop against this shared struct, so summing each
	// session's dt into it would age the marker N× too fast with N sessions.
	// The zero value reads as "long ago", which is what seeded issues want.
	touched:  time.Tick,
}

// A shared board on a public port must not grow without bound — without a cap,
// anyone holding an SSH key can grow this process's memory until the OS kills
// it. Evicting old issues instead would be wrong here: sessions hold snapshot
// copies whose strings borrow the board's allocations, so freeing an evicted
// issue's strings would dangle every snapshot that still shows it. Refusing is
// both safer and simpler.
MAX_ISSUES :: 500

board: struct {
	mu:        sync.Mutex,
	issues:    [dynamic]Issue,
	next_id:   int,
	connected: int,
}

seed_board :: proc() {
	seed :: proc(state: Issue_State, title, body: string, comments: int) {
		board.next_id += 1
		append(
			&board.issues,
			Issue {
				id = board.next_id,
				title = strings.clone(title),
				body = strings.clone(body),
				author = strings.clone("otsh"),
				state = state,
				comments = comments,
			},
		)
	}
	seed(.Closed, "ssh_event_dopoll spins a core",
	     "Its timeout argument never blocks — it returns immediately every call, so each session burned a core at ~22k fps. ssh.read now waits on the session socket with poll(2) and calls dopoll(0) only to parse.", 4)
	seed(.Closed, "rejecting a key enumerates the client's agent",
	     "An SSH client offers its next key after each rejection, so a gating server learns every public key a user holds. The probe is now accepted unconditionally; authorisation belongs in the app.", 7)
	seed(.Closed, "host key written world-readable",
	     "libssh writes it under the process umask, usually 0644. A host key any local user can read is one they can impersonate the server with. The file is now created first — empty, O_EXCL, 0600 — before libssh opens it. Chmod after the fact would not do: a process that already won the open() keeps its descriptor across the mode change.", 2)
	seed(.Closed, "toast overprints the help line",
	     "view paints a full frame with no erase step, so drawing a short toast over a longer help string left the tail of the help text on screen. The footer now picks one string and draws only that.", 1)
	seed(.Closed, "lone ESC is ambiguous",
	     "ESC is both a key and the start of every escape sequence. Resolved with the usual timeout: an ESC still alone after two frames is reported as the Escape key.", 3)
	seed(.Closed, "Session is ~17 KB because of the ring buffer",
	     "The per-session ring is gone entirely: libssh already buffers channel data, so read() drains that directly and Session dropped under 1 KB. The ring's original justification — that libssh re-offers whatever the callback declines — turned out to be false, and cost a separate session-deafening bug before anyone checked it.", 4)
	seed(.Closed, "a ~1 MiB paste permanently deafened a session",
	     "Two consumers shared one buffer: a channel_data_function copied into a fixed ring and declined the rest, believing libssh would re-offer it. It does not — the callback fires only when the next packet arrives, so a paste's tail was stranded and the session went deaf while still repainting. Instrumented: 1 MiB pasted, ~550 KB stuck, quit key unseen after 60s. Now one buffer, one consumer: no callback, read() drains libssh directly. 1 MiB went from never to 4.8s, 4 MiB works, and SSH's own window is the backpressure.", 6)
	seed(.Closed, "no Windows local backend",
	     "A console-API backend, winsock plumbing and a vcpkg build path now exist. Run by hand on real Windows 11 on 2026-07-31 — every example built, 67 tests green, openssh sessions served against tracker.exe — which turned up four genuine bugs, since fixed. The hosted windows-latest CI job then went green too. One path is still unexercised: closing the console window rather than pressing Ctrl+C, which is modelled on MSDN's contract and noted as such in ssh/signal_windows.odin.", 3)
	seed(.Closed, "no audit log",
	     "Config.audit takes a sink; audit_stderr emits one machine-parseable line per event — accept, auth, limiter reject, kex failure, session lifecycle — with client text scrubbed so a username cannot forge fields. Opt-in, because every line carries a peer address.", 2)
	seed(.Closed, "distributed floods are not mitigated",
	     "The fix lives where the issue said it must: in front of the process. deploy/ ships nftables/pf rate limits, a fail2ban filter over the audit log, and a hardened systemd unit; docs/deploy.md walks the layering. The process itself still cannot stop a spread-out flood, and the docs keep saying so.", 1)
	seed(.Closed, "wide glyphs need a real width table",
	     "rune_width is generated from Unicode East Asian Width data (docs/tools/gen_width.py), ambiguous-width narrow so box borders survive. Grapheme clustering stays out of scope: ZWJ sequences measure as their parts.", 6)
	seed(.Closed, "handshake deadlocked once in three connections under load",
	     "Server callbacks were installed after ssh_handle_key_exchange instead of before it. The client's SERVICE_REQUEST arrives coalesced with NEWKEYS, and libssh only answers it when callbacks already exist — otherwise it queues the message where nothing drains it, so no SERVICE_ACCEPT is ever sent and the connection dies at the handshake timeout. Ordering fixed: 12/30 stalls became 0/30. It was blamed on libssh buffering first; a C reproducer refuted that.", 3)
}

// Applies `edit` to the issue with `id`, under the lock, and marks it changed.
edit_issue :: proc(id: int, edit: proc(issue: ^Issue)) {
	sync.lock(&board.mu)
	defer sync.unlock(&board.mu)
	for &issue in board.issues {
		if issue.id == id {
			edit(&issue)
			issue.touched = time.tick_now()
			return
		}
	}
}

// Files a new issue. ok is false when the board is at MAX_ISSUES; the check
// lives under the same lock as the append, so two sessions racing to file the
// last slot cannot both win.
file_issue :: proc(title, author: string) -> (id: int, ok: bool) {
	sync.lock(&board.mu)
	defer sync.unlock(&board.mu)
	if len(board.issues) >= MAX_ISSUES {
		return 0, false
	}
	board.next_id += 1
	append(
		&board.issues,
		Issue {
			id = board.next_id,
			title = strings.clone(title),
			body = strings.clone("(no description yet)"),
			author = strings.clone(author),
			state = .Open,
			touched = time.tick_now(),
		},
	)
	return board.next_id, true
}

// True while the issue's "just changed" marker should show. The zero Tick of
// a seeded issue never reads as recent.
just_changed :: proc(issue: Issue) -> bool {
	if issue.touched == (time.Tick{}) {
		return false
	}
	return time.duration_seconds(time.tick_since(issue.touched)) < 2.0
}

// Copies the issues matching `filter` into `dst`. Callers work from the copy so
// the lock is never held while drawing.
snapshot :: proc(dst: ^[dynamic]Issue, filter: Filter) {
	clear(dst)
	sync.lock(&board.mu)
	defer sync.unlock(&board.mu)
	for issue in board.issues {
		switch filter {
		case .All:
		case .Open:
			if issue.state != .Open {continue}
		case .Closed:
			if issue.state != .Closed {continue}
		}
		append(dst, issue)
	}
}

open_count :: proc() -> int {
	sync.lock(&board.mu)
	defer sync.unlock(&board.mu)
	n := 0
	for issue in board.issues {
		if issue.state == .Open {n += 1}
	}
	return n
}

// --- per-connection state ---------------------------------------------------

View :: enum {
	List,    // the split list + preview
	Detail,  // one issue, full screen
	Compose, // the new-issue form
}

Filter :: enum {
	All,
	Open,
	Closed,
}

Model :: struct {
	view:      View,
	filter:    Filter,
	cursor:    int,
	offset:    int, // first visible row
	visible:   []Issue, // snapshot, refreshed each tick
	rows:      [dynamic]Issue,
	compose:   [80]u8,
	compose_n: int,
	toast:     [96]u8,
	toast_n:   int,
	toast_ttl: f64,
	who:       string, // owned copy of Info.id, or "guest"
	spinner:   f64,
}

set_toast :: proc(m: ^Model, msg: string) {
	n := min(len(msg), len(m.toast))
	copy(m.toast[:n], msg[:n])
	m.toast_n = n
	m.toast_ttl = 2.2
}

selected :: proc(m: ^Model) -> (Issue, bool) {
	if m.cursor < 0 || m.cursor >= len(m.rows) {
		return {}, false
	}
	return m.rows[m.cursor], true
}

// Rows the list pane can show, given the current screen height.
viewport_rows :: proc(h: int) -> int {
	return max(h - 6, 1)
}

clamp_view :: proc(m: ^Model, h: int) {
	n := len(m.rows)
	if n == 0 {
		m.cursor, m.offset = 0, 0
		return
	}
	m.cursor = clamp(m.cursor, 0, n - 1)
	rows := viewport_rows(h)
	if m.cursor < m.offset {m.offset = m.cursor}
	if m.cursor >= m.offset + rows {m.offset = m.cursor - rows + 1}
	m.offset = clamp(m.offset, 0, max(n - rows, 0))
}

// --- update -----------------------------------------------------------------

update :: proc(p: ^tui.Program, msg: tui.Msg) {
	m := (^Model)(p.app.data)

	switch e in msg {
	case tui.Tick:
		m.spinner += e.dt
		snapshot(&m.rows, m.filter)
		clamp_view(m, p.screen.h)
		if m.toast_ttl > 0 {
			m.toast_ttl -= e.dt
			if m.toast_ttl <= 0 {m.toast_n = 0}
		}

	case tui.Resize:
		clamp_view(m, e.rows)

	case tui.Mouse:
		if m.view != .List {break}
		#partial switch e.kind {
		case .Wheel_Up:
			m.cursor = max(m.cursor - 1, 0)
			clamp_view(m, p.screen.h)
		case .Wheel_Down:
			m.cursor += 1
			clamp_view(m, p.screen.h)
		}

	case tui.Key:
		// Ctrl+C arrives as a key, not a signal — the client's terminal is in
		// raw mode, so nothing translates it for us.
		if e.ctrl && e.r == 'c' {
			tui.quit(p)
			return
		}
		switch m.view {
		case .List:
			key_list(p, m, e)
		case .Detail:
			key_detail(p, m, e)
		case .Compose:
			key_compose(p, m, e)
		}
	}
}

key_list :: proc(p: ^tui.Program, m: ^Model, k: tui.Key) {
	#partial switch k.kind {
	case .Up:
		m.cursor -= 1
	case .Down:
		m.cursor += 1
	case .Home:
		m.cursor = 0
	case .End:
		m.cursor = len(m.rows) - 1
	case .Page_Up:
		m.cursor -= viewport_rows(p.screen.h)
	case .Page_Down:
		m.cursor += viewport_rows(p.screen.h)
	case .Enter:
		if _, ok := selected(m); ok {m.view = .Detail}
	case .Rune:
		switch k.r {
		case 'j':
			m.cursor += 1
		case 'k':
			m.cursor -= 1
		case 'g':
			m.cursor = 0
		case 'G':
			m.cursor = len(m.rows) - 1
		case 'n':
			m.view = .Compose
			m.compose_n = 0
		case 'f':
			m.filter = Filter((int(m.filter) + 1) % len(Filter))
			m.cursor, m.offset = 0, 0
			set_toast(m, fmt.tprintf("filter: %v", m.filter))
		case 'c':
			toggle_selected(m)
		case 'q':
			tui.quit(p)
		}
	}
	clamp_view(m, p.screen.h)
}

key_detail :: proc(p: ^tui.Program, m: ^Model, k: tui.Key) {
	#partial switch k.kind {
	case .Esc, .Backspace:
		m.view = .List
	case .Rune:
		switch k.r {
		case 'q':
			m.view = .List
		case 'c':
			toggle_selected(m)
		}
	}
}

key_compose :: proc(p: ^tui.Program, m: ^Model, k: tui.Key) {
	#partial switch k.kind {
	case .Esc:
		m.view = .List
		m.compose_n = 0
	case .Enter:
		title := string(m.compose[:m.compose_n])
		if len(strings.trim_space(title)) == 0 {
			set_toast(m, "title cannot be empty")
			return
		}
		id, filed := file_issue(title, m.who)
		if !filed {
			set_toast(m, fmt.tprintf("the board is full (%d issues)", MAX_ISSUES))
			return
		}
		m.compose_n = 0
		m.view = .List
		set_toast(m, fmt.tprintf("filed #%d", id))
	case .Backspace:
		// Delete a whole rune, not a byte — otherwise multi-byte input leaves
		// a broken tail behind.
		if m.compose_n > 0 {
			_, size := utf8.decode_last_rune(m.compose[:m.compose_n])
			m.compose_n -= max(size, 1)
		}
	case .Space, .Rune:
		r := k.kind == .Space ? ' ' : k.r
		bytes, n := utf8.encode_rune(r)
		if m.compose_n + n <= len(m.compose) {
			copy(m.compose[m.compose_n:], bytes[:n])
			m.compose_n += n
		}
	}
}

toggle_selected :: proc(m: ^Model) {
	issue, ok := selected(m)
	if !ok {
		return
	}
	edit_issue(issue.id, proc(it: ^Issue) {
		it.state = it.state == .Open ? .Closed : .Open
	})
	// Re-read so the toast reports what actually happened, not what we assumed.
	snapshot(&m.rows, m.filter)
	set_toast(m, fmt.tprintf("#%d %s", issue.id, issue.state == .Open ? "closed" : "reopened"))
}

// --- view -------------------------------------------------------------------

MIN_W :: 56
MIN_H :: 16

view :: proc(p: ^tui.Program, s: ^tui.Screen) {
	defer free_all(context.temp_allocator)
	m := (^Model)(p.app.data)

	if s.w < MIN_W || s.h < MIN_H {
		msg := fmt.tprintf("terminal too small — need %dx%d, have %dx%d", MIN_W, MIN_H, s.w, s.h)
		tui.draw_text_clipped(
			s,
			max((s.w - tui.text_width(msg)) / 2, 0),
			s.h / 2,
			s.w,
			msg,
			tui.Style{fg = C_ACCENT},
		)
		return
	}

	draw_header(m, s)
	switch m.view {
	case .List:
		draw_list(m, s)
	case .Detail:
		draw_detail(m, s)
	case .Compose:
		draw_compose(m, s)
	}
	draw_footer(m, s)
}

draw_header :: proc(m: ^Model, s: ^tui.Screen) {
	tui.draw_text(s, 2, 0, "issues", tui.Style{fg = C_ACCENT, attrs = {.Bold}})

	// A slow pulse, so it is visible that the board is live even when nobody
	// is typing. Driven by dt, not by frame count.
	dots := [4]string{"·  ", "·· ", "···", " ··"}
	tui.draw_text(s, 9, 0, dots[int(m.spinner * 2) % 4], tui.Style{fg = C_DIM})

	sync.lock(&board.mu)
	conns := board.connected
	sync.unlock(&board.mu)

	right := fmt.tprintf("%d open · %d connected", open_count(), conns)
	x := s.w - tui.text_width(right) - 2
	if x > 14 {
		tui.draw_text(s, x, 0, right, tui.Style{fg = C_MUTED})
	}
	for col in 0 ..< s.w {
		tui.set_cell(s, col, 1, '─', tui.Style{fg = C_BORDER})
	}
}

draw_list :: proc(m: ^Model, s: ^tui.Screen) {
	top := 2
	rows := viewport_rows(s.h)
	split := min(max(s.w * 3 / 5, 34), s.w - 22)

	tui.draw_text(s, 2, top, "#", tui.Style{fg = C_DIM})
	tui.draw_text(s, 6, top, "TITLE", tui.Style{fg = C_DIM})
	tui.draw_text(s, split - 8, top, "STATE", tui.Style{fg = C_DIM})

	if len(m.rows) == 0 {
		tui.draw_text(s, 2, top + 2, "no issues match this filter", tui.Style{fg = C_DIM, attrs = {.Italic}})
	}

	for i in 0 ..< rows {
		idx := m.offset + i
		if idx >= len(m.rows) {break}
		issue := m.rows[idx]
		y := top + 1 + i
		sel := idx == m.cursor

		st := tui.Style {
			fg = sel ? C_TEXT : C_MUTED,
		}
		if sel {
			st.bg = C_SEL_BG
			st.attrs = {.Bold}
			for col in 1 ..< split - 1 {
				tui.set_cell(s, col, y, ' ', st)
			}
			tui.set_cell(s, 1, y, '▌', tui.Style{fg = C_ACCENT, bg = C_SEL_BG})
		}

		tui.draw_text(s, 2, y, fmt.tprintf("%d", issue.id), tui.Style{fg = C_DIM, bg = st.bg})
		tui.draw_text_clipped(s, 6, y, split - 16, issue.title, st)

		label := issue.state == .Open ? "open" : "closed"
		tui.draw_text(
			s,
			split - 8,
			y,
			label,
			tui.Style{fg = issue.state == .Open ? C_OPEN : C_CLOSED, bg = st.bg},
		)

		// Anything changed in the last two seconds gets a marker — that is how
		// you notice somebody else's edit arriving.
		if just_changed(issue) {
			tui.set_cell(s, split - 10, y, '●', tui.Style{fg = C_ACCENT, bg = st.bg})
		}
	}

	// Scroll indicator, only when the list actually overflows.
	if len(m.rows) > rows {
		bar_h := max(rows * rows / len(m.rows), 1)
		bar_y := top + 1 + (m.offset * rows / len(m.rows))
		for i in 0 ..< bar_h {
			tui.set_cell(s, split - 2, bar_y + i, '│', tui.Style{fg = C_ACCENT})
		}
	}

	for y in top ..< s.h - 2 {
		tui.set_cell(s, split, y, '│', tui.Style{fg = C_BORDER})
	}
	draw_preview(m, s, split + 3, top, s.w - split - 5)
}

draw_preview :: proc(m: ^Model, s: ^tui.Screen, x, y, w: int) {
	issue, ok := selected(m)
	if !ok {
		return
	}
	limit := s.h - 2

	tui.draw_text(s, x, y, fmt.tprintf("#%d", issue.id), tui.Style{fg = C_ACCENT, attrs = {.Bold}})
	label := issue.state == .Open ? "open" : "closed"
	tui.draw_text(
		s,
		x + 6,
		y,
		label,
		tui.Style{fg = issue.state == .Open ? C_OPEN : C_CLOSED},
	)

	line := wrap(s, x, y + 2, w, limit, issue.title, tui.Style{fg = C_TEXT, attrs = {.Bold}})
	line += 1
	if line < limit {
		tui.draw_text_clipped(
			s,
			x,
			line,
			w,
			fmt.tprintf("filed by %s · %d comments", issue.author, issue.comments),
			tui.Style{fg = C_DIM},
		)
		line += 2
	}
	wrap(s, x, line, w, limit, issue.body, tui.Style{fg = C_MUTED})
}

draw_detail :: proc(m: ^Model, s: ^tui.Screen) {
	issue, ok := selected(m)
	if !ok {
		m.view = .List
		return
	}
	w := min(s.w - 8, 72)
	x := (s.w - w) / 2
	y := 3
	h := s.h - 6

	tui.draw_box(
		s,
		x,
		y,
		w,
		h,
		tui.Style{fg = C_BORDER},
		tui.BORDER_ROUND,
		fmt.tprintf(" #%d ", issue.id),
	)

	inner := x + 3
	iw := w - 6
	line := wrap(s, inner, y + 2, iw, y + h - 1, issue.title, tui.Style{fg = C_TEXT, attrs = {.Bold}})
	line += 1

	label := issue.state == .Open ? "open" : "closed"
	tui.draw_text(s, inner, line, label, tui.Style{fg = issue.state == .Open ? C_OPEN : C_CLOSED, attrs = {.Bold}})
	tui.draw_text(
		s,
		inner + tui.text_width(label) + 2,
		line,
		fmt.tprintf("· filed by %s · %d comments", issue.author, issue.comments),
		tui.Style{fg = C_DIM},
	)
	line += 2
	wrap(s, inner, line, iw, y + h - 1, issue.body, tui.Style{fg = C_MUTED})
}

draw_compose :: proc(m: ^Model, s: ^tui.Screen) {
	w := min(s.w - 8, 64)
	x := (s.w - w) / 2
	y := s.h / 2 - 4

	tui.draw_box(s, x, y, w, 7, tui.Style{fg = C_ACCENT}, tui.BORDER_ROUND, " new issue ")
	tui.draw_text(s, x + 3, y + 2, "title", tui.Style{fg = C_DIM})

	text := string(m.compose[:m.compose_n])
	field_w := w - 6
	shown := text
	// Scroll the field so the caret stays visible on a long title.
	for tui.text_width(shown) > field_w - 1 {
		_, sz := utf8.decode_rune(transmute([]u8)shown)
		shown = shown[max(sz, 1):]
	}
	tui.draw_text(s, x + 3, y + 3, shown, tui.Style{fg = C_TEXT})
	tui.set_cursor(s, x + 3 + tui.text_width(shown), y + 3)

	tui.draw_text(s, x + 3, y + 5, "enter file · esc cancel", tui.Style{fg = C_DIM})
}

draw_footer :: proc(m: ^Model, s: ^tui.Screen) {
	y := s.h - 1
	for col in 0 ..< s.w {
		tui.set_cell(s, col, y - 1, '─', tui.Style{fg = C_BORDER})
	}

	// One string for this line, chosen here — never drawn over another, since
	// a shorter string would leave the tail of a longer one behind.
	left := ""
	style := tui.Style {
		fg = C_DIM,
	}
	if m.toast_n > 0 {
		left = string(m.toast[:m.toast_n])
		style.fg = C_ACCENT
	} else {
		switch m.view {
		case .List:
			left = "↑↓/jk move · enter open · c close · n new · f filter · q quit"
		case .Detail:
			left = "c close/reopen · esc back"
		case .Compose:
			left = "type a title · enter file · esc cancel"
		}
	}
	tui.draw_text_clipped(s, 2, y, s.w - 20, left, style)

	right := fmt.tprintf("%v", m.filter)
	x := s.w - tui.text_width(right) - 2
	if x > 4 {
		tui.draw_text(s, x, y, right, tui.Style{fg = C_MUTED})
	}
}

// Greedy word wrap. Returns the row after the last one drawn. Words wider
// than the pane are clipped to it — drawn unclipped they would run past the
// pane edge into whatever is right of it, since the screen only clips at its
// own boundary.
wrap :: proc(s: ^tui.Screen, x, y, w, limit: int, text: string, style: tui.Style) -> int {
	if w <= 0 || y >= limit {
		return y
	}
	line, col := y, 0
	rest := text
	for word in strings.split_iterator(&rest, " ") {
		ww := tui.text_width(word)
		if col > 0 && col + 1 + ww > w {
			line += 1
			col = 0
			if line >= limit {return line}
		}
		if col > 0 {
			col += 1
		}
		tui.draw_text_clipped(s, x + col, line, w - col, word, style)
		col += ww
	}
	return line + 1
}

// --- wiring -----------------------------------------------------------------

create :: proc(info: sshtui.Info) -> tui.App {
	m := new(Model)
	m.rows = make([dynamic]Issue, 0, 32)
	// info.id is borrowed from the connection and dies with it, so clone what
	// we intend to keep. It is empty unless identity_secret is set.
	m.who = strings.clone(info.id == "" ? "guest" : info.id[:min(len(info.id), 12)])
	snapshot(&m.rows, m.filter)

	sync.lock(&board.mu)
	board.connected += 1
	sync.unlock(&board.mu)

	return tui.App{data = m, update = update, view = view}
}

destroy :: proc(app: tui.App) {
	m := (^Model)(app.data)
	sync.lock(&board.mu)
	board.connected = max(board.connected - 1, 0)
	sync.unlock(&board.mu)

	delete(m.rows)
	delete(m.who)
	free(m)
}

main :: proc() {
	board.issues = make([dynamic]Issue, 0, 32)
	seed_board()

	cfg := sshtui.Config {
		port            = 2222,
		host_key_path   = "tracker_hostkey",
		identity_secret = "tracker_secret", // enables Info.id
		// Required to get an identity at all: every OpenSSH client tries the
		// "none" method first, and if the server accepts it the client never
		// offers a key, so Info.id stays empty and every issue is filed by
		// "guest". Not offering "none" costs nothing in privacy — the client
		// still stops at its first key, because that one is accepted.
		methods         = {.Publickey},
		create          = create,
		destroy         = destroy,
		mouse           = true,
	}

	for arg in os.args[1:] {
		if arg == "--local" || arg == "-l" {
			if !sshtui.run_local(cfg) {
				fmt.eprintln("tracker: stdin is not a terminal")
				os.exit(1)
			}
			return
		}
	}
	if !sshtui.serve(cfg) {
		os.exit(1)
	}
}
