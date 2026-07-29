#!/usr/bin/env python3
"""Generate tui/width_table.odin — the Unicode display-width table.

    python3 docs/tools/gen_width.py

The data comes out of Python's own `unicodedata` module, so this needs no
network access and no vendored copy of the UCD. It emits one committed Odin
file of sorted, disjoint, merged rune ranges; `tui.rune_width` binary-searches
them. Only widths other than 1 are in the table — a rune that misses it is
narrow.

Width policy (terminal convention; wcwidth semantics for the cases that occur
in practice):

  * East Asian Width W (Wide) and F (Fullwidth) -> 2.
  * East Asian Width A (Ambiguous) -> 1, i.e. left out of the table. Terminals
    overwhelmingly render ambiguous-width characters narrow, and the U+2500
    box-drawing block that tui's own draw_box borders are made of is ambiguous:
    at width 2 every border in every app would double in size and shift every
    column after it.
  * Zero: combining marks (categories Mn, Me) and format characters (Cf) except
    U+00AD SOFT HYPHEN, which terminals draw as a visible hyphen — wcwidth
    agrees. U+200B..U+200F and the U+FE00..U+FE0F variation selectors are named
    explicitly below; they fall out of Cf/Mn anyway, but the policy names them,
    so the code does too.
  * Everything else -> 1. That includes unassigned code points outside the
    blocks Unicode gives a Wide default to, private use (Ambiguous), and
    surrogates.

Zero beats wide where a character is both (U+302A..U+302D, say: Mn with East
Asian Width W), matching wcwidth. The subtraction happens here so the emitted
ranges are disjoint and the lookup order in rune_width cannot change an answer.

Deliberately NOT wired into check.sh or CI as a `--check` drift gate, unlike
gen_api.py. gen_api.py's output is a function of the repository alone, so every
machine reproduces it byte for byte and a stale page is always a real defect.
This generator's output is a function of the Python that runs it: 3.9 ships
Unicode 13.0.0, 3.11 ships 14.0.0, 3.12 ships 15.0.0. A drift gate would fail
on every contributor whose interpreter differs from the one that last
regenerated the table, reporting a version difference as a defect. Re-run this
by hand when raising the Unicode level, and review the diff.

Standard library only, like the rest of docs/tools.
"""
import os
import sys
import unicodedata

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "tui", "width_table.odin")

MAX_CP = 0x110000

# U+00AD is Cf but is not invisible: terminals draw a hyphen. wcwidth returns 1.
SOFT_HYPHEN = 0x00AD

# Named by the width policy. Both are already Cf/Mn in every Unicode version
# released so far; listing them keeps the emitted table right even if a future
# UCD recategorises one.
EXPLICIT_ZERO = set(range(0x200B, 0x2010)) | set(range(0xFE00, 0xFE10))

# Unassigned code points that Unicode gives a Wide default to, from the
# @missing lines of DerivedEastAsianWidth.txt. They have to be listed because
# unicodedata cannot report them: CPython's east_asian_width() answers "F" for
# every code point with no entry in its table, unassigned ones included, so the
# only safe reading is to skip category Cn entirely and apply the documented
# defaults here. Everything unassigned elsewhere defaults to N or A -> 1.
DEFAULT_WIDE_UNASSIGNED = [
    (0x3400, 0x4DBF),    # CJK Unified Ideographs Extension A
    (0x4E00, 0x9FFF),    # CJK Unified Ideographs
    (0xF900, 0xFAFF),    # CJK Compatibility Ideographs
    (0x20000, 0x2FFFD),  # Plane 2, Supplementary Ideographic
    (0x30000, 0x3FFFD),  # Plane 3, Tertiary Ideographic
]


def width_of(cp):
    """Columns this code point occupies: 0, 1 or 2."""
    ch = chr(cp)
    cat = unicodedata.category(ch)
    if cp in EXPLICIT_ZERO:
        return 0
    if cat in ("Mn", "Me") or (cat == "Cf" and cp != SOFT_HYPHEN):
        return 0
    if cat == "Cn":
        return 2 if any(lo <= cp <= hi for lo, hi in DEFAULT_WIDE_UNASSIGNED) else 1
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1


