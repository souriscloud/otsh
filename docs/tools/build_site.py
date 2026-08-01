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
"""
import argparse, errno, glob, html, os, re, shutil, sys

DOCS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(DOCS, "site")

# Order of the sidebar. Anything not listed is appended alphabetically.
# Sources outside docs/ that are pulled into the site, mapped to output names.
EXTERNAL = {os.path.join(os.path.dirname(DOCS), "README.md"): "readme.html"}

# Sidebar labels. Page titles are full sentences, which wrap badly in a narrow
# column, so the nav gets its own short names.
NAV_TITLES = {
    "index.md": "Overview",
    "readme.md": "README",
    "getting-started.md": "Getting started",
    "tutorial-tui.md": "Stopwatch (local)",
    "tutorial-guestbook.md": "Guestbook (SSH)",
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
    "compatibility.md": "Compatibility",
    "deploy.md": "Deployment",
}

NAV = [
    ("Start", ["index.md", "readme.md", "getting-started.md"]),
    ("Tutorials", ["tutorial-tui.md", "tutorial-guestbook.md"]),
    ("Guides", ["cookbook.md", "tui.md", "ssh.md", "sshtui.md"]),
    ("API reference", ["api-tui.md", "api-ssh.md", "api-sshtui.md", "api-libssh.md"]),
    ("Understanding", ["security.md", "architecture.md"]),
    ("Operations", ["deploy.md", "compatibility.md"]),
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
        if False:
            rel = href[href.index("examples/"):] if "examples/" in href else href
            return f'<a href="{rel}.txt">{label}</a>' if rel.endswith(".odin") \
                else f'<a href="{rel}">{label}</a>'
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
    """Markdown -> (html, [(level, id, title)]) for the page outline."""
    md = re.sub(r"<!--.*?-->", "", md, flags=re.S)  # comments are not content
    lines = md.split("\n")
    out, toc, i = [], [], 0
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
            tag = f'<div class="code"><pre><code>{code}</code></pre></div>'
            out.append(tag)
            continue

        m = re.match(r"^(#{1,4})\s+(.*)$", line)
        if m:
            lvl, title = len(m.group(1)), inline(m.group(2))
            sid = slug(m.group(2))
            if lvl <= 3:
                toc.append((lvl, sid, re.sub(r"<[^>]+>", "", title)))
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
            out.append("".join(t))
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
            out.append(f"<blockquote>{inline(' '.join(body))}</blockquote>")
            continue

        m = re.match(r"^(\s*)([-*]|\d+\.)\s+(.*)$", line)
        if m:
            ordered = bool(re.match(r"\d+\.", m.group(2)))
            tag = "ol" if ordered else "ul"
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
            out.append(f"<{tag}>" + "".join(f"<li>{x}</li>" for x in items) + f"</{tag}>")
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
        out.append(f"<p>{inline(' '.join(para))}</p>")

    return "\n".join(out), toc


CSS = """
:root{--bg:#fbfbfd;--fg:#1e1c24;--muted:#6b6676;--line:#e3e1e8;--accent:#b06f16;
--card:#fff;--code:#f5f4f8;--k:#a03fa0;--s:#1f7a4d;--c:#8b8797;--t:#0f6f86;--d:#b06f16;--l:#a03fa0}
@media (prefers-color-scheme:dark){:root{--bg:#131218;--fg:#dedae2;--muted:#9691a3;
--line:#2a2833;--accent:#e9a658;--card:#1a1922;--code:#1c1b23;--k:#d599e8;--s:#7ec490;
--c:#6b6676;--t:#5fb3b3;--d:#e9a658;--l:#d599e8}}
:root[data-theme=dark]{--bg:#131218;--fg:#dedae2;--muted:#9691a3;--line:#2a2833;
--accent:#e9a658;--card:#1a1922;--code:#1c1b23;--k:#d599e8;--s:#7ec490;--c:#6b6676;
--t:#5fb3b3;--d:#e9a658;--l:#d599e8}
:root[data-theme=light]{--bg:#fbfbfd;--fg:#1e1c24;--muted:#6b6676;--line:#e3e1e8;
--accent:#b06f16;--card:#fff;--code:#f5f4f8;--k:#a03fa0;--s:#1f7a4d;--c:#8b8797;
--t:#0f6f86;--d:#b06f16;--l:#a03fa0}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.65 -apple-system,
BlinkMacSystemFont,"Segoe UI",Inter,Roboto,sans-serif;-webkit-font-smoothing:antialiased}
a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}
.layout{display:grid;grid-template-columns:250px minmax(0,1fr);gap:0;max-width:1240px;margin:0 auto}
nav{position:sticky;top:0;align-self:start;height:100vh;overflow-y:auto;padding:22px 18px;
border-right:1px solid var(--line)}
nav .brand{font-weight:700;font-size:18px;letter-spacing:-.01em;margin-bottom:2px;display:block;color:var(--fg)}
nav .tag{color:var(--muted);font-size:12.5px;margin-bottom:18px}
nav h4{margin:18px 0 6px;font-size:11px;text-transform:uppercase;letter-spacing:.09em;color:var(--muted)}
nav ul{list-style:none;margin:0;padding:0}
nav li a{display:block;padding:5px 9px;margin:1px 0;border-radius:6px;color:var(--fg);font-size:14.5px}
nav li a:hover{background:var(--code);text-decoration:none}
nav li a.active{background:var(--code);color:var(--accent);font-weight:600}
main{padding:34px 44px 90px;min-width:0}
article{max-width:820px}
h1,h2,h3,h4{line-height:1.25;letter-spacing:-.015em;scroll-margin-top:20px}
h1{font-size:2em;margin:.2em 0 .6em}
h2{font-size:1.42em;margin:1.9em 0 .5em;padding-top:.5em;border-top:1px solid var(--line)}
h3{font-size:1.13em;margin:1.5em 0 .4em}
h4{font-size:1em;margin:1.2em 0 .3em;color:var(--muted)}
.anchor{opacity:0;margin-left:.4em;color:var(--muted);font-weight:400;text-decoration:none}
h1:hover .anchor,h2:hover .anchor,h3:hover .anchor{opacity:.55}
p,li{color:var(--fg)}
code{background:var(--code);padding:.13em .38em;border-radius:4px;font-size:.87em;
font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
.code{background:var(--code);border:1px solid var(--line);border-radius:9px;
margin:1.1em 0;overflow-x:auto}
.code pre{margin:0;padding:14px 16px}
.code code{background:none;padding:0;font-size:13.2px;line-height:1.55;display:block}
pre{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
.k{color:var(--k)}.s{color:var(--s)}.c{color:var(--c);font-style:italic}
.t{color:var(--t)}.d{color:var(--d)}.l{color:var(--l)}.n{color:var(--s)}
.tablewrap{overflow-x:auto;margin:1.1em 0}
table{border-collapse:collapse;width:100%;font-size:14.2px}
th,td{border:1px solid var(--line);padding:7px 11px;text-align:left;vertical-align:top}
th{background:var(--code);font-weight:650}
blockquote{margin:1.1em 0;padding:.5em 1em;border-left:3px solid var(--accent);
background:var(--card);color:var(--muted);border-radius:0 6px 6px 0}
hr{border:0;border-top:1px solid var(--line);margin:2.2em 0}
img{max-width:100%;vertical-align:middle}
p>img:only-child,p>a:only-child>img{display:block;margin:1.1em 0;border-radius:9px}
td img{border-radius:7px;margin:0}
.navwrap>summary{display:none}
.themetoggle{position:fixed;top:14px;right:18px;background:var(--card);
border:1px solid var(--line);color:var(--muted);border-radius:7px;padding:5px 11px;
cursor:pointer;font-size:12.5px;z-index:10}
.footer{margin-top:60px;padding-top:18px;border-top:1px solid var(--line);
color:var(--muted);font-size:13px}
@media(max-width:900px){.layout{grid-template-columns:1fr}
nav{position:static;height:auto;border-right:0;border-bottom:1px solid var(--line);
padding:16px 18px}
main{padding:22px 18px 60px;overflow-x:hidden}
article{max-width:100%}
/* Collapse the nav so the page starts at the content, not a full screen of links. */
.navwrap>summary{display:block;cursor:pointer;padding:7px 9px;margin-top:8px;
border:1px solid var(--line);border-radius:7px;color:var(--muted);font-size:13.5px;
list-style:none}
.navwrap>summary::-webkit-details-marker{display:none}
.navwrap>summary::after{content:" ▾";float:right}
.navwrap[open]>summary::after{content:" ▴"}
.themetoggle{position:absolute;top:14px;right:14px}
.brand{font-size:17px}
h1{font-size:1.6em}h2{font-size:1.3em}
.code code{font-size:12.4px}}
"""

JS = """
(function(){
 var r=document.documentElement,k='otsh-theme',s=localStorage.getItem(k);
 if(s)r.setAttribute('data-theme',s);
 var b=document.createElement('button');b.className='themetoggle';
 function lbl(){var d=r.getAttribute('data-theme')||
   (matchMedia('(prefers-color-scheme:dark)').matches?'dark':'light');
   b.textContent=d==='dark'?'light':'dark';}
 b.onclick=function(){var d=r.getAttribute('data-theme')||
   (matchMedia('(prefers-color-scheme:dark)').matches?'dark':'light');
   var n=d==='dark'?'light':'dark';r.setAttribute('data-theme',n);
   localStorage.setItem(k,n);lbl();};
 lbl();document.body.appendChild(b);
})();
"""

PAGE = """<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>__TITLE__</title>
<link rel="icon" href="data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 100 100%22><text y=%22.9em%22 font-size=%2290%22>&#9646;</text></svg>">
<style>__CSS__</style></head>
<body><div class="layout">
<nav><a class="brand" href="index.html">otsh</a>
<div class="tag">SSH-served TUIs in Odin</div>
<details class="navwrap" open><summary>Contents</summary>__NAV__</details>
<script>
(function(){var d=document.currentScript.previousElementSibling;
 if(window.matchMedia('(max-width:900px)').matches)d.removeAttribute('open');})();
</script></nav>
<main><article>__BODY__
<div class="footer">Generated from <code>docs/*.md</code> by
<code>docs/tools/build_site.py</code>. Screenshots are real captures made with
<code>docs/tools/capture.py</code>.</div>
</article></main></div>
<script>__JS__</script></body></html>
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
    sections = [(t, [f for f in g if f in md_files]) for t, g in NAV]
    if extras:
        sections.append(("More", extras))

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

    built = 0
    for f in md_files:
        with open(sources[f]) as fh:
            body, _ = render(fh.read())
        nav = []
        for section, files in sections:
            if not files:
                continue
            nav.append(f"<h4>{section}</h4><ul>")
            for g in files:
                cls = ' class="active"' if g == f else ""
                label = NAV_TITLES.get(g, titles[g])
                nav.append(f'<li><a href="{g[:-3]}.html"{cls}>{label}</a></li>')
            nav.append("</ul>")
        page = (PAGE
                .replace("__CSS__", CSS)
                .replace("__JS__", JS)
                .replace("__NAV__", "".join(nav))
                .replace("__BODY__", body)
                .replace("__TITLE__", html.escape(titles[f]) + " — otsh"))
        for marker in ("__CSS__", "__JS__", "__NAV__", "__BODY__", "__TITLE__"):
            assert marker not in page, f"{f}: template placeholder {marker} survived"
        with open(os.path.join(OUT, f[:-3] + ".html"), "w") as fh:
            fh.write(page)
        built += 1
    return built


def check():
    """Validate the generated site. Catches the failure modes this generator has
    actually hit: dead links, missing images, unconverted Markdown, and an empty
    sidebar (a <details> that shipped without `open` renders no nav at all)."""
    problems = []
    pages = sorted(glob.glob(os.path.join(OUT, "*.html")))
    if not pages:
        return ["no pages were generated"]

    for page in pages:
        name = os.path.basename(page)
        doc = open(page).read()

        nav = doc.split("<nav>")[1].split("</nav>")[0] if "<nav>" in doc else ""
        if nav.count("<li>") < 5:
            problems.append(f"{name}: sidebar has {nav.count('<li>')} links, expected >= 5")
        if "<details" in nav and "open" not in nav.split(">")[0] + nav[:200]:
            problems.append(f"{name}: nav <details> is not open; sidebar will render empty")

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

        body = doc.split("<article>")[1] if "<article>" in doc else doc
        body = re.sub(r'<div class="code">.*?</div>', "", body, flags=re.S)
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
        print("check: all links, images and sidebars resolve")

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
