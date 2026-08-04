#!/usr/bin/env python3
"""The symbol index behind the site's hover cards and code links.

    python3 docs/tools/gen_symbols.py            # print a summary of the index
    python3 docs/tools/gen_symbols.py --check    # verify docs/site against it

build_site.py imports this module and writes the index as docs/site/symbols.js
(`var OTSH_SYMBOLS = {...}`), the same shape as search-index.js: one shared
file, loaded per page, instead of repeating card markup in every code block.

Accuracy rules, in order of importance:

  * The index is built by gen_api.parse() — the same parser that generates the
    API reference pages — so a hover card can never disagree with the
    reference entry it links to. Nothing here is hand-maintained.

  * Only certainty links. A qualified `tui.draw_box` whose member is an
    exported symbol of that package resolves; a bare `read` never does.
    An identifier this module cannot resolve stays plain text.

  * Standard-library links point at pkg.odin-lang.org only when the symbol is
    verifiably declared in the local Odin distribution's own core/ sources
    (resolved the same way check_examples.py finds the compiler). No Odin
    tree, no stdlib links — a missing link degrades, a wrong one lies.
    Scheme verified against the live site (2026-08): package pages live at
    https://pkg.odin-lang.org/core/<path>/ and every exported symbol has an
    `id="<name>"` anchor, case preserved.

  * --check walks every generated page and verifies every symbol link it
    finds: internal ones must land on an anchor that exists, external ones
    must match the verified pkg.odin-lang.org scheme and a symbol present in
    the local core tree. It also fails if docs/site/symbols.js no longer
    matches what the sources say. Wired into check.sh.

Standard library only, like the rest of docs/tools.
"""
import argparse, glob, json, os, re, sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TOOLS)
import gen_api
import check_examples

ROOT = gen_api.ROOT
DOCS = gen_api.DOCS
SITE = os.path.join(DOCS, "site")

KIND_LABEL = {"Types": "type", "Constants": "const", "Procedures": "proc"}
PKGS = [pkg for pkg, _, _ in gen_api.PACKAGES]


def summary(doc, limit=220):
    """The first paragraph of a doc comment, capped at a word boundary.
    Stops before an indented block or an `Example:` heading — a hover card
    wants the one-line truth, the reference entry has the rest."""
    para = []
    for ln in doc.split("\n"):
        if not ln.strip() or ln.startswith("\t") or ln.strip() == "Example:":
            break
        para.append(ln.strip())
    text = " ".join(para).strip()
    if len(text) <= limit:
        return text
    return text[:limit].rsplit(" ", 1)[0] + "…"


def build_index():
    """One entry per exported symbol, keyed `pkg.name`.

    p: import path        k: kind (type/const/proc)
    s: exact signature    d: first paragraph of the doc comment
    h: reference entry    f: source location (pkg/file.odin:line)
    sf: generated source page for f
    """
    idx = {}
    for pkg, imp, _ in gen_api.PACKAGES:
        for s in gen_api.parse(pkg):
            path, line = s["src"].rsplit(":", 1)
            idx[f"{pkg}.{s['name']}"] = {
                "p": imp,
                "k": KIND_LABEL[s["kind"]],
                "s": s["sig"],
                "d": summary(s["doc"]),
                "h": f"api-{pkg}.html#{gen_api.anchor(s['name'])}",
                "f": s["src"],
                "sf": f"src/{path}.html#L{line}",
            }
    return idx


def names_by_pkg(idx=None):
    idx = idx if idx is not None else build_index()
    out = {pkg: set() for pkg in PKGS}
    for key in idx:
        pkg, name = key.split(".", 1)
        out[pkg].add(name)
    return out


# --- Odin standard library ---------------------------------------------------

