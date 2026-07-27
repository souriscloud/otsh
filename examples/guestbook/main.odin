// guestbook — a shared guestbook served over SSH.
//
// Anyone who connects sees every message left by everyone who has connected
// before them, and can leave their own. This file is the finished program
// from docs/tutorial-guestbook.md; read that alongside this one — it builds
// this up in the same order the sections below appear in.
//
//	./build.sh examples/guestbook && ./guestbook
//	ssh -p 2228 localhost
package main

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:unicode/utf8"
import "otsh:sshtui"
import "otsh:tui"

// ---------------------------------------------------------------------------
// Shared state. Every connection runs create/update/view on its own thread
// (sshtui.md, "Create_Proc, Destroy_Proc, and the connection lifecycle"), so
// the one guestbook everybody reads and writes has to live at package scope,
// guarded by a mutex, exactly like examples/members' roster.

Message :: struct {
	author: string, // owned copy — see add_message
	text:   string, // owned copy
}

messages: [dynamic]Message
messages_mu: sync.Mutex

message_count :: proc() -> int {
	sync.lock(&messages_mu)
	defer sync.unlock(&messages_mu)
	return len(messages)
}

message_at :: proc(i: int) -> (Message, bool) {
	sync.lock(&messages_mu)
	defer sync.unlock(&messages_mu)
	if i < 0 || i >= len(messages) {
		return {}, false
	}
	return messages[i], true
}

// Clones both strings before storing them. author/text may point into a
// per-connection buffer that is about to be reused or freed — see step 5 and
// step 6 of the tutorial for why this is not optional.
add_message :: proc(author, text: string) {
	sync.lock(&messages_mu)
	defer sync.unlock(&messages_mu)
	append(&messages, Message{author = strings.clone(author), text = strings.clone(text)})
}

// ---------------------------------------------------------------------------
// Per-connection state.

Mode :: enum {
	Browse,
	Compose,
}

MAX_MSG_BYTES :: 240

Model :: struct {
	who:         string, // owned; short label derived from Info.id
	mode:        Mode,
	cursor:      int,
	offset:      int, // index of the first visible row
	buf:         [MAX_MSG_BYTES]u8,
	buf_len:     int,
	confirm_ttl: f64, // seconds left to show "message posted"
	blink:       f64, // accumulator driving the input cursor blink
}

// info.id is only non-empty when identity_secret is set and the client
// authenticated with a key (see step 6). Falling back to "anonymous" keeps
// the app usable even when that is not the case.
author_label :: proc(info: sshtui.Info) -> string {
	if info.id == "" {
		return "anonymous"
	}
	return fmt.tprintf("guest-%s", info.id[:min(len(info.id), 10)])
}

move_cursor :: proc(m: ^Model, delta, n, viewport_h: int) {
	if n == 0 {
		m.cursor, m.offset = 0, 0
		return
	}
	m.cursor = clamp(m.cursor + delta, 0, n - 1)
	clamp_scroll(m, n, viewport_h)
}

// Keeps cursor/offset consistent whenever the message count or the viewport
// height changes underneath us — new messages from other connections, or a
// resize. See docs/cookbook.md recipe 1.
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

commit_message :: proc(m: ^Model) {
	text := strings.trim_space(string(m.buf[:m.buf_len]))
	if text != "" {
		add_message(m.who, text)
		m.confirm_ttl = 1.5
	}
	m.buf_len = 0
	m.mode = .Browse
}

// ---------------------------------------------------------------------------
// Layout. One set of numbers, shared by update() (for scrolling math) and
// view() (for drawing), so the two can never disagree about how tall the
// list viewport is. See docs/cookbook.md recipe 1's warning about exactly
// this drifting apart.

MIN_W :: 44
MIN_H :: 14

Layout :: struct {
	box_x, box_y, box_w, box_h:     int,
	list_x, list_y, list_w, list_h: int,
	footer_y:                       int,
}

compute_layout :: proc(w, h: int) -> Layout {
	l: Layout
	l.box_w = min(w - 4, 100)
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
		if e.ctrl && e.r == 'c' {
			tui.quit(p)
			return
		}
		switch m.mode {
		case .Browse:
			browse_key(p, m, e)
		case .Compose:
			compose_key(m, e)
		}

	case tui.Resize:
		l := compute_layout(e.cols, e.rows)
		clamp_scroll(m, message_count(), l.list_h)

	case tui.Tick:
		m.blink += e.dt
		if m.confirm_ttl > 0 {
			m.confirm_ttl -= e.dt
			if m.confirm_ttl < 0 {
				m.confirm_ttl = 0
			}
		}
	}
}

browse_key :: proc(p: ^tui.Program, m: ^Model, k: tui.Key) {
	if k.kind == .Esc || (k.kind == .Rune && k.r == 'q') {
		tui.quit(p)
		return
	}
	l := compute_layout(p.screen.w, p.screen.h)
	n := message_count()

	#partial switch k.kind {
	case .Up:
		move_cursor(m, -1, n, l.list_h)
	case .Down:
		move_cursor(m, 1, n, l.list_h)
	case .Enter:
		m.mode = .Compose
		m.buf_len = 0
	case .Rune:
		switch k.r {
		case 'k':
			move_cursor(m, -1, n, l.list_h)
		case 'j':
			move_cursor(m, 1, n, l.list_h)
		}
	}
}

