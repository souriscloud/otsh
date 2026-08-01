#!/usr/bin/env python3
"""Render docs/*.md into a browsable static HTML site.

Pure standard library — no pip install, no network, no build step beyond
running this file. That is deliberate: documentation you cannot build is
documentation that rots.

    python3 docs/tools/build_site.py            # -> docs/site/
    python3 docs/tools/build_site.py --serve    # build, then serve on :8000

The Markdown subset handled here is the subset these docs actually use:
headings, fenced code, tables, lists, blockquotes, rules, images, links,
and inline code/bold/italic. It is not a general Markdown implementation.

Everything the generated pages do at runtime — theme toggle, code-block
copy buttons, the "on this page" mini-TOC, client-side search — is inline
or same-directory JS/CSS loaded via relative <script src>/<link href>, so
the site works offline and from file:// with zero network access.
"""
import argparse, errno, glob, html, json, os, re, shutil, sys

DOCS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(DOCS, "site")

# Order of the sidebar. Anything not listed is appended alphabetically.
# Sources outside docs/ that are pulled into the site, mapped to output names.
EXTERNAL = {
    os.path.join(os.path.dirname(DOCS), "README.md"): "readme.html",
    # The changelog lives at the repository root, where a release process and
    # GitHub both look for it. The output name keeps its case so that a
    # `../CHANGELOG.md` link from docs/ rewrites onto exactly this file.
    os.path.join(os.path.dirname(DOCS), "CHANGELOG.md"): "CHANGELOG.html",
}

# Sidebar labels. Page titles are full sentences, which wrap badly in a narrow
# column, so the nav gets its own short names.
NAV_TITLES = {
    "index.md": "Overview",
    "readme.md": "README",
    "getting-started.md": "Getting started",
    "concepts.md": "The basics",
    "tutorial-first-app.md": "First app (10 min)",
    "tutorial-tui.md": "Stopwatch (local)",
    "tutorial-guestbook.md": "Guestbook (SSH)",
    "tutorial-notes.md": "Notes (multi-view)",
    "cookbook.md": "Cookbook",
    "tui.md": "tui — guide",
    "ssh.md": "ssh — guide",
    "sshtui.md": "sshtui — guide",
    "api-tui.md": "tui",
    "api-ssh.md": "ssh",
    "api-sshtui.md": "sshtui",
    "api-libssh.md": "libssh",
    "security.md": "Security model",
    "architecture.md": "Architecture",
    "bindings.md": "C bindings",
    "compatibility.md": "Compatibility",
    "deploy.md": "Deployment",
    "CHANGELOG.md": "Changelog",
    "releasing.md": "Releasing",
    "migrating.md": "Migrating",
}

NAV = [
    ("Start", ["index.md", "readme.md", "getting-started.md", "concepts.md"]),
    ("Tutorials", ["tutorial-first-app.md", "tutorial-tui.md",
                   "tutorial-guestbook.md", "tutorial-notes.md"]),
    ("Guides", ["cookbook.md", "tui.md", "ssh.md", "sshtui.md"]),
    ("API reference", ["api-tui.md", "api-ssh.md", "api-sshtui.md", "api-libssh.md"]),
    ("Understanding", ["security.md", "architecture.md", "bindings.md"]),
    ("Operations", ["deploy.md", "compatibility.md"]),
    ("Releases", ["CHANGELOG.md", "releasing.md", "migrating.md"]),
]

ODIN_KW = r"""package|import|proc|struct|enum|union|bit_set|distinct|map|matrix|using|
defer|return|if|else|for|switch|case|break|continue|fallthrough|when|in|not_in|
do|dynamic|cast|transmute|auto_cast|context|or_else|or_return|foreign|where"""
ODIN_KW = "|".join(x.strip() for x in ODIN_KW.split("|") if x.strip())
ODIN_LIT = r"true|false|nil"
ODIN_TYPE = (r"string|cstring|rune|byte|bool|rawptr|uintptr|int|uint|i8|i16|i32|i64|"
             r"u8|u16|u32|u64|f16|f32|f64|any|typeid")


def highlight(code, lang):
    """Very small tokenizer. Correctness over cleverness: anything unmatched
    is emitted as plain escaped text."""
    out, i, n = [], 0, len(code)
    if lang in ("sh", "bash", "shell", "console", ""):
        for line in code.split("\n"):
            if line.lstrip().startswith("#"):
                out.append(f'<span class="c">{html.escape(line)}</span>')
            else:
                line = html.escape(line)
                line = re.sub(r"(&#x27;[^&]*?&#x27;|&quot;[^&]*?&quot;)",
                              r'<span class="s">\1</span>', line)
                out.append(line)
        return "\n".join(out)

    token = re.compile(
        r"(?P<c>//[^\n]*)"
        r"|(?P<s>\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|`[^`]*`)"
        r"|(?P<n>\b\d[\d_]*(?:\.\d+)?\b)"
        r"|(?P<w>[A-Za-z_][A-Za-z0-9_]*)"
    )
    while i < n:
        m = token.search(code, i)
        if not m:
            out.append(html.escape(code[i:]))
            break
        out.append(html.escape(code[i:m.start()]))
        kind = m.lastgroup
        text = html.escape(m.group())
        if kind == "w":
            word = m.group()
            after = code[m.end():m.end() + 3]
            if re.fullmatch(ODIN_KW, word):
                out.append(f'<span class="k">{text}</span>')
            elif re.fullmatch(ODIN_LIT, word):
                out.append(f'<span class="l">{text}</span>')
            elif re.fullmatch(ODIN_TYPE, word):
                out.append(f'<span class="t">{text}</span>')
            elif after.startswith(" ::"):
                out.append(f'<span class="d">{text}</span>')
            elif word[0].isupper():
                out.append(f'<span class="t">{text}</span>')
            else:
                out.append(text)
        else:
            out.append(f'<span class="{kind}">{text}</span>')
        i = m.end()
    return "".join(out)


