// notes — a private scratchpad per SSH key, served to many users at once.
//
// Every key gets its own list of notes. Reconnect with the same key later in
// the same server run and they're still there; restart the server and
// they're gone — nothing here is ever written to disk. See
// docs/tutorial-notes.md, "what to try next", for how you'd add that.
//
//	./build.sh examples/notes && ./notes
//	ssh -p 2224 localhost
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:unicode/utf8"
import "otsh:sshtui"
import "otsh:tui"

// ---------------------------------------------------------------------------
// Shared state. Every connection runs on its own thread, so the notes live
// at package scope guarded by a mutex, like examples/members' roster —
// keyed per user instead of shared by everyone. destroy (below) frees only
// the per-connection Model; this map outlives every connection on purpose.

Note :: struct {
	text: string, // owned
}

User_Notes :: struct {
	notes: [dynamic]Note,
}

notes_store: map[string]User_Notes
notes_mu: sync.Mutex

// Bounded per user, checked under the same lock as the append below, or two
// sessions racing for the last slot could both pass.
MAX_NOTES :: 200

notes_count :: proc(id: string) -> int {
	sync.lock(&notes_mu)
	defer sync.unlock(&notes_mu)
	u, ok := notes_store[id]
	return ok ? len(u.notes) : 0
}

// Returns a copy of note i whose text is cloned into the temp allocator.
// Returning the stored string itself would be a use-after-free waiting to
// happen: the moment the lock drops, another session with the same key can
// press d and notes_delete frees those bytes while the caller is still
// drawing them. (guestbook can return its strings borrowed because nothing
// there ever deletes one; here d exists.) view()'s frame-end
// free_all(context.temp_allocator) reclaims the clone.
notes_at :: proc(id: string, i: int) -> (Note, bool) {
	sync.lock(&notes_mu)
	defer sync.unlock(&notes_mu)
	u, ok := notes_store[id]
	if !ok || i < 0 || i >= len(u.notes) {
		return {}, false
	}
	return Note{text = strings.clone(u.notes[i].text, context.temp_allocator)}, true
}

// Clones text before storing it — it usually points into a per-connection
// buffer (Model.buf) the next keystroke overwrites. False at MAX_NOTES.
notes_add :: proc(id: string, text: string) -> bool {
	sync.lock(&notes_mu)
	defer sync.unlock(&notes_mu)

	u, existed := notes_store[id]
	if !existed {
		u = User_Notes{notes = make([dynamic]Note, 0, 8)}
	}
	if len(u.notes) >= MAX_NOTES {
		return false
	}
	append(&u.notes, Note{text = strings.clone(text)})

	if existed {
		// Assigning to a key already in the map updates the value and
		// leaves the stored key alone, so the borrowed `id` is fine here.
		// docs/cookbook.md §8.
		notes_store[id] = u
	} else {
		// First note from this user: the map key must outlive the
		// connection that handed us `id`, so it gets its own clone, made
		// exactly once, right here on insert. Every later access reuses
		// the caller's borrowed id — only the insert owns a key.
		notes_store[strings.clone(id)] = u
	}
	return true
}

// Deletes note i for this user. False if there is no such note.
notes_delete :: proc(id: string, i: int) -> bool {
	sync.lock(&notes_mu)
	defer sync.unlock(&notes_mu)
	u, ok := notes_store[id]
	if !ok || i < 0 || i >= len(u.notes) {
		return false
	}
	delete(u.notes[i].text)
	ordered_remove(&u.notes, i)
	notes_store[id] = u // id is only borrowed; see notes_add above
	return true
}

// ---------------------------------------------------------------------------
// Per-connection state.

View :: enum {
	List, // your notes, with a cursor
	Edit, // composing a new note
	Help, // keybindings
}

MAX_NOTE_BYTES :: 240

Model :: struct {
	id:      string, // owned; cloned from Info.id, keys the shared store
	who:     string, // owned; short display label — first 8 chars of id
	view:    View,
	cursor:  int,
	offset:  int, // index of the first visible row
	buf:     [MAX_NOTE_BYTES]u8,
	buf_len: int,
}

move_cursor :: proc(m: ^Model, delta, n, viewport_h: int) {
	if n == 0 {
		m.cursor, m.offset = 0, 0
		return
	}
	m.cursor = clamp(m.cursor + delta, 0, n - 1)
	clamp_scroll(m, n, viewport_h)
}

