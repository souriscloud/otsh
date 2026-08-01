#!/usr/bin/env python3
"""Verify that the Odin code blocks in the documentation are real.

    python3 docs/tools/check_examples.py            # report
    python3 docs/tools/check_examples.py --check    # exit 1 on any failure
    python3 docs/tools/check_examples.py --strict   # unannotated blocks fail too

This documentation has twice shipped confident fiction, and prose is cheap to
write while verification is not. So every fenced ```odin block in README.md
and docs/*.md carries a machine-checked claim about what kind of real it is,
declared in an HTML comment immediately above the fence (invisible on GitHub
and stripped by build_site.py):

    <!-- check:file -->
        A complete program. Extracted into a scratch package and run through
        `odin check` with the otsh collection mapped, so every import, name
        and type in it is verified against the sources in this repo.

    <!-- check:decls -->
        File-scope declarations without a `package` line (a struct, some
        procs). Wrapped in a scratch package — imports for any otsh:* or
        common core:* prefixes the block uses are added automatically — and
        run through `odin check`.

    <!-- check:verbatim examples/tracker/main.odin -->
        Lifted from the named repo file. Verified by contiguous match against
        that file, insensitive to whitespace and to // comments (a doc may
        annotate a lifted line; it may not change what the code does). If the
        source drifts, the doc fails.

    <!-- check:skip <reason> -->
        Explicitly illustrative: pseudocode, a fragment referencing state that
        exists only in surrounding prose, or deliberately wrong code shown as
        a counter-example. The reason is mandatory — it is the author saying
        "I know this one is not checkable" out loud.

Blocks with no annotation are counted and reported; `--strict` turns them
into failures. Generated pages (docs/api-*.md) are excluded — gen_api.py
already guarantees those against the sources.

Standard library only, like the rest of docs/tools. Needs the Odin compiler
for file/decls blocks; resolved like build.sh does ($ODIN, then .odin-path,
then PATH). Without a compiler those blocks are skipped with a note, so
docs-only environments can still run the verbatim checks.
"""
import argparse, concurrent.futures, glob, os, re, shutil, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DOCS = os.path.join(ROOT, "docs")

DIRECTIVE = re.compile(r"<!--\s*check:(file|decls|verbatim|skip)\s*(.*?)\s*-->\s*$")

# Import lines added to a decls-mode wrapper when the block uses the prefix.
# Over-detection is harmless (unused imports are not an error under
# `odin check` without -vet); under-detection fails loudly at check time.
IMPORTS = {
    "tui":    'import "otsh:tui"',
    "ssh":    'import "otsh:ssh"',
    "sshtui": 'import "otsh:sshtui"',
    "libssh": 'import "otsh:libssh"',
    "fmt":     'import "core:fmt"',
    "os":      'import "core:os"',
    "strings": 'import "core:strings"',
    "time":    'import "core:time"',
    "sync":    'import "core:sync"',
    "thread":  'import "core:thread"',
    "utf8":    'import "core:unicode/utf8"',
    "math":    'import "core:math"',
    "rand":    'import "core:math/rand"',
    "mem":     'import "core:mem"',
    "slice":   'import "core:slice"',
    "strconv": 'import "core:strconv"',
    "log":     'import "core:log"',
    "posix":   'import "core:sys/posix"',
}


def resolve_odin():
    """Same order as build.sh: $ODIN, then .odin-path, then PATH."""
    cand = os.environ.get("ODIN")
    if cand and shutil.which(cand):
        return cand
    path_file = os.path.join(ROOT, ".odin-path")
    if os.path.exists(path_file):
        cand = open(path_file).read().strip()
        if cand and shutil.which(cand):
            return cand
    return shutil.which("odin")


class Block:
    def __init__(self, doc, line, mode, arg, code):
        self.doc, self.line, self.mode, self.arg, self.code = doc, line, mode, arg, code

    def where(self):
        return f"{os.path.relpath(self.doc, ROOT)}:{self.line}"


def extract(path):
    """All ```odin blocks in a Markdown file, with their annotation if any."""
    lines = open(path).read().split("\n")
    blocks, i = [], 0
    while i < len(lines):
        line = lines[i]
        if line.startswith("```"):
            lang = line[3:].strip().split()[0] if line[3:].strip() else ""
            fence_line = i + 1  # 1-based
            i += 1
            body = []
            while i < len(lines) and not lines[i].startswith("```"):
                body.append(lines[i])
                i += 1
            i += 1  # closing fence
            if lang != "odin":
                continue
            # The directive sits above the fence, possibly with blank lines
            # between. Anything else (prose) means "unannotated".
            mode, arg = None, ""
            j = fence_line - 2
            while j >= 0 and not lines[j].strip():
                j -= 1
            if j >= 0:
                m = DIRECTIVE.search(lines[j].strip())
                if m:
                    mode, arg = m.group(1), m.group(2).strip()
            blocks.append(Block(path, fence_line, mode, arg, "\n".join(body)))
        else:
            i += 1
    return blocks


def strip_code(code):
    """Remove comments and string literals so prefix detection does not see
    them. Rough is fine: this only feeds import auto-detection."""
    code = re.sub(r'"(?:\\.|[^"\\])*"', '""', code)
    code = re.sub(r"//[^\n]*", "", code)
    return code