def std_packages():
    """Qualifier -> core package path (`utf8` -> `unicode/utf8`), derived from
    the same table check_examples.py uses to auto-import doc blocks, so the
    linker and the compile checker can never disagree about what `fmt.` means."""
    out = {}
    for prefix, imp in check_examples.IMPORTS.items():
        m = re.match(r'import "core:([\w/]+)"', imp)
        if m:
            out[prefix] = m.group(1)
    return out


def odin_core():
    """Path to the local Odin distribution's core/ collection, or None."""
    odin = check_examples.resolve_odin()
    if not odin:
        return None
    core = os.path.join(os.path.dirname(os.path.realpath(odin)), "core")
    return core if os.path.isdir(core) else None


_std_decls = {}

def std_symbol_exists(core, path, name):
    """Is `name` declared, exported, at package level in core/<path>/?

    Column-0 `name :` catches constants, procs, types and variables; a
    tab-indented `name ::` catches foreign-block members and platform
    variants inside `when` blocks. Files under the `#+private` pragma and
    declarations under an `@(private...)` attribute are excluded — they have
    no anchor on pkg.odin-lang.org. Anything this misses simply does not get
    a link — the failure mode is a plain identifier, never a wrong one.
    """
    if path not in _std_decls:
        decls = set()
        for f in glob.glob(os.path.join(core, path, "*.odin")):
            lines = open(f, errors="replace").read().split("\n")
            if any(re.match(r"^(#|//)\+private\b", ln) for ln in lines[:30]):
                continue
            prev = ""
            for ln in lines:
                m = re.match(r"^([A-Za-z_]\w*)\s*:", ln) or \
                    re.match(r"^\t+([A-Za-z_]\w*)\s*::", ln)
                if m and not prev.lstrip().startswith("@(private"):
                    decls.add(m.group(1))
                if ln.strip():
                    prev = ln
        _std_decls[path] = decls
    return name in _std_decls[path]


STD_URL = "https://pkg.odin-lang.org/core/{path}/"


def std_link(core, quals, qual, name):
    """Verified pkg.odin-lang.org deep link for `qual.name`, or None."""
    if core is None or qual not in quals:
        return None
    path = quals[qual]
    if not std_symbol_exists(core, path, name):
        return None
    return STD_URL.format(path=path) + "#" + name


def write_index(site_dir):
    idx = build_index()
    with open(os.path.join(site_dir, "symbols.js"), "w") as fh:
        fh.write("var OTSH_SYMBOLS = " +
                 json.dumps(idx, separators=(",", ":"), sort_keys=True) + ";\n")
    return idx


# --- verification ------------------------------------------------------------

SYM_LINK = re.compile(r'<a class="sym( ext)?"([^>]*)>')
ATTR = re.compile(r'([a-zA-Z-]+)="([^"]*)"')
EXT_OK = re.compile(r"^https://pkg\.odin-lang\.org/core/([\w/]+)/(?:#([A-Za-z_]\w*))?$")


def _page_ids(cache, path):
    if path not in cache:
        cache[path] = set(re.findall(r'id="([^"]+)"', open(path).read()))
    return cache[path]


