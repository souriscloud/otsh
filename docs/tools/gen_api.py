#!/usr/bin/env python3
"""Generate an exhaustive API reference from the Odin sources.

    python3 docs/tools/gen_api.py            # writes docs/api-<pkg>.md
    python3 docs/tools/gen_api.py --check    # fail if the checked-in pages are stale

Every exported declaration in each package gets an entry: its exact signature,
its doc comment, and where it lives. Generated rather than hand-written so it
cannot drift from the code — if you want better prose here, write a better doc
comment on the declaration and re-run this.

The hand-written pages (tui.md, ssh.md, sshtui.md) explain how the pieces fit
together and why. These pages are for looking a single thing up.

Standard library only, like the rest of docs/tools.
"""
import argparse, glob, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DOCS = os.path.join(ROOT, "docs")

PACKAGES = [
    ("tui", "otsh:tui", "Screen, styles, drawing, the frame loop, and input decoding. "
                        "No dependency on `ssh` — usable for a purely local TUI."),
    ("ssh", "otsh:ssh", "The SSH server: bind, handshake, auth, pty and shell requests, "
                        "then a byte stream. No dependency on `tui`."),
    ("sshtui", "otsh:sshtui", "The glue: adapts an `ssh.Session` into a `tui.Backend` and "
                              "runs one `tui.Program` per connection."),
    ("libssh", "otsh:libssh", "Raw bindings to libssh's server API. Everything here maps "
                              "1:1 onto the C function of the same name, so libssh's own "
                              "documentation is authoritative for semantics."),
]

KIND_ORDER = ["Types", "Constants", "Procedures"]


def classify(name, rhs):
    r = rhs.lstrip()
    if r.startswith(("struct", "enum", "union", "distinct", "bit_set")) or \
       r.startswith("#type") or "proc(" in r.split("::")[0] and r.startswith("#type"):
        return "Types"
    if r.startswith("proc"):
        return "Procedures"
    if name.isupper() or re.match(r"^[A-Z][A-Z0-9_]*$", name):
        return "Constants"
    if r.startswith(("\"", "'")) or re.match(r"^-?\d", r):
        return "Constants"
    return "Constants"


def doc_line(raw):
    """Text of one `//`-prefixed doc-comment line, keeping its indentation.

    Strips only the leading `//` and at most one following space — never a
    tab. That lets a doc comment carry a tab-indented block (render() turns a
    run of those into a fenced code block) without losing the indentation
    that marks it as one.
    """
    text = raw[2:]
    if text[:1] == " ":
        text = text[1:]
    return text.rstrip()


def signature(lines, i):
    """The declaration text, trimmed at the body brace but keeping the params."""
    buf, depth, started = [], 0, False
    for ln in lines[i:i + 40]:
        # stop before a struct/enum body we do not want to inline wholesale
        buf.append(ln.rstrip())
        for ch in ln:
            if ch in "({[":
                depth += 1
                started = True
            elif ch in ")}]":
                depth -= 1
        text = "\n".join(buf)
        if started and depth <= 0:
            break
        if not started and ln.rstrip().endswith(("{",)):
            break
    text = "\n".join(buf)
    # For procs, cut the body: keep everything up to the opening brace.
    m = re.search(r"\)\s*(->[^{]*)?\{", text)
    if m and " proc" in text.split("::")[1][:12]:
        text = text[:m.start() + m.group().index("{")].rstrip()
    # For structs/enums/unions keep the whole block (they are the API).
    return text.rstrip().rstrip("{").rstrip() if text.rstrip().endswith("{") else text.rstrip()


def parse(pkg):
    """Every exported declaration in a package, one entry per name.

    A platform-split package declares the same public name in more than one
    file (tui/local.odin and tui/local_windows.odin, ssh/perm_posix.odin and
    ssh/perm_windows.odin). One name is one API entry, so the first file in
    sorted order wins — which is the POSIX one in every split here, and POSIX
    is the platform this project actually supports.
    """
    out, seen = [], set()
    for path in sorted(glob.glob(os.path.join(ROOT, pkg, "*.odin"))):
        rel = os.path.relpath(path, ROOT)
        lines = open(path).read().split("\n")
        in_foreign = False
        for i, ln in enumerate(lines):
            if re.match(r"^\s*foreign\s+lib\s*\{", ln) or re.match(r"^@\(default_calling", ln):
                in_foreign = True
            if in_foreign and ln.startswith("}"):
                in_foreign = False

            # foreign block entries are indented: `name :: proc(...) ---`
            fm = re.match(r"^\t([a-z_][A-Za-z0-9_]*)\s*::\s*(proc.*---)", ln)
            if in_foreign and fm:
                doc, link, priv = [], None, False
                j = i - 1
                while j >= 0 and (lines[j].lstrip().startswith("//") or
                                  lines[j].lstrip().startswith("@")):
                    stripped = lines[j].lstrip()
                    lm = re.search(r'link_name\s*=\s*"([^"]+)"', lines[j])
                    if stripped.startswith("@(private"):
                        priv = True
                    elif lm:
                        link = lm.group(1)
                    elif stripped.startswith("//"):
                        doc.insert(0, doc_line(stripped))
                    j -= 1
                if priv or fm.group(1) in seen:
                    continue
                seen.add(fm.group(1))
                out.append({
                    "name": fm.group(1), "kind": "Procedures",
                    "sig": fm.group(2).replace(" ---", ""), "doc": " ".join(doc).strip(),
                    "src": f"{rel}:{i+1}", "c": link,
                })
                continue

            m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*::\s*(.*)$", ln)
            if not m:
                continue
            name, rhs = m.group(1), m.group(2)

            doc, priv, j = [], False, i - 1
            while j >= 0 and (lines[j].startswith("//") or lines[j].startswith("@")):
                if lines[j].startswith("@(private"):
                    priv = True
                elif lines[j].startswith("//"):
                    doc.insert(0, doc_line(lines[j]))
                j -= 1
            if priv or name in seen:
                continue
            seen.add(name)

            out.append({
                "name": name, "kind": classify(name, rhs),
                "sig": signature(lines, i), "doc": "\n".join(doc).strip(),
                "src": f"{rel}:{i+1}", "c": None,
            })
    return out