// Keeps cursor/offset consistent when the note count or viewport height
// changes underneath us. docs/cookbook.md recipe 1.
clamp_scroll :: proc(m: ^Model, n, viewport_h: int) {
	if n == 0 {
		m.cursor, m.offset = 0, 0
		return
	}
	if m.cursor >= n {
		m.cursor = n - 1
	}
	if m.cursor < m.offset {
		m.offset = m.cursor
	}
	if m.cursor >= m.offset + viewport_h {
		m.offset = m.cursor - viewport_h + 1
	}
	if m.offset < 0 {
		m.offset = 0
	}
}

insert_rune :: proc(m: ^Model, r: rune) {
	b, n := utf8.encode_rune(r)
	if m.buf_len + n <= len(m.buf) {
		copy(m.buf[m.buf_len:], b[:n])
		m.buf_len += n
	}
}

commit_note :: proc(m: ^Model) {
	text := strings.trim_space(string(m.buf[:m.buf_len]))
	if text != "" {
		notes_add(m.id, text)
	}
	m.buf_len = 0
	m.view = .List
}

// ---------------------------------------------------------------------------
// Layout. One set of numbers, used by both update() and view(), so the two
// never disagree about the list height. docs/cookbook.md recipe 1.

MIN_W :: 44
MIN_H :: 14

Layout :: struct {
	box_x, box_y, box_w, box_h:     int,
	list_x, list_y, list_w, list_h: int,
	footer_y:                       int,
}

compute_layout :: proc(w, h: int) -> Layout {
	l: Layout
	l.box_w = min(w - 4, 70)
	l.box_x = (w - l.box_w) / 2
	l.box_y = 1
	l.box_h = h - 2
	l.list_x = l.box_x + 2
	l.list_y = l.box_y + 3
	l.list_w = max(l.box_w - 4, 1)
	l.list_h = max(l.box_h - 6, 1)
	l.footer_y = l.box_y + 4 + l.list_h
	return l
}

// ---------------------------------------------------------------------------
// update

update :: proc(p: ^tui.Program, msg: tui.Msg) {
	m := (^Model)(p.app.data)

	#partial switch e in msg {
	case tui.Key:
		// Ctrl+C is a key here, not a signal — docs/cookbook.md recipe 12.
		if e.ctrl && e.r == 'c' {
			tui.quit(p)
			return
		}
		switch m.view {
		case .List:
			key_list(p, m, e)
		case .Edit:
			key_edit(m, e)
		case .Help:
			key_help(m, e)
		}

	case tui.Resize:
		l := compute_layout(e.cols, e.rows)
		clamp_scroll(m, notes_count(m.id), l.list_h)
	}
}

key_list :: proc(p: ^tui.Program, m: ^Model, k: tui.Key) {
	if k.kind == .Esc || (k.kind == .Rune && k.r == 'q') {
		tui.quit(p)
		return
	}
	l := compute_layout(p.screen.w, p.screen.h)
	n := notes_count(m.id)

	#partial switch k.kind {
	case .Up:
		move_cursor(m, -1, n, l.list_h)
	case .Down:
		move_cursor(m, 1, n, l.list_h)
	case .Rune:
		switch k.r {
		case 'k':
			move_cursor(m, -1, n, l.list_h)
		case 'j':
			move_cursor(m, 1, n, l.list_h)
		case 'n':
			m.view = .Edit
			m.buf_len = 0
		case 'd':
			if notes_delete(m.id, m.cursor) {
				clamp_scroll(m, notes_count(m.id), l.list_h)
			}
		case '?':
			m.view = .Help
		}
	}
}

key_edit :: proc(m: ^Model, k: tui.Key) {
	#partial switch k.kind {
	case .Enter:
		commit_note(m)
	case .Esc:
		m.buf_len = 0
		m.view = .List
	case .Backspace:
		// A whole rune, not a byte — multi-byte input otherwise leaves a
		// broken tail behind. docs/cookbook.md recipe 3.
		if m.buf_len > 0 {
			_, size := utf8.decode_last_rune(m.buf[:m.buf_len])
			m.buf_len -= max(size, 1)
		}
	case .Space:
		insert_rune(m, ' ')
	case .Rune:
		insert_rune(m, k.r)
	}
}

key_help :: proc(m: ^Model, k: tui.Key) {
	if k.kind == .Esc || (k.kind == .Rune && k.r == '?') {
		m.view = .List
	}
}

// ---------------------------------------------------------------------------
// view