compose_key :: proc(m: ^Model, k: tui.Key) {
	#partial switch k.kind {
	case .Enter:
		commit_message(m)
	case .Esc:
		m.buf_len = 0
		m.mode = .Browse
	case .Backspace:
		if m.buf_len > 0 {
			_, size := utf8.decode_last_rune(m.buf[:m.buf_len])
			m.buf_len -= size
		}
	case .Space:
		insert_rune(m, ' ')
	case .Rune:
		insert_rune(m, k.r)
	}
}

// ---------------------------------------------------------------------------
// view

view :: proc(p: ^tui.Program, sc: ^tui.Screen) {
	defer free_all(context.temp_allocator)
	m := (^Model)(p.app.data)

	if sc.w < MIN_W || sc.h < MIN_H {
		msg := fmt.tprintf("terminal too small — need %dx%d, have %dx%d", MIN_W, MIN_H, sc.w, sc.h)
		tui.draw_text_clipped(
			sc,
			max((sc.w - tui.text_width(msg)) / 2, 0),
			sc.h / 2,
			sc.w,
			msg,
			tui.Style{fg = tui.ansi(11)},
		)
		return
	}

	l := compute_layout(sc.w, sc.h)
	n := message_count()
	clamp_scroll(m, n, l.list_h)

	tui.draw_box(
		sc,
		l.box_x,
		l.box_y,
		l.box_w,
		l.box_h,
		tui.Style{fg = tui.rgb(120, 190, 255)},
		tui.BORDER_ROUND,
		" guestbook ",
	)

	header := fmt.tprintf("%d message(s) — you are %s", n, m.who)
	tui.draw_text_clipped(sc, l.list_x, l.box_y + 1, l.list_w, header, tui.Style{fg = tui.ansi(8)})
	draw_rule(sc, l.list_x, l.box_y + 2, l.list_w)

	draw_messages(sc, m, l, n)

	draw_rule(sc, l.list_x, l.footer_y - 1, l.list_w)
	draw_footer(sc, m, l)
}

draw_rule :: proc(sc: ^tui.Screen, x, y, w: int) {
	for col in x ..< x + w {
		tui.set_cell(sc, col, y, '─', tui.Style{fg = tui.ansi(8)})
	}
}

draw_messages :: proc(sc: ^tui.Screen, m: ^Model, l: Layout, n: int) {
	if n == 0 {
		tui.draw_text_clipped(
			sc,
			l.list_x,
			l.list_y,
			l.list_w,
			"no messages yet — press enter to write the first one",
			tui.Style{fg = tui.ansi(8), attrs = {.Italic}},
		)
		return
	}
	for row in 0 ..< l.list_h {
		i := m.offset + row
		if i >= n {
			break
		}
		msg, ok := message_at(i)
		if !ok {
			break
		}
		selected := m.mode == .Browse && i == m.cursor
		draw_message_row(sc, l.list_x, l.list_y + row, l.list_w, msg, selected)
	}
}

draw_message_row :: proc(sc: ^tui.Screen, x, y, w: int, msg: Message, selected: bool) {
	au_style := tui.Style{fg = tui.ansi(6), attrs = {.Bold}}
	tx_style := tui.Style{fg = tui.ansi(15)}
	if selected {
		au_style.attrs += {.Reverse}
		tx_style.attrs += {.Reverse}
	}
	prefix := fmt.tprintf("%s: ", msg.author)
	used := tui.draw_text_clipped(sc, x, y, w, prefix, au_style)
	if used < w {
		tui.draw_text_clipped(sc, x + used, y, w - used, msg.text, tx_style)
	}
}

draw_footer :: proc(sc: ^tui.Screen, m: ^Model, l: Layout) {
	switch m.mode {
	case .Browse:
		if m.confirm_ttl > 0 {
			tui.draw_text_clipped(
				sc,
				l.list_x,
				l.footer_y,
				l.list_w,
				"message posted",
				tui.Style{fg = tui.ansi(10), attrs = {.Bold}},
			)
		} else {
			tui.draw_text_clipped(
				sc,
				l.list_x,
				l.footer_y,
				l.list_w,
				"↑↓/jk move · enter write · q quit",
				tui.Style{fg = tui.ansi(8)},
			)
		}
	case .Compose:
		text := string(m.buf[:m.buf_len])
		line := fmt.tprintf("> %s", text)
		tui.draw_text_clipped(sc, l.list_x, l.footer_y, l.list_w, line, tui.Style{fg = tui.ansi(15)})
		if int(m.blink * 2) % 2 == 0 {
			tui.set_cursor(sc, l.list_x + tui.text_width("> ") + tui.text_width(text), l.footer_y)
		}
	}
}

// ---------------------------------------------------------------------------
// wiring

create :: proc(info: sshtui.Info) -> tui.App {
	m := new(Model)
	m.who = strings.clone(author_label(info))
	return tui.App{data = m, update = update, view = view}
}

destroy :: proc(app: tui.App) {
	m := (^Model)(app.data)
	delete(m.who)
	free(app.data)
}

connected :: proc(info: sshtui.Info) {
	// Log the pseudonymous id, never a fingerprint or a key.
	fmt.printfln("guestbook: connected id=%s auth=%s", info.id, info.auth_method)
}

main :: proc() {
	messages = make([dynamic]Message, 0, 64)

	sshtui.serve(
		sshtui.Config {
			port            = 2228,
			host_key_path   = "guestbook_hostkey",
			identity_secret = "guestbook_secret", // enables Info.id
			methods         = {.Publickey}, // required so a key is always offered
			create          = create,
			destroy         = destroy,
			on_connect      = connected,
		},
	)
}
