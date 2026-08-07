// Put `otsh` on $PATH, so the checkout stops being something you have to
// type.
//
// A symlink, never a copy — and it points at the bootstrap script at the
// checkout root, not at this binary: the bootstrap locates the collection
// relative to its own real path and rebuilds the tool when its sources
// change, so the symlink keeps working across a `git pull`. A copy sitting in
// ~/.local/bin has no ssh/ or tui/ beside it and nothing builds. `install` is
// the one chore left after `git clone`, and it can at least do itself.
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

cmd_install :: proc(args: []string) {
	want_uninstall := false
	if len(args) > 0 {
		switch args[0] {
		case "--uninstall":
			want_uninstall = true
		case:
			die(fmt.tprintf("usage: %s install [--uninstall]", PROG))
		}
	}

	// Prefer somewhere already on $PATH; fall back to the XDG-ish default,
	// which is where a user-level binary belongs even if $PATH lags behind.
	home := home_dir()
	xdg_bin := os.get_env("XDG_BIN_HOME", context.allocator)
	candidates := [4]string{
		xdg_bin,
		path_join(home, ".local", "bin"),
		path_join(home, "bin"),
		"/usr/local/bin",
	}
	path_env := strings.concatenate({":", os.get_env("PATH", context.allocator), ":"}, context.allocator)
	dir := ""
	for d in candidates {
		if d == "" {
			continue
		}
		if strings.contains(path_env, strings.concatenate({":", d, ":"}, context.allocator)) &&
		   is_writable_dir(d) {
			dir = d
			break
		}
	}
	if dir == "" {
		dir = xdg_bin if xdg_bin != "" else path_join(home, ".local", "bin")
	}
	target := path_join(dir, "otsh")
	source := path_join(OTSH, "otsh")

	if want_uninstall {
		if is_symlink(target) {
			os.remove(target)
			fmt.printf("%s: removed %s\n", PROG, target)
		} else {
			fmt.printf("%s: nothing to remove at %s\n", PROG, target)
		}
		return
	}

	// Refuse to clobber something that is not ours rather than silently
	// replacing a real file somebody put there.
	if os.exists(target) && !is_symlink(target) {
		die(fmt.tprintf("%s exists and is not a symlink; move it aside first", target))
	}

	if !mkdir_p(dir) {
		die(fmt.tprintf("cannot create %s", dir))
	}
	if is_symlink(target) {
		os.remove(target)
	}
	if err := os.symlink(source, target); err != nil {
		die(fmt.tprintf("cannot write %s", target))
	}
	fmt.printf("%s: %s -> %s\n", PROG, target, source)

	if strings.contains(path_env, strings.concatenate({":", dir, ":"}, context.allocator)) {
		fmt.printf("\nready — `otsh doctor` from anywhere.\n")
	} else {
		shell := os.get_env("SHELL", context.allocator)
		if i := strings.last_index_byte(shell, '/'); i >= 0 {
			shell = shell[i + 1:]
		}
		hint: string
		switch shell {
		case "fish":
			hint = fmt.aprintf("fish_add_path %s", dir)
		case "zsh":
			hint = fmt.aprintf("echo 'export PATH=\"%s:$PATH\"' >> ~/.zshrc", dir)
		case:
			hint = fmt.aprintf("echo 'export PATH=\"%s:$PATH\"' >> ~/.bashrc", dir)
		}
		fmt.printf("\n%s is not on your $PATH yet. Add it:\n  %s\n", dir, hint)
		fmt.printf("then open a new shell, or run it now with:\n  %s doctor\n", target)
	}
}