# GitHub-flavored Markdown permits inline HTML, and a good landing page uses it
# (image grids, badges side by side). Pass a conservative allowlist through
# instead of escaping it — but never scripting, embedding, or event handlers.
HTML_OK = {
    "a", "b", "br", "code", "div", "em", "h1", "h2", "h3", "h4", "h5", "h6",
    "hr", "i", "img", "kbd", "li", "ol", "p", "picture", "pre", "small",
    "source", "span", "strong", "sub", "summary", "sup", "table", "tbody",
    "td", "details", "th", "thead", "tr", "ul", "blockquote",
}
HTML_TAG = re.compile(r"</?([a-zA-Z][a-zA-Z0-9]*)((?:\s[^<>]*)?)/?>")


def rewrite_path(href):
    """Map a repo-relative path onto its place in the flat generated site."""
    if href.startswith(("http", "https", "data:", "mailto:", "#")):
        return href
    if href.startswith("docs/"):
        href = href[len("docs/"):]
    if href.endswith(".odin") or "/examples/" in href:
        rel = href[href.index("examples/"):] if "examples/" in href else href
        return rel + ".txt" if rel.endswith(".odin") else rel
    # Deployment configs are linked from the ops guide the same way example
    # sources are linked from the tutorials: copied into the site as .txt so
    # the link resolves offline.
    if "deploy/" in href and not href.endswith(".md"):
        return href[href.index("deploy/"):] + ".txt"
    if href.rstrip("/").endswith("README.md"):
        return "readme.html"
    if href.endswith(".md"):
        return os.path.basename(href)[:-3] + ".html"
    if ".md#" in href:
        base, _, frag = href.partition("#")
        return os.path.basename(base)[:-3] + ".html#" + frag
    return href


def sanitize_html(tag_text, name, attrs):
    """Drop anything with an event handler or a javascript: URL."""
    low = attrs.lower()
    if "javascript:" in low or re.search(r"\bon[a-z]+\s*=", low):
        return None
    return tag_text


def slug(text):
    s = re.sub(r"<[^>]+>", "", text).lower()
    s = re.sub(r"[^\w\s-]", "", s)
    return re.sub(r"[\s_]+", "-", s).strip("-")


def strip_tags(text):
    """Plain text for the search index and result snippets: drop tags,
    decode entities and collapse whitespace. inline()/render() output has
    already HTML-escaped everything, so this is the inverse for a consumer
    that wants prose rather than markup."""
    text = re.sub(r"<[^>]+>", " ", text)
    text = html.unescape(text)
    return re.sub(r"\s+", " ", text).strip()


def snippet(text, limit=200):
    text = text.strip()
    if len(text) <= limit:
        return text
    cut = text[:limit].rsplit(" ", 1)[0]
    return cut + "…"


def inline(text):
    """Inline markup. Code spans are pulled out first so their contents are
    never treated as markup."""
    spans = []

    def stash(m):
        spans.append(html.escape(m.group(1)))
        return f"\x00{len(spans)-1}\x00"

    text = re.sub(r"`([^`]+)`", stash, text)

    raw = []

    def stash_html(m):
        name = m.group(1).lower()
        if name not in HTML_OK:
            return m.group(0)
        kept = sanitize_html(m.group(0), name, m.group(2) or "")
        if kept is None:
            return ""
        raw.append(kept)
        return f"\x01{len(raw)-1}\x01"

    text = HTML_TAG.sub(stash_html, text)
    text = html.escape(text)
    for i, t in enumerate(raw):
        text = text.replace(f"\x01{i}\x01", t)
    # images before links — the pattern differs only by the leading !
    def image(m):
        src = m.group(2)
        if src.startswith("docs/"):
            src = src[len("docs/"):]          # README lives a level up
        return f'<img src="{src}" alt="{m.group(1)}" loading="lazy">'

    text = re.sub(r"!\[([^\]]*)\]\(([^)]+)\)", image, text)

    def link(m):
        label, href = m.group(1), m.group(2)
        href = rewrite_path(href)
        if href.rstrip("/").endswith("README.md"):
            href = "readme.html"
        elif href.endswith(".md"):
            # the site is flat, so docs/foo.md and ./foo.md both land on foo.html
            href = os.path.basename(href)[:-3] + ".html"
        elif ".md#" in href:
            href = href.replace(".md#", ".html#")
        ext = ' target="_blank" rel="noopener"' if href.startswith("http") else ""
        return f'<a href="{href}"{ext}>{label}</a>'

    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", link, text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<![\w*])\*([^*\n]+)\*(?![\w*])", r"<em>\1</em>", text)
    for i, s in enumerate(spans):
        text = text.replace(f"\x00{i}\x00", f"<code>{s}</code>")
    return text