def wrap_decls(code, n):
    bare = strip_code(code)
    imports = []
    for prefix, imp in sorted(IMPORTS.items()):
        if re.search(rf"\b{prefix}\.", bare) and imp not in code:
            imports.append(imp)
    header = f"package doccheck_{n}\n\n" + "\n".join(imports)
    return header + "\n\n" + code + "\n"


def compile_block(block, n, odin, tmp):
    """Returns None on success, else an error string."""
    d = os.path.join(tmp, f"blk_{n}")
    os.makedirs(d, exist_ok=True)
    if block.mode == "file":
        if "package " not in block.code:
            return "check:file block has no `package` line — use check:decls?"
        src = block.code + "\n"
    else:
        src = wrap_decls(block.code, n)
    with open(os.path.join(d, "main.odin"), "w") as fh:
        fh.write(src)
    cmd = [odin, "check", d, f"-collection:otsh={ROOT}"]
    if not re.search(r"\bmain\s*::", src):
        cmd.append("-no-entry-point")
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode == 0:
        return None
    err = (r.stderr or r.stdout).strip()
    return "\n".join(err.split("\n")[:6])


def uncomment(line):
    """Cut a // comment off a line, respecting string literals, so a doc may
    annotate a lifted line (or drop the source's own comment) without failing
    the match. Comments cannot change what the code does."""
    in_str = None
    i = 0
    while i < len(line):
        ch = line[i]
        if in_str:
            if ch == "\\" and in_str == '"':
                i += 2
                continue
            if ch == in_str:
                in_str = None
        elif ch in ('"', "`"):
            in_str = ch
        elif ch == "/" and line[i:i + 2] == "//":
            return line[:i]
        i += 1
    return line


def norm_lines(text):
    """Whitespace- and comment-insensitive view of code: comments cut,
    lines stripped, blank lines dropped."""
    out = []
    for ln in text.split("\n"):
        ln = uncomment(ln).strip()
        if ln:
            out.append(ln)
    return out


def check_verbatim(block):
    if not block.arg:
        return "check:verbatim needs a repo-relative path argument"
    src_path = os.path.join(ROOT, block.arg)
    if not os.path.exists(src_path):
        return f"check:verbatim target does not exist: {block.arg}"
    want = norm_lines(block.code)
    if not want:
        return "check:verbatim block contains no code lines"
    have = norm_lines(open(src_path).read())
    n = len(want)
    for i in range(len(have) - n + 1):
        if have[i:i + n] == want:
            return None
    # Help the author find the drift: report the first line that never appears.
    for ln in want:
        if ln not in have:
            return f"not found in {block.arg}; first missing line:\n  {ln}"
    return f"every line exists in {block.arg} but not contiguously in this order"


def main():
    ap = argparse.ArgumentParser(
        description="Verify the Odin code blocks in README.md and docs/*.md.")
    ap.add_argument("--check", action="store_true", help="exit 1 on any failure")
    ap.add_argument("--strict", action="store_true",
                    help="unannotated blocks are failures too (implies --check)")
    ap.add_argument("--list", action="store_true", help="list every block and its mode")
    a = ap.parse_args()

    docs = [os.path.join(ROOT, "README.md")]
    docs += sorted(p for p in glob.glob(os.path.join(DOCS, "*.md"))
                   if not os.path.basename(p).startswith("api-"))

    blocks = []
    for doc in docs:
        blocks.extend(extract(doc))

    if a.list:
        for b in blocks:
            print(f"  {b.where():44} {b.mode or 'UNANNOTATED'} {b.arg}")
        return

    odin = resolve_odin()
    failures, skipped, unannotated, compiled, verbatim = [], [], [], 0, 0

    compile_jobs = []
    for n, b in enumerate(blocks):
        if b.mode in ("file", "decls"):
            if odin:
                compile_jobs.append((n, b))
            else:
                skipped.append((b, "no odin compiler found"))
        elif b.mode == "verbatim":
            err = check_verbatim(b)
            if err:
                failures.append((b, err))
            else:
                verbatim += 1
        elif b.mode == "skip":
            if not b.arg:
                failures.append((b, "check:skip requires a reason"))
            else:
                skipped.append((b, b.arg))
        else:
            unannotated.append(b)

    if compile_jobs:
        tmp = tempfile.mkdtemp(prefix="otsh_doccheck_")
        try:
            with concurrent.futures.ThreadPoolExecutor(max_workers=4) as ex:
                futs = {ex.submit(compile_block, b, n, odin, tmp): b
                        for n, b in compile_jobs}
                for fut in concurrent.futures.as_completed(futs):
                    b, err = futs[fut], fut.result()
                    if err:
                        failures.append((b, err))
                    else:
                        compiled += 1
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    total = len(blocks)
    print(f"{total} odin blocks in {len(docs)} files: "
          f"{compiled} compiled, {verbatim} verbatim-matched, "
          f"{len(skipped)} skipped, {len(unannotated)} unannotated, "
          f"{len(failures)} failed")
    if unannotated and (a.strict or not a.check):
        for b in unannotated:
            print(f"  unannotated  {b.where()}")
    for b, err in sorted(failures, key=lambda f: f[0].where()):
        print(f"\nFAIL {b.where()} (check:{b.mode or '?'})")
        for ln in err.split("\n"):
            print("  " + ln)

    bad = len(failures) + (len(unannotated) if a.strict else 0)
    if bad and a.strict and unannotated:
        print(f"\n--strict: {len(unannotated)} unannotated block(s) count as failures")
    if (a.check or a.strict) and bad:
        sys.exit(1)


if __name__ == "__main__":
    main()
