// whoami — the smallest useful otsh app: shows who connected and how.
//
// Also demonstrates the auth hook and the audit log. This server requires
// public-key auth, so `info.fingerprint` is always populated.
//
//	./build.sh examples/whoami && ./whoami
//	ssh -p 2223 localhost
//
// Audit lines go to stderr, one per event, so `./whoami 2>audit.log` keeps the
// record separate from the app's own chatter on stdout.
package main

import "core:fmt"
import "otsh:ssh"
import "otsh:sshtui"
import "otsh:tui"

State :: struct {
	info:  sshtui.Info,
	frame: u64,
}

update :: proc(p: ^tui.Program, msg: tui.Msg) {
	s := (^State)(p.app.data)
	#partial switch m in msg {
	case tui.Tick:
		s.frame = m.frame
	case tui.Key:
		if m.kind == .Esc || (m.kind == .Rune && (m.r == 'q' || m.ctrl && m.r == 'c')) {
			tui.quit(p)
		}
	}
}

view :: proc(p: ^tui.Program, sc: ^tui.Screen) {
	defer free_all(context.temp_allocator)
	s := (^State)(p.app.data)

	label := tui.Style{fg = tui.ansi(8)}
	value := tui.Style{fg = tui.ansi(15), attrs = {.Bold}}

	rows := [][2]string {
		{"user", s.info.user},
		{"term", s.info.term},
		{"auth", s.info.auth_method},
		{"key type", s.info.key_type},
		{"fingerprint", s.info.fingerprint},
		{"size", fmt.tprintf("%d×%d", sc.w, sc.h)},
		{"frames", fmt.tprintf("%d", s.frame)},
		{"sent", fmt.tprintf("%d bytes", p.bytes_out)},
	}

	w := min(sc.w - 4, 64)
	x := (sc.w - w) / 2
	y := max((sc.h - len(rows) - 4) / 2, 1)

	tui.draw_box(sc, x, y, w, len(rows) + 4, tui.Style{fg = tui.ansi(6)}, tui.BORDER_ROUND, " whoami ")
	for row, i in rows {
		tui.draw_text(sc, x + 3, y + 2 + i, row[0], label)
		tui.draw_text_clipped(sc, x + 16, y + 2 + i, w - 19, row[1], value)
	}
	tui.draw_text(sc, x + 3, y + len(rows) + 3, " q to quit ", label)
}

create :: proc(info: sshtui.Info) -> tui.App {
	s := new(State)
	s.info = info
	return tui.App{data = s, update = update, view = view}
}

destroy :: proc(app: tui.App) {
	free(app.data)
}

// Called during authentication, before the app exists. Return false to reject.
// A real app would look the fingerprint up in a database here.
//
// This prints the fingerprint because the whole point of the example is to show
// it to you. An audit trail you keep should not: `audit` below logs the
// pseudonymous id instead, which does not correlate with any other service.
gate :: proc(req: ssh.Auth_Request) -> bool {
	fmt.printfln("whoami: auth attempt user=%s method=%v key=%s", req.user, req.method, req.fingerprint)
	return true
}

main :: proc() {
	sshtui.serve(
		sshtui.Config {
			port          = 2223,
			host_key_path = "whoami_hostkey",
			create        = create,
			destroy       = destroy,
			authenticate  = gate,
			methods       = {.Publickey}, // no anonymous access
			audit         = ssh.audit_stderr, // one parseable line per event
		},
	)
}