def render(md):
    """Markdown -> (html, outline, sections) for one page.

    outline is [(level, id, title)] for h1-h3 — the page's table of
    contents, used to build the right-rail "on this page" mini-TOC.

    sections carries the same boundaries plus a plain-text snippet of each
    section's prose, used to build the search index: one entry per heading
    (h1-h3; an h4 folds into its enclosing section rather than starting a
    new one), each with up to ~200 characters of what follows it.

    Heading ids are deduplicated on repeat (foo, foo-1, foo-2, ...) without
    changing the id a heading gets the *first* time its text occurs in the
    document, so existing #anchor links (e.g. docs linking to
    security.md#11-independent-audit-findings) never move.
    """
    md = re.sub(r"<!--.*?-->", "", md, flags=re.S)  # comments are not content
    lines = md.split("\n")
    out, toc, i = [], [], 0
    slug_seen = {}
    sections = []
    cur = {"level": 0, "id": None, "title": None, "text": []}

    def flush():
        text = snippet(" ".join(t for t in cur["text"] if t))
        if cur["title"] is not None or text:
            sections.append({"level": cur["level"], "id": cur["id"],
                              "title": cur["title"], "text": text})

    def add_text(fragment):
        plain = strip_tags(fragment)
        if plain:
            cur["text"].append(plain)

    while i < len(lines):
        line = lines[i]

        if line.startswith("```"):
            lang = line[3:].strip()
            i += 1
            body = []
            while i < len(lines) and not lines[i].startswith("```"):
                body.append(lines[i])
                i += 1
            i += 1
            code = highlight("\n".join(body), lang)
            lang_attr = html.escape(lang, quote=True)
            tag = (f'<div class="code" data-lang="{lang_attr}">'
                   f'<pre><code>{code}</code></pre></div>')
            out.append(tag)
            continue

        m = re.match(r"^(#{1,4})\s+(.*)$", line)
        if m:
            lvl, title = len(m.group(1)), inline(m.group(2))
            base = slug(m.group(2))
            n = slug_seen.get(base, 0)
            slug_seen[base] = n + 1
            sid = base if n == 0 else f"{base}-{n}"
            if lvl <= 3:
                toc.append((lvl, sid, re.sub(r"<[^>]+>", "", title)))
                flush()
                cur = {"level": lvl, "id": sid, "title": strip_tags(title), "text": []}
            else:
                add_text(title)
            out.append(f'<h{lvl} id="{sid}">{title}'
                       f'<a class="anchor" href="#{sid}" aria-label="link">#</a></h{lvl}>')
            i += 1
            continue

        if re.match(r"^\s*\|.*\|\s*$", line) and i + 1 < len(lines) \
                and re.match(r"^\s*\|[\s:|-]+\|\s*$", lines[i + 1]):
            def cells(row):
                return [c.strip() for c in row.strip().strip("|").split("|")]
            head = cells(line)
            i += 2
            body = []
            while i < len(lines) and re.match(r"^\s*\|.*\|\s*$", lines[i]):
                body.append(cells(lines[i]))
                i += 1
            t = ["<div class='tablewrap'><table><thead><tr>"]
            t += [f"<th>{inline(c)}</th>" for c in head]
            t.append("</tr></thead><tbody>")
            for row in body:
                t.append("<tr>" + "".join(f"<td>{inline(c)}</td>" for c in row) + "</tr>")
            t.append("</tbody></table></div>")
            tag = "".join(t)
            out.append(tag)
            add_text(tag)
            continue

        if re.match(r"^\s*(---+|\*\*\*+)\s*$", line):
            out.append("<hr>")
            i += 1
            continue

        if line.startswith(">"):
            body = []
            while i < len(lines) and lines[i].startswith(">"):
                body.append(lines[i].lstrip(">").strip())
                i += 1
            tag = f"<blockquote>{inline(' '.join(body))}</blockquote>"
            out.append(tag)
            add_text(tag)
            continue

        m = re.match(r"^(\s*)([-*]|\d+\.)\s+(.*)$", line)
        if m:
            ordered = bool(re.match(r"\d+\.", m.group(2)))
            tagname = "ol" if ordered else "ul"
            items, base = [], len(m.group(1))
            while i < len(lines):
                mm = re.match(r"^(\s*)([-*]|\d+\.)\s+(.*)$", lines[i])
                if mm and len(mm.group(1)) >= base:
                    text = mm.group(3)
                    i += 1
                    # continuation lines belong to the current item
                    while i < len(lines) and lines[i].strip() and \
                            not re.match(r"^(\s*)([-*]|\d+\.)\s+", lines[i]) and \
                            not lines[i].startswith("```") and \
                            lines[i].startswith(" "):
                        text += " " + lines[i].strip()
                        i += 1
                    items.append(inline(text))
                elif not lines[i].strip() and i + 1 < len(lines) and \
                        re.match(r"^(\s*)([-*]|\d+\.)\s+", lines[i + 1]):
                    i += 1
                else:
                    break
            tag = f"<{tagname}>" + "".join(f"<li>{x}</li>" for x in items) + f"</{tagname}>"
            out.append(tag)
            add_text(tag)
            continue

        # Raw HTML block: emit verbatim rather than wrapping it in <p>.
        bm = re.match(r"^\s*<([a-zA-Z][a-zA-Z0-9]*)", line)
        if bm and bm.group(1).lower() in HTML_OK and bm.group(1).lower() not in (
            "code", "b", "i", "em", "strong", "sub", "sup", "kbd", "small", "span", "a"
        ):
            block = []
            while i < len(lines) and lines[i].strip():
                block.append(lines[i])
                i += 1
            joined = "\n".join(block)
            # links and images inside the block still need path rewriting
            joined = re.sub(r'(src|href)="([^"]+)"',
                            lambda m: f'{m.group(1)}="{rewrite_path(m.group(2))}"', joined)
            out.append(joined)
            add_text(joined)
            continue

        if not line.strip():
            i += 1
            continue

        para = [line]
        i += 1
        while i < len(lines) and lines[i].strip() and \
                not re.match(r"^(#{1,4}\s|```|>|\s*\||\s*[-*]\s|\s*\d+\.\s|---+\s*$)", lines[i]):
            para.append(lines[i])
            i += 1
        tag = f"<p>{inline(' '.join(para))}</p>"
        out.append(tag)
        add_text(tag)

    flush()
    return "\n".join(out), toc, sections