def build():
    """Sorted, disjoint, merged (lo, hi, width) runs of everything not width 1."""
    ranges = []
    for cp in range(MAX_CP):
        w = width_of(cp)
        if w == 1:
            continue
        if ranges and ranges[-1][2] == w and ranges[-1][1] == cp - 1:
            ranges[-1][1] = cp
        else:
            ranges.append([cp, cp, w])
    return ranges


def label(lo, hi):
    """The first code point's Unicode name, for reviewability of the diff."""
    name = unicodedata.name(chr(lo), "")
    if not name:
        name = "<unassigned>" if unicodedata.category(chr(lo)) == "Cn" else "<unnamed>"
    return name[:52] + (" .." if lo != hi else "")


def render(ranges):
    zero = sum(1 for r in ranges if r[2] == 0)
    wide = len(ranges) - zero
    lo, hi = ranges[0][0], ranges[-1][1]

    L = [
        "// Display widths for every rune that is not one column wide.",
        "//",
        f"// Generated from Unicode {unicodedata.unidata_version} (Python's unicodedata) by",
        "// docs/tools/gen_width.py. Do not edit by hand; regenerate with:",
        "//",
        "//\tpython3 docs/tools/gen_width.py",
        "//",
        "// Sorted, disjoint and merged, so `rune_width` in screen.odin can binary-search",
        "// it. A rune that misses the table is one column wide, which is why only two",
        "// widths appear here. East Asian Width A (ambiguous) is deliberately absent —",
        "// see the policy note on `rune_width`. No drift check gates this file: the",
        "// Unicode version follows whichever Python generated it, so the generator's",
        "// docstring, not CI, is the record of how to refresh it.",
        "package tui",
        "",
        "// One run of code points sharing a display width.",
        "@(private)",
        "Width_Range :: struct {",
        "\tlo, hi: rune,",
        "\tw:      u8,",
        "}",
        "",
        "// The bounds of WIDTH_RANGES. Outside them every rune is one column, so",
        "// `rune_width` answers without searching.",
        "@(private)",
        f"WIDTH_TABLE_LO :: rune(0x{lo:04x})",
        "@(private)",
        f"WIDTH_TABLE_HI :: rune(0x{hi:04x})",
        "",
        f"// {len(ranges)} ranges: {zero} zero-width (Mn, Me, Cf), {wide} double-width (East Asian",
        "// Width W and F). The trailing comment on each is the name of its first code",
        "// point, so a regenerated table diffs readably.",
        "@(private, rodata)",
        "WIDTH_RANGES := [?]Width_Range{",
    ]
    for lo_, hi_, w in ranges:
        L.append(f"\t{{0x{lo_:04x}, 0x{hi_:04x}, {w}}}, // {label(lo_, hi_)}")
    L += ["}", ""]
    return "\n".join(L)


def main():
    if len(sys.argv) > 1:
        print(__doc__)
        sys.exit(2)

    ranges = build()

    # The invariants rune_width's binary search depends on. Cheap to assert,
    # and a silent violation would be a corrupted line in every frame.
    prev_hi, prev_w = -2, -1
    for lo, hi, w in ranges:
        assert lo <= hi, f"inverted range {lo:04x}..{hi:04x}"
        assert lo > prev_hi, f"unsorted or overlapping range at {lo:04x}"
        assert lo > prev_hi + 1 or w != prev_w, f"unmerged range at {lo:04x}"
        assert w in (0, 2), f"width {w} does not belong in the table"
        prev_hi, prev_w = hi, w

    text = render(ranges)
    with open(OUT, "w") as f:
        f.write(text)

    covered = sum(hi - lo + 1 for lo, hi, _ in ranges)
    print(f"  {os.path.relpath(OUT, ROOT)}  {len(ranges)} ranges, "
          f"{covered} code points, Unicode {unicodedata.unidata_version}")


if __name__ == "__main__":
    main()
