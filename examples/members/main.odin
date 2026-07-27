// members — key-driven auth, done without harvesting anyone's keys.
//
// The pattern: accept every key at the SSH layer, then decide what the user
// gets to see *inside the app*. Non-members are just as excluded as they would
// be by a "Permission denied", but the server only ever learns the one key they
// connected with instead of every key in their agent.
//
//	./build.sh examples/members && ./members
//	ssh -p 2226 localhost          # first connection enrols you
//
// Enrolment here is first-come — fine for a demo, not for a real members list.
// Swap `roster` for your database and drop `enrol_open`.
package main

import "core:fmt"
import "core:strings"
import "core:sync"
import "otsh:sshtui"
import "otsh:tui"

// In a real app this is a database. Keys are pseudonymous ids (see
// ssh/identity.odin), never fingerprints and never public keys.
roster: map[string]Member
roster_mu: sync.Mutex
enrol_open := true

Member :: struct {
	id:     string,
	number: int,
	visits: int,
}

// Looks up (or enrols) the caller. Returns the member and whether they are one.
recognise :: proc(id: string) -> (Member, bool) {
	if id == "" {
		return {}, false
	}
	sync.lock(&roster_mu)
	defer sync.unlock(&roster_mu)

	if m, found := roster[id]; found {
		m.visits += 1
		roster[id] = m
		return m, true
	}
	if !enrol_open {
		return {}, false
	}
	m := Member {
		// `id` points into the connection's own buffer and dies with it, so the
		// roster key has to be an owned copy. sshtui.clone_info does the same
		// for a whole Info.
		id     = strings.clone(id),
		number = len(roster) + 1,
		visits = 1,
	}
	roster[m.id] = m
	return m, true
}

State :: struct {
	info:   sshtui.Info,
	member: Member,
	is_member: bool,
}

update :: proc(p: ^tui.Program, msg: tui.Msg) {
	#partial switch m in msg {
	case tui.Key:
		if m.kind == .Esc || (m.kind == .Rune && (m.r == 'q' || m.ctrl && m.r == 'c')) {
			tui.quit(p)
		}
	}
}

view :: proc(p: ^tui.Program, sc: ^tui.Screen) {
	defer free_all(context.temp_allocator)
	s := (^State)(p.app.data)

	dim := tui.Style{fg = tui.ansi(8)}
	if !s.is_member {
		deny(s, sc, dim)
		return
	}

	ok := tui.Style{fg = tui.ansi(10), attrs = {.Bold}}
	val := tui.Style{fg = tui.ansi(15)}

	w := min(sc.w - 4, 64)
	x := (sc.w - w) / 2
	y := max(sc.h / 2 - 6, 1)

	tui.draw_box(sc, x, y, w, 10, tui.Style{fg = tui.ansi(10)}, tui.BORDER_ROUND, " members ")
	tui.draw_text(sc, x + 3, y + 2, "welcome back", ok)

	rows := [][2]string {
		{"member no.", fmt.tprintf("#%d", s.member.number)},
		{"visits", fmt.tprintf("%d", s.member.visits)},
		{"account id", s.member.id},
		{"key", s.info.key_type},
	}
	for row, i in rows {
		tui.draw_text(sc, x + 3, y + 4 + i, row[0], dim)
		tui.draw_text_clipped(sc, x + 16, y + 4 + i, w - 19, row[1], val)
	}
	tui.draw_text(sc, x + 3, y + 9, " q to quit ", dim)
}

deny :: proc(s: ^State, sc: ^tui.Screen, dim: tui.Style) {
	lines := [?]string {
		"this is a members-only server",
		"",
		s.info.auth_method == "publickey" \
		? "your key is not on the list" \
		: "connect with an ssh key to be recognised",
		"",
		"nothing about your connection has been stored",
	}
	y := max((sc.h - len(lines)) / 2, 1)
	for line, i in lines {
		if line == "" {continue}
		st := i == 0 ? tui.Style{fg = tui.ansi(11), attrs = {.Bold}} : dim
		tui.draw_text_clipped(
			sc,
			max((sc.w - tui.text_width(line)) / 2, 0),
			y + i,
			sc.w,
			line,
			st,
		)
	}
}

create :: proc(info: sshtui.Info) -> tui.App {
	s := new(State)
	s.info = info
	s.member, s.is_member = recognise(info.id)
	return tui.App{data = s, update = update, view = view}
}

destroy :: proc(app: tui.App) {
	free(app.data)
}

connected :: proc(info: sshtui.Info) {
	// Log the pseudonymous id, never the fingerprint or the key.
	fmt.printfln("members: session id=%s auth=%s", info.id, info.auth_method)
}

main :: proc() {
	roster = make(map[string]Member)

	sshtui.serve(
		sshtui.Config {
			port            = 2226,
			host_key_path   = "members_hostkey",
			identity_secret = "members_secret", // enables Info.id
			create          = create,
			destroy         = destroy,
			on_connect      = connected,
			// Required for a key-identity app: every OpenSSH client probes the
			// "none" method first, and if we accept it the client never offers
			// a key at all — Info.id would always be empty. Not offering "none"
			// costs nothing in privacy: the client still stops at its *first*
			// key, because we accept that one.
			methods         = {.Publickey},
			// Note what is NOT here: no `authenticate`. Everyone gets in at the
			// SSH layer; `view` decides what they see. That is the whole trick.
		},
	)
}