CSS = """
:root{
--radius:10px;--radius-sm:6px;--maxw:1320px;
--bg:#fbfbfd;--fg:#1e1c24;--muted:#6b6676;--line:#e3e1e8;--accent:#b06f16;
--card:#fff;--code:#f5f4f8;--k:#a03fa0;--s:#1f7a4d;--c:#8b8797;--t:#0f6f86;--d:#b06f16;--l:#a03fa0;
--wash:#fbf1e3;
--shadow-sm:0 1px 2px rgba(30,20,10,.05);
--shadow:0 2px 8px rgba(30,20,10,.06),0 14px 32px -16px rgba(30,20,10,.20)}
@media (prefers-color-scheme:dark){:root{--bg:#131218;--fg:#dedae2;--muted:#9691a3;
--line:#2a2833;--accent:#e9a658;--card:#1a1922;--code:#1c1b23;--k:#d599e8;--s:#7ec490;
--c:#6b6676;--t:#5fb3b3;--d:#e9a658;--l:#d599e8;--wash:#221b10;
--shadow-sm:0 1px 2px rgba(0,0,0,.4);
--shadow:0 4px 14px rgba(0,0,0,.4),0 22px 44px -20px rgba(0,0,0,.65)}}
:root[data-theme=dark]{--bg:#131218;--fg:#dedae2;--muted:#9691a3;--line:#2a2833;
--accent:#e9a658;--card:#1a1922;--code:#1c1b23;--k:#d599e8;--s:#7ec490;--c:#6b6676;
--t:#5fb3b3;--d:#e9a658;--l:#d599e8;--wash:#221b10;
--shadow-sm:0 1px 2px rgba(0,0,0,.4);
--shadow:0 4px 14px rgba(0,0,0,.4),0 22px 44px -20px rgba(0,0,0,.65)}
:root[data-theme=light]{--bg:#fbfbfd;--fg:#1e1c24;--muted:#6b6676;--line:#e3e1e8;
--accent:#b06f16;--card:#fff;--code:#f5f4f8;--k:#a03fa0;--s:#1f7a4d;--c:#8b8797;
--t:#0f6f86;--d:#b06f16;--l:#a03fa0;--wash:#fbf1e3;
--shadow-sm:0 1px 2px rgba(30,20,10,.05);
--shadow:0 2px 8px rgba(30,20,10,.06),0 14px 32px -16px rgba(30,20,10,.20)}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.65 -apple-system,
BlinkMacSystemFont,"Segoe UI",Inter,Roboto,sans-serif;-webkit-font-smoothing:antialiased;
overflow-x:hidden}
a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}
a:focus-visible,button:focus-visible,input:focus-visible{outline:2px solid var(--accent);
outline-offset:2px;border-radius:3px}
.layout{display:grid;grid-template-columns:260px minmax(0,1fr);gap:0;
max-width:var(--maxw);margin:0 auto}
body.has-rail .layout{grid-template-columns:260px minmax(0,1fr)}
@media(min-width:1200px){body.has-rail .layout{grid-template-columns:260px minmax(0,1fr) 240px}
body.has-rail .rail{display:block}}
nav{position:sticky;top:0;align-self:start;height:100vh;overflow-y:auto;padding:22px 18px;
border-right:1px solid var(--line)}
nav .brand{font-weight:700;font-size:18px;letter-spacing:-.01em;margin-bottom:2px;display:block;color:var(--fg)}
nav .tag{color:var(--muted);font-size:12.5px;margin-bottom:16px}
nav h4{margin:18px 0 6px;font-size:11px;text-transform:uppercase;letter-spacing:.09em;color:var(--muted)}
nav ul{list-style:none;margin:0;padding:0}
nav li a{display:block;padding:5px 9px;margin:1px 0;border-radius:var(--radius-sm);color:var(--fg);font-size:14.5px}
nav li a:hover{background:var(--code);text-decoration:none}
nav li a.active{background:var(--code);color:var(--accent);font-weight:600}
.searchbox{position:relative;margin:2px 0 4px}
.searchbox input{width:100%;box-sizing:border-box;background:var(--card);
border:1px solid var(--line);border-radius:var(--radius-sm);padding:7px 32px 7px 10px;
color:var(--fg);font:13.5px/1.4 inherit}
.searchbox input::placeholder{color:var(--muted)}
.searchbox .searchkey{position:absolute;right:7px;top:6px;pointer-events:none;
font-size:11px;padding:1px 5px}
.searchbox input:focus + .searchkey{display:none}
.searchresults{position:absolute;left:0;right:-4px;top:calc(100% + 6px);z-index:30;
background:var(--card);border:1px solid var(--line);border-radius:var(--radius);
box-shadow:var(--shadow);max-height:min(70vh,520px);overflow-y:auto;padding:6px}
.resultgroup{padding:4px 2px}
.resultgroup + .resultgroup{border-top:1px solid var(--line);margin-top:4px;padding-top:8px}
.resultpage{font-size:10.5px;text-transform:uppercase;letter-spacing:.07em;color:var(--muted);
padding:4px 8px}
a.result{display:block;padding:6px 8px;border-radius:var(--radius-sm);color:var(--fg)}
a.result:hover,a.result.sel{background:var(--code);text-decoration:none}
.resulttitle{display:block;font-size:13.5px;font-weight:600}
.resultsnippet{display:block;font-size:12px;color:var(--muted);margin-top:2px;
overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.noresults{padding:10px 8px;color:var(--muted);font-size:13px}
main{padding:34px 44px 90px;min-width:0}
article{max-width:70ch}
h1,h2,h3,h4{line-height:1.25;letter-spacing:-.015em;scroll-margin-top:20px}
h1{font-size:2.1em;margin:.2em 0 .6em}
h2{font-size:1.42em;margin:1.9em 0 .5em;padding-top:.5em;border-top:1px solid var(--line)}
h3{font-size:1.13em;margin:1.5em 0 .4em}
h4{font-size:.92em;margin:1.2em 0 .3em;color:var(--muted);text-transform:uppercase;letter-spacing:.06em}
.anchor{opacity:0;margin-left:.4em;color:var(--muted);font-weight:400;text-decoration:none}
h1:hover .anchor,h2:hover .anchor,h3:hover .anchor{opacity:.55}
p,li{color:var(--fg)}
kbd{background:var(--card);border:1px solid var(--line);border-bottom-width:2px;
border-radius:5px;padding:.08em .45em;font:12px/1.4 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
color:var(--fg)}
code{background:var(--code);padding:.13em .38em;border-radius:4px;font-size:.87em;
font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
.code{background:var(--code);border:1px solid var(--line);border-radius:var(--radius);
margin:1.2em 0;overflow:hidden;position:relative}
.code pre{margin:0;padding:14px 16px;overflow-x:auto}
.code code{background:none;padding:0;font-size:13.2px;line-height:1.55;display:block}
.codebar{display:flex;align-items:center;gap:8px;padding:6px 10px;
border-bottom:1px solid var(--line);background:var(--card)}
.codelang{font-size:11px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted)}
.copybtn{margin-left:auto;background:var(--card);border:1px solid var(--line);color:var(--muted);
border-radius:var(--radius-sm);padding:3px 9px;font:12px/1.4 -apple-system,BlinkMacSystemFont,
"Segoe UI",sans-serif;cursor:pointer}
.copybtn:hover{color:var(--fg);border-color:var(--muted)}
.copybtn.copied{color:var(--s);border-color:var(--s)}
pre{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
.k{color:var(--k)}.s{color:var(--s)}.c{color:var(--c);font-style:italic}
.t{color:var(--t)}.d{color:var(--d)}.l{color:var(--l)}.n{color:var(--s)}
.tablewrap{overflow-x:auto;margin:1.1em 0}
table{border-collapse:collapse;width:100%;font-size:14.2px}
th,td{border:1px solid var(--line);padding:7px 11px;text-align:left;vertical-align:top}
th{background:var(--code);font-weight:650}
blockquote{margin:1.1em 0;padding:.5em 1em;border-left:3px solid var(--accent);
background:var(--card);color:var(--muted);border-radius:0 var(--radius-sm) var(--radius-sm) 0;
box-shadow:var(--shadow-sm)}
hr{border:0;border-top:1px solid var(--line);margin:2.2em 0}
img{max-width:100%;vertical-align:middle}
p>img:only-child,p>a:only-child>img{display:block;margin:1.1em 0;border-radius:var(--radius)}
td img{border-radius:var(--radius-sm);margin:0}
.navwrap>summary{display:none}
.themetoggle{position:fixed;top:14px;right:18px;background:var(--card);
border:1px solid var(--line);color:var(--muted);border-radius:var(--radius-sm);padding:5px 11px;
cursor:pointer;font-size:12.5px;z-index:10;box-shadow:var(--shadow-sm)}
.themetoggle:hover{color:var(--fg)}
.prevnext{display:flex;gap:14px;margin-top:52px;padding-top:22px;border-top:1px solid var(--line)}
.prevnext a{flex:1 1 0;display:flex;flex-direction:column;gap:4px;padding:13px 16px;
border:1px solid var(--line);border-radius:var(--radius);color:var(--fg);min-width:0}
.prevnext a:hover{border-color:var(--accent);text-decoration:none;box-shadow:var(--shadow-sm)}
.prevnext .next{text-align:right;margin-left:auto}
.pnlabel{font-size:11px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted)}
.pntitle{font-weight:600;font-size:14.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.footer{margin-top:44px;padding-top:18px;border-top:1px solid var(--line);
color:var(--muted);font-size:13px}
.rail{display:none;position:sticky;top:0;align-self:start;height:100vh;overflow-y:auto;
padding:34px 20px 60px 10px}
.railhead{font-size:11px;text-transform:uppercase;letter-spacing:.09em;color:var(--muted);
margin-bottom:10px}
.rail ul{list-style:none;margin:0;padding:0;border-left:1px solid var(--line)}
.rail li{margin:0}
.rail a{display:block;padding:5px 0 5px 14px;margin-left:-1px;border-left:2px solid transparent;
color:var(--muted);font-size:13px;line-height:1.4}
.rail li.lvl3 a{padding-left:26px;font-size:12.5px}
.rail a:hover{color:var(--fg);text-decoration:none}
.rail a.active{color:var(--accent);border-left-color:var(--accent);font-weight:600}
body.landing main{background:linear-gradient(180deg,var(--wash),transparent 360px)}
body.landing article{max-width:940px}
body.landing h1{font-size:2.6em;letter-spacing:-.02em;margin-top:.1em}
body.landing article>p:first-of-type{font-size:1.2em;color:var(--muted);max-width:62ch}
body.landing p>img:only-child{box-shadow:var(--shadow)}
body.landing .tablewrap{margin:1.4em 0}
body.landing .tablewrap table{border-collapse:separate;border-spacing:0 10px}
body.landing .tablewrap thead{position:absolute;width:1px;height:1px;padding:0;margin:-1px;
overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}
body.landing .tablewrap tr{background:var(--card);box-shadow:var(--shadow-sm)}
body.landing .tablewrap tr:hover{box-shadow:var(--shadow)}
body.landing .tablewrap td{border:none;padding:14px 18px;vertical-align:middle;font-size:14.5px}
body.landing .tablewrap td:first-child{border-radius:var(--radius) 0 0 var(--radius);
font-weight:650;white-space:nowrap}
body.landing .tablewrap td:last-child{border-radius:0 var(--radius) var(--radius) 0;
color:var(--muted)}
@media(max-width:1350px){body.landing .tablewrap td:first-child{white-space:normal}}
@media(max-width:900px){.layout{grid-template-columns:1fr}
nav{position:static;height:auto;border-right:0;border-bottom:1px solid var(--line);
padding:16px 18px}
main{padding:22px 18px 60px;overflow-x:hidden}
article{max-width:100%}
body.landing article{max-width:100%}
body.landing h1{font-size:1.9em}
/* Collapse the nav so the page starts at the content, not a full screen of links. */
.navwrap>summary{display:block;cursor:pointer;padding:7px 9px;margin-top:8px;
border:1px solid var(--line);border-radius:var(--radius-sm);color:var(--muted);font-size:13.5px;
list-style:none}
.navwrap>summary::-webkit-details-marker{display:none}
.navwrap>summary::after{content:" ▾";float:right}
.navwrap[open]>summary::after{content:" ▴"}
.themetoggle{position:absolute;top:14px;right:14px}
.brand{font-size:17px}
h1{font-size:1.6em}h2{font-size:1.3em}
.prevnext{flex-direction:column}
.prevnext .next{text-align:left;margin-left:0}
.code code{font-size:12.4px}}
"""

