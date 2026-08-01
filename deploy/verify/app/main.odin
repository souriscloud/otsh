// The app deploy/verify runs under systemd to exercise the deploy/ stack
// against real traffic.
//
// It is examples/tracker's externally visible contract — port 2222, host key
// at "tracker_hostkey", identity secret at "tracker_secret", publickey-only —
// with two additions the verification needs:
//
//   * Config.audit is set (the stock tracker leaves it nil, and with a nil
//     sink fail2ban has nothing to read);
//   * the authenticator refuses user "mallory", so a test can generate real
//     `event=auth ... method=publickey ... ok=false` lines on demand instead
//     of relying only on the method=none refusal every OpenSSH client
//     produces on its way in.
//
// The TUI itself is deliberately nothing: one line of text, q to quit. What
// matters is that it is a real tui.run loop, so a SIGTERM during `systemctl
// restart` exercises the real terminal-restore path (alternate screen left,
// cursor shown) that deploy/otsh.service's TimeoutStopSec exists to protect.
package main

import "core:os"
import "otsh:ssh"
import "otsh:sshtui"
import "otsh:tui"

update :: proc(p: ^tui.Program, msg: tui.Msg) {
	#partial switch m in msg {
	case tui.Key:
		if m.kind == .Esc || (m.kind == .Rune && (m.r == 'q' || m.ctrl && m.r == 'c')) {
			tui.quit(p)
		}
	}
}

view :: proc(p: ^tui.Program, sc: ^tui.Screen) {
	tui.draw_text(sc, 2, 1, "otsh deploy-verify app — q quits", tui.Style{})
}

create :: proc(info: sshtui.Info) -> tui.App {
	return tui.App{update = update, view = view}
}

destroy :: proc(app: tui.App) {}

gate :: proc(req: ssh.Auth_Request) -> bool {
	return req.user != "mallory"
}

main :: proc() {
	cfg := sshtui.Config {
		port            = 2222,
		host_key_path   = "tracker_hostkey",
		identity_secret = "tracker_secret",
		methods         = {.Publickey},
		authenticate    = gate,
		audit           = ssh.audit_stderr,
		create          = create,
		destroy         = destroy,
	}
	if !sshtui.serve(cfg) {
		os.exit(1)
	}
}