def render_doc(doc):
    """A doc string as Markdown lines, fencing tab-indented runs as code.

    A doc comment can carry a tab-indented block (see doc_line). Left alone,
    the site renderer has no indented-code rule and would glue it into the
    surrounding paragraph as flat prose — so each run of lines starting with
    a tab becomes a fenced block instead, with exactly one leading tab
    stripped from every line in it (preserving any deeper indentation inside
    the block).

    The convention this project uses: a block introduced by a line that reads
    exactly "Example:" is Odin and is fenced ```odin. Anything else — a
    table, a line-format grammar, the audit event list — is not code and
    stays plain ``` so a plain-Markdown viewer never syntax-highlights
    something that is not actually Odin.
    """
    lines = doc.split("\n")
    out = []
    example = False
    i = 0
    while i < len(lines):
        ln = lines[i]
        if ln.startswith("\t"):
            block = []
            while i < len(lines) and lines[i].startswith("\t"):
                block.append(lines[i][1:])
                i += 1
            if out and out[-1] != "":
                out.append("")
            out.append("```odin" if example else "```")
            out += block
            out.append("```")
            if i < len(lines) and lines[i] != "":
                out.append("")
            example = False
            continue
        if ln.strip() == "Example:":
            example = True
        elif ln.strip():
            example = False
        out.append(ln)
        i += 1
    return out


def render(pkg, import_path, blurb, syms):
    L = [f"# {import_path} — API reference", ""]
    L += [blurb, ""]
    L += [f"Generated from `{pkg}/*.odin` by `docs/tools/gen_api.py`. "
          f"For how these fit together, see the hand-written guide "
          f"({'[' + pkg + '](' + pkg + '.md)' if pkg != 'libssh' else '[ssh](ssh.md)'}).", ""]

    by_kind = {}
    for s in syms:
        by_kind.setdefault(s["kind"], []).append(s)

    # index
    L += ["## Contents", ""]
    for kind in KIND_ORDER:
        items = sorted(by_kind.get(kind, []), key=lambda s: s["name"].lower())
        if not items:
            continue
        links = ", ".join(f"[`{s['name']}`](#{anchor(s['name'])})" for s in items)
        L += [f"**{kind}** — {links}", ""]

    undocumented = 0
    for kind in KIND_ORDER:
        items = sorted(by_kind.get(kind, []), key=lambda s: s["name"].lower())
        if not items:
            continue
        L += [f"## {kind}", ""]
        for s in items:
            L += [f"### `{s['name']}`", ""]
            L += ["```odin", s["sig"], "```", ""]
            if s["doc"]:
                L += render_doc(s["doc"]) + [""]
            else:
                undocumented += 1
            # Plain Markdown only — the site renderer escapes raw HTML, and
            # these pages must also read correctly on a plain Markdown viewer.
            meta = f"*{s['src']}*"
            if s["c"]:
                meta += f" · C: `{s['c']}`"
            L += [meta, ""]
    return "\n".join(L).rstrip() + "\n", undocumented


def anchor(name):
    return name.lower().replace("_", "-")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true",
                    help="exit 1 if a generated page differs from what is on disk")
    a = ap.parse_args()

    stale, total_undoc = [], 0
    for pkg, imp, blurb in PACKAGES:
        syms = parse(pkg)
        text, undoc = render(pkg, imp, blurb, syms)
        total_undoc += undoc
        path = os.path.join(DOCS, f"api-{pkg}.md")
        old = open(path).read() if os.path.exists(path) else None
        if a.check:
            if old != text:
                stale.append(os.path.basename(path))
        else:
            open(path, "w").write(text)
            print(f"  api-{pkg}.md  {len(syms)} symbols, {undoc} without a doc comment")

    if a.check:
        if stale:
            print("stale (re-run gen_api.py): " + ", ".join(stale))
            sys.exit(1)
        print("api reference is up to date")
    else:
        print(f"\n{total_undoc} exported symbols still have no doc comment")


if __name__ == "__main__":
    main()