# Shared behaviour for every page: theme toggle, code-block copy buttons, the
# "on this page" active-heading tracking, and the search box. Loaded once as
# docs/site/site.js via <script src>, same directory, so it works offline.
SITE_JS = """(function(){
"use strict";
var root = document.documentElement, THEME_KEY = "otsh-theme";

function currentTheme(){
  return root.getAttribute("data-theme") ||
    (matchMedia("(prefers-color-scheme:dark)").matches ? "dark" : "light");
}

// theme toggle, persisted in localStorage, overriding prefers-color-scheme
var saved = localStorage.getItem(THEME_KEY);
if (saved) root.setAttribute("data-theme", saved);
var toggle = document.createElement("button");
toggle.type = "button";
toggle.className = "themetoggle";
function labelToggle(){
  var next = currentTheme() === "dark" ? "light" : "dark";
  toggle.textContent = next === "dark" ? "Dark" : "Light";
  toggle.setAttribute("aria-label", "Switch to " + next + " theme");
}
toggle.addEventListener("click", function(){
  var next = currentTheme() === "dark" ? "light" : "dark";
  root.setAttribute("data-theme", next);
  localStorage.setItem(THEME_KEY, next);
  labelToggle();
});
labelToggle();
document.body.appendChild(toggle);

// copy-to-clipboard on every code block, with an execCommand fallback for
// browsers/contexts without navigator.clipboard (e.g. non-secure file://)
function fallbackCopy(text){
  var ta = document.createElement("textarea");
  ta.value = text;
  ta.setAttribute("readonly", "");
  ta.style.position = "fixed";
  ta.style.top = "-1000px";
  ta.style.left = "-1000px";
  document.body.appendChild(ta);
  ta.select();
  ta.setSelectionRange(0, text.length);
  try { document.execCommand("copy"); } catch (e) {}
  document.body.removeChild(ta);
}
document.querySelectorAll(".code").forEach(function(block){
  var codeEl = block.querySelector("code");
  if (!codeEl) return;
  var bar = document.createElement("div");
  bar.className = "codebar";
  var langEl = document.createElement("span");
  langEl.className = "codelang";
  langEl.textContent = block.getAttribute("data-lang") || "";
  var btn = document.createElement("button");
  btn.type = "button";
  btn.className = "copybtn";
  btn.textContent = "Copy";
  btn.setAttribute("aria-label", "Copy code to clipboard");
  var resetTimer = null;
  btn.addEventListener("click", function(){
    var text = codeEl.textContent;
    function done(){
      btn.textContent = "Copied";
      btn.classList.add("copied");
      clearTimeout(resetTimer);
      resetTimer = setTimeout(function(){
        btn.textContent = "Copy";
        btn.classList.remove("copied");
      }, 1500);
    }
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done, function(){ fallbackCopy(text); done(); });
    } else {
      fallbackCopy(text);
      done();
    }
  });
  bar.appendChild(langEl);
  bar.appendChild(btn);
  block.insertBefore(bar, block.firstChild);
});

// "on this page" active-heading tracking via IntersectionObserver
var railLinks = document.querySelectorAll(".rail a[href^=\\"#\\"]");
if (railLinks.length && "IntersectionObserver" in window) {
  var map = {};
  railLinks.forEach(function(a){ map[a.getAttribute("href").slice(1)] = a; });
  var active = null;
  var obs = new IntersectionObserver(function(entries){
    entries.forEach(function(entry){
      var link = map[entry.target.id];
      if (!link || !entry.isIntersecting) return;
      if (active) active.classList.remove("active");
      link.classList.add("active");
      active = link;
    });
  }, {rootMargin: "-10% 0px -70% 0px", threshold: 0});
  Object.keys(map).forEach(function(id){
    var el = document.getElementById(id);
    if (el) obs.observe(el);
  });
}

// client-side search over OTSH_SEARCH (search-index.js), substring/prefix
// match over page titles and section headings, grouped by page
var input = document.getElementById("search-input");
var results = document.getElementById("search-results");
if (input && results && window.OTSH_SEARCH) {
  var data = window.OTSH_SEARCH;
  var items = [];
  var selected = -1;

  function esc(s){
    var d = document.createElement("div");
    d.textContent = s == null ? "" : s;
    return d.innerHTML;
  }

  function clearResults(){
    results.innerHTML = "";
    results.hidden = true;
    items = [];
    selected = -1;
  }

  function renderResults(query){
    var q = query.trim().toLowerCase();
    if (!q) { clearResults(); return; }
    var order = [];
    var pages = {};
    for (var i = 0; i < data.length; i++) {
      var e = data[i];
      var hay = (e.h || e.t || "").toLowerCase();
      if (hay.indexOf(q) === -1) continue;
      if (!pages[e.p]) { pages[e.p] = { title: e.t, entries: [] }; order.push(e.p); }
      pages[e.p].entries.push(e);
    }
    if (!order.length) {
      results.innerHTML = '<div class="noresults">No matches</div>';
      results.hidden = false;
      items = [];
      selected = -1;
      return;
    }
    var out = "";
    order.slice(0, 12).forEach(function(p){
      var g = pages[p];
      out += '<div class="resultgroup"><div class="resultpage">' + esc(g.title) + "</div>";
      g.entries.slice(0, 5).forEach(function(e){
        var href = e.p + (e.i ? "#" + e.i : "");
        var label = e.h || e.t;
        out += '<a href="' + href + '" class="result"><span class="resulttitle">' +
          esc(label) + "</span>" +
          (e.s ? '<span class="resultsnippet">' + esc(e.s) + "</span>" : "") +
          "</a>";
      });
      out += "</div>";
    });
    results.innerHTML = out;
    results.hidden = false;
    items = Array.prototype.slice.call(results.querySelectorAll("a.result"));
    selected = -1;
  }

  function markSelected(){
    items.forEach(function(a, i){ a.classList.toggle("sel", i === selected); });
    if (items[selected]) items[selected].scrollIntoView({block: "nearest"});
  }

  input.addEventListener("input", function(){ renderResults(input.value); });
  input.addEventListener("keydown", function(ev){
    if (ev.key === "Escape") {
      input.value = "";
      clearResults();
      input.blur();
    } else if (ev.key === "ArrowDown" && items.length) {
      ev.preventDefault();
      selected = Math.min(selected + 1, items.length - 1);
      markSelected();
    } else if (ev.key === "ArrowUp" && items.length) {
      ev.preventDefault();
      selected = Math.max(selected - 1, 0);
      markSelected();
    } else if (ev.key === "Enter" && selected >= 0 && items[selected]) {
      items[selected].click();
    }
  });
  document.addEventListener("click", function(ev){
    if (ev.target !== input && !results.contains(ev.target)) results.hidden = true;
  });
  document.addEventListener("keydown", function(ev){
    if (ev.key !== "/" || document.activeElement === input) return;
    var tag = (document.activeElement && document.activeElement.tagName) || "";
    if (tag === "INPUT" || tag === "TEXTAREA") return;
    ev.preventDefault();
    input.focus();
    input.select();
  });
}
})();
"""

