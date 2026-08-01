#!/usr/bin/env python3
"""Capture a real frame from an otsh app and render it as SVG.

This drives the app the way a user would — a real ssh client on a real pty —
then parses the escape stream it sent back and draws the resulting cell grid.
The screenshots in these docs are therefore actual output, not mockups.

Authoring-time tool only. Reading the docs needs nothing; the generated SVGs
are committed. Requires `pyte` (pip install pyte).

    python3 docs/tools/capture.py --port 2222 --keys "jj" \\
        --title "ssh -p 2222 localhost" --out docs/assets/tracker-list.svg

    python3 docs/tools/capture.py --local ./stopwatch --keys " " \\
        --title "stopwatch" --out docs/assets/stopwatch.svg
"""
import argparse, fcntl, os, pty, re, select, struct, sys, termios, time

try:
    import pyte
except ImportError:
    sys.exit("capture.py needs pyte:  pip install pyte")

# --- terminal palette used to resolve pyte's named colours ------------------
NAMED = {
    "black": "1c1b22", "red": "e05561", "green": "7ec490", "brown": "e9a658",
    "yellow": "e9a658", "blue": "6cb6eb", "magenta": "c08cdc", "cyan": "5fb3b3",
    "white": "dedae2", "brightblack": "6b6676", "brightred": "ec7a85",
    "brightgreen": "9bd4a8", "brightyellow": "f0bd7c", "brightblue": "8ac6f2",
    "brightmagenta": "cfa3e6", "brightcyan": "84c9c9", "brightwhite": "ffffff",
}
FG_DEFAULT = "dedae2"
BG_DEFAULT = "1c1b22"


def resolve(colour, default):
    if colour in (None, "default"):
        return default
    if colour in NAMED:
        return NAMED[colour]
    if re.fullmatch(r"[0-9a-fA-F]{6}", colour or ""):
        return colour.lower()
    return default


def drive(argv):
    """Run the app under a pty, send keystrokes, return the raw byte stream."""
    cols, rows = argv.cols, argv.rows
    pid, fd = pty.fork()
    if pid == 0:
        if argv.local:
            os.environ["TERM"] = "xterm-256color"
            os.execv(argv.local, [argv.local] + argv.args)
        cmd = ["ssh", "-p", str(argv.port)]
        if argv.key:
            cmd += ["-i", argv.key, "-o", "IdentitiesOnly=yes"]
        cmd += ["-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "LogLevel=ERROR",
                "-o", "ConnectTimeout=8", argv.host]
        os.execvp("ssh", cmd)

    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    buf = bytearray()

    def pump(seconds):
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.05)
            if r:
                try:
                    chunk = os.read(fd, 65536)
                except OSError:
                    return False
                if not chunk:
                    return False
                buf.extend(chunk)
        return True

    pump(argv.settle)
    for ch in argv.keys.encode().decode("unicode_escape"):
        os.write(fd, ch.encode())
        pump(argv.key_delay)
    pump(argv.hold)

    try:
        os.write(fd, b"\x03")
        os.close(fd)
    except OSError:
        pass
    return bytes(buf)


def to_svg(data, cols, rows, title):
    screen = pyte.Screen(cols, rows)
    pyte.Stream(screen).feed(data.decode("utf-8", "replace"))

    CW, CH, FS = 8.4, 17.0, 14.0        # cell width, line height, font size
    PAD_X, PAD_Y, BAR = 16, 14, 28      # padding and title-bar height
    w = cols * CW + PAD_X * 2
    h = rows * CH + PAD_Y * 2 + BAR

    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w:.0f}" height="{h:.0f}" '
        f'viewBox="0 0 {w:.1f} {h:.1f}" font-family="ui-monospace,SFMono-Regular,'
        f'Menlo,Consolas,monospace" font-size="{FS}">',
        f'<rect width="{w:.1f}" height="{h:.1f}" rx="8" fill="#{BG_DEFAULT}"/>',
        f'<rect width="{w:.1f}" height="{BAR}" rx="8" fill="#26252e"/>',
        f'<rect y="{BAR-8}" width="{w:.1f}" height="8" fill="#26252e"/>',
    ]
    for i, c in enumerate(("#e05561", "#e9a658", "#7ec490")):
        out.append(f'<circle cx="{18+i*16}" cy="{BAR/2}" r="5" fill="{c}"/>')
    if title:
        out.append(
            f'<text x="{w/2:.1f}" y="{BAR/2+4:.1f}" fill="#8b8797" font-size="11.5" '
            f'text-anchor="middle">{esc(title)}</text>')

    # Background rects first, then glyph runs on top.
    for y in range(rows):
        line = screen.buffer[y]
        for x in range(cols):
            ch = line[x]
            bg = resolve(ch.bg, None)
            if ch.reverse:
                bg = resolve(ch.fg, FG_DEFAULT)
            if bg:
                out.append(
                    f'<rect x="{PAD_X+x*CW:.1f}" y="{BAR+PAD_Y+y*CH:.1f}" '
                    f'width="{CW+0.5:.1f}" height="{CH:.1f}" fill="#{bg}"/>')

    for y in range(rows):
        line = screen.buffer[y]
        run, run_style, run_x = [], None, 0
        def flush(run, style, rx, yy):
            text = "".join(run).rstrip()
            if not text.strip():
                return
            fg, bold = style
            weight = ' font-weight="600"' if bold else ""
            out.append(
                f'<text x="{PAD_X+rx*CW:.1f}" y="{BAR+PAD_Y+yy*CH+FS*0.82:.1f}" '
                f'fill="#{fg}"{weight} xml:space="preserve">{esc(text)}</text>')
        for x in range(cols):
            ch = line[x]
            fg = resolve(ch.fg, FG_DEFAULT)
            if ch.reverse:
                fg = resolve(ch.bg, BG_DEFAULT)
            style = (fg, ch.bold)
            if style != run_style:
                if run:
                    flush(run, run_style, run_x, y)
                run, run_style, run_x = [], style, x
            run.append(ch.data if ch.data else " ")
        if run:
            flush(run, run_style, run_x, y)

    out.append("</svg>")
    return "\n".join(out)


def esc(s):
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", type=int, default=2222)
    ap.add_argument("--host", default="localhost")
    ap.add_argument("--key", help="ssh identity file")
    ap.add_argument("--local", help="run this binary directly instead of ssh")
    ap.add_argument("--args", nargs="*", default=[], help="args for --local")
    ap.add_argument("--keys", default="", help=r"keystrokes, e.g. 'jj\r'")
    ap.add_argument("--cols", type=int, default=88)
    ap.add_argument("--rows", type=int, default=26)
    ap.add_argument("--settle", type=float, default=1.5, help="wait before typing")
    ap.add_argument("--key-delay", type=float, default=0.25)
    ap.add_argument("--hold", type=float, default=1.0, help="wait after typing")
    ap.add_argument("--title", default="")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    data = drive(a)
    if len(data) < 200:
        sys.exit(f"capture failed: only {len(data)} bytes came back")
    svg = to_svg(data, a.cols, a.rows, a.title)
    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    with open(a.out, "w") as f:
        f.write(svg)
    print(f"{a.out}  ({len(data)} bytes captured -> {len(svg)} bytes svg)")


if __name__ == "__main__":
    main()