view :: proc(p: ^tui.Program, sc: ^tui.Screen) {
	defer free_all(context.temp_allocator)
	m := (^Model)(p.app.data)

	if sc.w < MIN_W || sc.h < MIN_H {
		msg := fmt.tprintf("terminal too small — need %dx%d, have %dx%d", MIN_W, MIN_H, sc.w, sc.h)
		x := max((sc.w - tui.text_width(msg)) / 2, 0)
		tui.draw_text_clipped(sc, x, sc.h / 2, sc.w, msg, tui.Style{fg = tui.ansi(11)})
		return
	}

	l := compute_layout(sc.w, sc.h)
	n := notes_count(m.id)
	clamp_scroll(m, n, l.list_h)

	title := fmt.tprintf(" %s — %d note(s) ", m.who, n)
	tui.draw_box(sc, l.box_x, l.box_y, l.box_w, l.box_h, tui.Style{fg = tui.rgb(150, 200, 140)}, tui.BORDER_ROUND, title)

	if m.view == .Help {
		draw_help(sc, l)
	} else {
		draw_list(sc, m, l, n)
	}
	draw_footer(sc, m, l)
}

draw_list :: proc(sc: ^tui.Screen, m: ^Model, l: Layout, n: int) {
	if n == 0 {
		empty := "no notes yet — press n to write one"
		tui.draw_text_clipped(sc, l.list_x, l.list_y, l.list_w, empty, tui.Style{fg = tui.ansi(8), attrs = {.Italic}})
		return
	}
	for row in 0 ..< l.list_h {
		i := m.offset + row
		if i >= n {
			break
		}
		note, ok := notes_at(m.id, i)
		if !ok {
			break
		}
		st := tui.Style{fg = tui.ansi(15)}
		if m.view == .List && i == m.cursor {
			st.attrs = {.Reverse}
		}
		prefix := fmt.tprintf("%2d. ", i + 1)
		used := tui.draw_text_clipped(sc, l.list_x, l.list_y + row, l.list_w, prefix, st)
		if used < l.list_w {
			tui.draw_text_clipped(sc, l.list_x + used, l.list_y + row, l.list_w - used, note.text, st)
		}
	}
}

draw_help :: proc(sc: ^tui.Screen, l: Layout) {
	lines := [?]string {
		"↑↓ / j k    move",
		"n           new note",
		"enter       save note",
		"esc         cancel / close help",
		"d           delete selected note",
		"?           toggle this help",
		"q, ctrl+c   quit",
	}
	for line, i in lines {
		y := l.list_y + i
		if y >= l.footer_y {
			break
		}
		tui.draw_text_clipped(sc, l.list_x, y, l.list_w, line, tui.Style{fg = tui.ansi(15)})
	}
}

draw_footer :: proc(sc: ^tui.Screen, m: ^Model, l: Layout) {
	switch m.view {
	case .List:
		help := "↑↓/jk move · n new · d delete · ? help · q quit"
		tui.draw_text_clipped(sc, l.list_x, l.footer_y, l.list_w, help, tui.Style{fg = tui.ansi(8)})
	case .Help:
		tui.draw_text_clipped(sc, l.list_x, l.footer_y, l.list_w, "esc/? back to the list", tui.Style{fg = tui.ansi(8)})
	case .Edit:
		text := string(m.buf[:m.buf_len])
		line := fmt.tprintf("> %s", text)
		tui.draw_text_clipped(sc, l.list_x, l.footer_y, l.list_w, line, tui.Style{fg = tui.ansi(15)})
		tui.set_cursor(sc, l.list_x + tui.text_width("> ") + tui.text_width(text), l.footer_y)
	}
}

// ---------------------------------------------------------------------------
// wiring

create :: proc(info: sshtui.Info) -> tui.App {
	m := new(Model)
	// methods = {.Publickey} plus identity_secret below means info.id is
	// always non-empty by the time create runs — see docs/security.md §3.
	m.id = strings.clone(info.id)
	m.who = strings.clone(info.id[:min(len(info.id), 8)])
	return tui.App{data = m, update = update, view = view}
}

// Frees only the per-connection Model — notes_store deliberately outlives
// every connection, so it is not touched here.
destroy :: proc(app: tui.App) {
	m := (^Model)(app.data)
	delete(m.id)
	delete(m.who)
	free(app.data)
}

connected :: proc(info: sshtui.Info) {
	// Log the pseudonymous id, never a fingerprint or a key.
	fmt.printfln("notes: connected id=%s auth=%s", info.id, info.auth_method)
}

main :: proc() {
	notes_store = make(map[string]User_Notes)

	cfg := sshtui.Config {
		port            = 2224,
		host_key_path   = "notes_hostkey",
		identity_secret = "notes_secret", // enables Info.id
		// Otherwise an OpenSSH client authenticates via "none" before ever
		// offering a key, and Info.id stays empty. docs/security.md §3.
		methods         = {.Publickey},
		create          = create,
		destroy         = destroy,
		on_connect      = connected,
	}

	// serve returns false when the server never came up — port in use, bad
	// host key, libssh too old — after printing why. Exiting 0 would hide it.
	if !sshtui.serve(cfg) {
		os.exit(1)
	}
}