PAGE = """<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>__TITLE__</title>
<link rel="icon" href="data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 100 100%22><text y=%22.9em%22 font-size=%2290%22>&#9646;</text></svg>">
<style>__CSS__</style></head>
<body class="__BODYCLASS__"><div class="layout">
<nav><a class="brand" href="index.html">otsh</a>
<div class="tag">SSH-served TUIs in Odin</div>
<div class="searchbox" role="search">
<input id="search-input" type="search" placeholder="Search docs" autocomplete="off" aria-label="Search documentation">
<kbd class="searchkey" aria-hidden="true">/</kbd>
<div id="search-results" class="searchresults" hidden></div>
</div>
<details class="navwrap" open><summary>Contents</summary>__NAV__</details>
<script>
(function(){var d=document.currentScript.previousElementSibling;
 if(window.matchMedia('(max-width:900px)').matches)d.removeAttribute('open');})();
</script></nav>
<main><article>__BODY__
__PREVNEXT__
<div class="footer">Generated from <code>docs/*.md</code> by
<code>docs/tools/build_site.py</code>. Screenshots are real captures made with
<code>docs/tools/capture.py</code>.</div>
</article></main>
__RAIL__
</div>
<script src="search-index.js"></script>
<script src="site.js"></script>
</body></html>
"""