def check_site(site_dir):
    """Every symbol link on every generated page must resolve.

    Returns (problems, stats). Internal links must land on an id that exists
    in the target page; external ones must match the verified
    pkg.odin-lang.org scheme and name a symbol present in the local Odin
    core tree. This is what makes the hover/link feature safe to ship: a
    link target is either mechanically confirmed or the build fails.
    """
    problems, ids_cache = [], {}
    stats = {"internal": 0, "external": 0, "cards": 0}
    core = odin_core()

    sym_path = os.path.join(site_dir, "symbols.js")
    idx = {}
    if not os.path.exists(sym_path):
        problems.append("symbols.js is missing")
    else:
        m = re.match(r"^var OTSH_SYMBOLS = (.*);\s*$", open(sym_path).read(), re.S)
        if not m:
            problems.append("symbols.js: expected `var OTSH_SYMBOLS = {...};`")
        else:
            try:
                idx = json.loads(m.group(1))
            except json.JSONDecodeError as e:
                problems.append(f"symbols.js: invalid JSON payload ({e})")

    # Every index entry's own targets must exist: the reference anchor the
    # card links to, and the source page (with that line present).
    for key, e in sorted(idx.items()):
        page, _, frag = e["h"].partition("#")
        page_path = os.path.join(site_dir, page)
        if not os.path.exists(page_path):
            problems.append(f"symbols.js: {key} -> missing page {page}")
        elif frag not in _page_ids(ids_cache, page_path):
            problems.append(f"symbols.js: {key} -> no anchor #{frag} in {page}")
        src, _, line = e["sf"].partition("#")
        src_path = os.path.join(site_dir, src)
        if not os.path.exists(src_path):
            problems.append(f"symbols.js: {key} -> missing source page {src}")
        elif line not in _page_ids(ids_cache, src_path):
            problems.append(f"symbols.js: {key} -> no line anchor #{line} in {src}")

    # Every symbol link every page actually emits.
    pages = sorted(glob.glob(os.path.join(site_dir, "*.html")) +
                   glob.glob(os.path.join(site_dir, "src", "*", "*.html")))
    for page in pages:
        rel = os.path.relpath(page, site_dir)
        doc = open(page).read()
        for m in SYM_LINK.finditer(doc):
            ext, attrs = bool(m.group(1)), dict(ATTR.findall(m.group(2)))
            href = attrs.get("href", "")
            if ext:
                stats["external"] += 1
                em = EXT_OK.match(href)
                if not em:
                    problems.append(f"{rel}: external symbol link off-scheme -> {href}")
                    continue
                path, name = em.group(1), em.group(2)
                if core:
                    if not glob.glob(os.path.join(core, path, "*.odin")):
                        problems.append(f"{rel}: link to unknown core package -> {href}")
                    elif name and not std_symbol_exists(core, path, name):
                        problems.append(f"{rel}: core:{path} has no symbol {name} -> {href}")
            else:
                stats["internal"] += 1
                target, _, frag = href.partition("#")
                t_path = page if not target else os.path.join(os.path.dirname(page), target)
                if not os.path.exists(t_path):
                    problems.append(f"{rel}: symbol link to missing page -> {href}")
                elif frag and frag not in _page_ids(ids_cache, t_path):
                    problems.append(f"{rel}: symbol link to missing anchor -> {href}")
                key = attrs.get("data-sym")
                if key:
                    stats["cards"] += 1
                    if key not in idx:
                        problems.append(f"{rel}: data-sym {key} not in symbols.js")
    return problems, stats


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true",
                    help="verify docs/site: index current, every symbol link resolves")
    a = ap.parse_args()

    idx = build_index()
    if not a.check:
        by = names_by_pkg(idx)
        for pkg in PKGS:
            print(f"  {pkg}: {len(by[pkg])} symbols")
        print(f"{len(idx)} symbols total; core tree "
              f"{'found' if odin_core() else 'NOT found (stdlib links disabled)'}")
        return

    problems = []
    sym_path = os.path.join(SITE, "symbols.js")
    if not os.path.exists(sym_path):
        problems.append("docs/site/symbols.js missing — run build_site.py first")
    else:
        m = re.match(r"^var OTSH_SYMBOLS = (.*);\s*$", open(sym_path).read(), re.S)
        if not m or json.loads(m.group(1)) != idx:
            problems.append("docs/site/symbols.js is stale — run build_site.py")

    site_problems, stats = check_site(SITE)
    problems += site_problems
    if problems:
        print(f"{len(problems)} problem(s):")
        for p in sorted(set(problems)):
            print("  " + p)
        sys.exit(1)
    print(f"symbol index current: {len(idx)} symbols; "
          f"{stats['internal']} internal and {stats['external']} external "
          f"symbol links all resolve ({stats['cards']} hover targets)")


if __name__ == "__main__":
    main()