def build():
    md_files = sorted(f for f in os.listdir(DOCS) if f.endswith(".md"))
    # README lives one level up; expose it as a virtual "readme.md" page.
    sources = {f: os.path.join(DOCS, f) for f in md_files}
    for path, outname in EXTERNAL.items():
        if os.path.exists(path):
            key = outname[:-5] + ".md"
            md_files.append(key)
            sources[key] = path
    md_files = sorted(set(md_files))
    listed = [f for _, group in NAV for f in group]
    extras = [f for f in md_files if f not in listed]
    nav_sections = [(t, [f for f in g if f in md_files]) for t, g in NAV]
    if extras:
        nav_sections.append(("More", extras))
    # Sidebar order, flattened — what "prev" and "next" walk.
    order = [f for _, files in nav_sections for f in files]

    titles = {}
    for f in md_files:
        with open(sources[f]) as fh:
            for line in fh:
                if line.startswith("# "):
                    titles[f] = line[2:].strip()
                    break
            else:
                titles[f] = f[:-3]

    os.makedirs(OUT, exist_ok=True)
    assets_src = os.path.join(DOCS, "assets")
    if os.path.isdir(assets_src):
        dst = os.path.join(OUT, "assets")
        shutil.rmtree(dst, ignore_errors=True)
        shutil.copytree(assets_src, dst)

    # Repo-root files the README links to.
    for extra in ("LICENSE",):
        src = os.path.join(os.path.dirname(DOCS), extra)
        if os.path.exists(src):
            shutil.copyfile(src, os.path.join(OUT, extra))

    # Example sources, so links to them from the tutorials resolve offline.
    ex_src = os.path.join(os.path.dirname(DOCS), "examples")
    if os.path.isdir(ex_src):
        for root, _, files in os.walk(ex_src):
            for name in files:
                if not name.endswith(".odin"):
                    continue
                rel = os.path.relpath(os.path.join(root, name), os.path.dirname(DOCS))
                dst = os.path.join(OUT, rel + ".txt")
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.copyfile(os.path.join(root, name), dst)

    # Deployment configs, so the ops guide's links to them resolve offline.
    # Same treatment as the example sources above: served as .txt rather than
    # letting a browser try to download a .service or .conf.
    dep_src = os.path.join(os.path.dirname(DOCS), "deploy")
    if os.path.isdir(dep_src):
        for root, _, files in os.walk(dep_src):
            for name in files:
                rel = os.path.relpath(os.path.join(root, name), os.path.dirname(DOCS))
                dst = os.path.join(OUT, rel + ".txt")
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.copyfile(os.path.join(root, name), dst)

    # Render every page once up front: the search index needs every page's
    # sections before any page is written, and the rail needs each page's
    # own outline.
    rendered = {}
    search_entries = []
    for f in md_files:
        with open(sources[f]) as fh:
            body, toc, secs = render(fh.read())
        outname = f[:-3] + ".html"
        for s in secs:
            search_entries.append({
                "p": outname,
                "t": titles[f],
                "h": None if s["level"] <= 1 else s["title"],
                "i": s["id"],
                "s": s["text"],
            })
        rail_items = [(lvl, sid, t) for lvl, sid, t in toc if lvl in (2, 3)]
        rendered[f] = (body, rail_items)

    with open(os.path.join(OUT, "search-index.js"), "w") as fh:
        fh.write("var OTSH_SEARCH = " + json.dumps(search_entries, separators=(",", ":")) + ";\n")
    with open(os.path.join(OUT, "site.js"), "w") as fh:
        fh.write(SITE_JS)

    built = 0
    for f in md_files:
        body, rail_items = rendered[f]
        nav = []
        for section, files in nav_sections:
            if not files:
                continue
            nav.append(f"<h4>{section}</h4><ul>")
            for g in files:
                cls = ' class="active"' if g == f else ""
                label = NAV_TITLES.get(g, titles[g])
                nav.append(f'<li><a href="{g[:-3]}.html"{cls}>{label}</a></li>')
            nav.append("</ul>")

        rail_html = ""
        if rail_items:
            li = "".join(f'<li class="lvl{lvl}"><a href="#{sid}">{t}</a></li>'
                         for lvl, sid, t in rail_items)
            rail_html = f'<aside class="rail"><div class="railhead">On this page</div><ul>{li}</ul></aside>'

        idx = order.index(f)
        links = []
        if idx > 0:
            p = order[idx - 1]
            links.append(f'<a class="prev" href="{p[:-3]}.html"><span class="pnlabel">Previous</span>'
                         f'<span class="pntitle">{NAV_TITLES.get(p, titles[p])}</span></a>')
        if idx < len(order) - 1:
            n = order[idx + 1]
            links.append(f'<a class="next" href="{n[:-3]}.html"><span class="pnlabel">Next</span>'
                         f'<span class="pntitle">{NAV_TITLES.get(n, titles[n])}</span></a>')
        prevnext = ('<div class="prevnext" role="navigation" aria-label="Page navigation">'
                    + "".join(links) + "</div>") if links else ""

        bodyclass = []
        if f == "index.md":
            bodyclass.append("landing")
        if rail_items:
            bodyclass.append("has-rail")

        page = (PAGE
                .replace("__CSS__", CSS)
                .replace("__NAV__", "".join(nav))
                .replace("__BODY__", body)
                .replace("__RAIL__", rail_html)
                .replace("__PREVNEXT__", prevnext)
                .replace("__BODYCLASS__", " ".join(bodyclass))
                .replace("__TITLE__", html.escape(titles[f]) + " — otsh"))
        for marker in ("__CSS__", "__NAV__", "__BODY__", "__RAIL__", "__PREVNEXT__",
                       "__BODYCLASS__", "__TITLE__"):
            assert marker not in page, f"{f}: template placeholder {marker} survived"
        with open(os.path.join(OUT, f[:-3] + ".html"), "w") as fh:
            fh.write(page)
        built += 1
    return built


def check():
    """Validate the generated site. Catches the failure modes this generator has
    actually hit: dead links, missing images, unconverted Markdown, an empty
    sidebar (a <details> that shipped without `open` renders no nav at all),
    a broken or missing search index, pages missing the assets they need, and
    duplicate or dangling heading anchors."""
    problems = []
    pages = sorted(glob.glob(os.path.join(OUT, "*.html")))
    if not pages:
        return ["no pages were generated"]

    search_index = os.path.join(OUT, "search-index.js")
    if not os.path.exists(search_index) or os.path.getsize(search_index) == 0:
        problems.append("search-index.js is missing or empty")
    else:
        raw = open(search_index).read()
        m = re.match(r"^var OTSH_SEARCH = (.*);\s*$", raw, re.S)
        if not m:
            problems.append("search-index.js: expected `var OTSH_SEARCH = [...];`")
        else:
            try:
                data = json.loads(m.group(1))
                if not isinstance(data, list) or not data:
                    problems.append("search-index.js: OTSH_SEARCH is empty")
            except json.JSONDecodeError as e:
                problems.append(f"search-index.js: invalid JSON payload ({e})")

    site_js = os.path.join(OUT, "site.js")
    if not os.path.exists(site_js) or os.path.getsize(site_js) == 0:
        problems.append("site.js is missing or empty")

    for page in pages:
        name = os.path.basename(page)
        doc = open(page).read()

        nav = doc.split("<nav>")[1].split("</nav>")[0] if "<nav>" in doc else ""
        if nav.count("<li>") < 5:
            problems.append(f"{name}: sidebar has {nav.count('<li>')} links, expected >= 5")
        details_tag = re.search(r"<details\b[^>]*>", nav)
        if details_tag and "open" not in details_tag.group(0):
            problems.append(f"{name}: nav <details> is not open; sidebar will render empty")

        if '<script src="search-index.js">' not in doc:
            problems.append(f'{name}: missing <script src="search-index.js">')
        if '<script src="site.js">' not in doc:
            problems.append(f'{name}: missing <script src="site.js">')

        # Anchor ids the generator itself hands out must be unique per page —
        # a repeated heading (e.g. two "Example" sections) would otherwise
        # silently collide and break every #anchor link into that page.
        heading_ids = re.findall(r'<h[1-4] id="([^"]+)"', doc)
        dupes = sorted({i for i in heading_ids if heading_ids.count(i) > 1})
        if dupes:
            problems.append(f"{name}: duplicate heading id(s) {dupes}")

        for m in re.finditer(r'href="([^"#][^"]*?)"', doc):
            target = m.group(1)
            if target.startswith(("http", "data:", "mailto:")):
                continue
            if not os.path.exists(os.path.join(OUT, target.split("#")[0])):
                problems.append(f"{name}: dead link -> {target}")
        for m in re.finditer(r'<img [^>]*src="([^"]+)"', doc):
            src = m.group(1)
            if src.startswith(("http://", "https://", "data:")):
                continue
            if not os.path.exists(os.path.join(OUT, src)):
                problems.append(f"{name}: missing image -> {src}")
        for m in re.finditer(r'<script [^>]*src="([^"]+)"', doc):
            src = m.group(1)
            if src.startswith(("http://", "https://")):
                problems.append(f"{name}: script loaded over the network -> {src}")
            elif not os.path.exists(os.path.join(OUT, src)):
                problems.append(f"{name}: missing script -> {src}")

        body = doc.split("<article>")[1] if "<article>" in doc else doc
        body = re.sub(r'<div class="code"[^>]*>.*?</div>', "", body, flags=re.S)
        # Raw HTML in a source .md is escaped by this renderer, so it surfaces
        # as visible &lt;tag&gt; text. Catch it rather than shipping it.
        for tag in re.findall(r"&lt;(/?[a-z][a-z0-9]*)&gt;", body):
            problems.append(f"{name}: escaped HTML <{tag}> is showing as literal text")
        for pattern, label in ((r"^\s*\|.*\|\s*$", "unconverted table row"),
                               (r"^#{1,4}\s", "unconverted heading"),
                               (r"\]\([^)]*\.md\)", "unconverted .md link"),
                               (r"```", "unclosed code fence")):
            if re.search(pattern, body, re.M):
                problems.append(f"{name}: {label}")
    return sorted(set(problems))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--serve", action="store_true", help="serve after building")
    ap.add_argument("--check", action="store_true", help="validate output, exit 1 on problems")
    ap.add_argument("--port", type=int, default=8000)
    a = ap.parse_args()

    n = build()
    print(f"built {n} pages -> {OUT}")

    problems = check()
    if problems:
        print(f"\n{len(problems)} problem(s):")
        for p in problems:
            print("  " + p)
        if a.check:
            sys.exit(1)
    elif a.check:
        print("check: all links, images, assets, anchors and sidebars resolve")

    if not a.check:
        print(f"open {os.path.join(OUT, 'index.html')}")

    if a.serve:
        import http.server, socketserver, functools
        handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=OUT)
        socketserver.TCPServer.allow_reuse_address = True
        try:
            httpd = socketserver.TCPServer(("", a.port), handler)
        except OSError as e:
            if e.errno != errno.EADDRINUSE:
                raise
            # Almost always a copy of this server already running, which is
            # harmless — say so instead of dumping a traceback.
            print(f"\nport {a.port} is already in use.")
            print(f"  if that is another copy of this server, the site is already at "
                  f"http://localhost:{a.port}/index.html")
            print(f"  otherwise pick a different port:  "
                  f"python3 docs/tools/build_site.py --serve --port {a.port + 1}")
            sys.exit(1)
        with httpd:
            print(f"serving http://localhost:{a.port}/index.html  (ctrl-c to stop)")
            try:
                httpd.serve_forever()
            except KeyboardInterrupt:
                print()


if __name__ == "__main__":
    main()
