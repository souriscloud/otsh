#!/usr/bin/env python3
"""Check deploy/fail2ban/filter.d/otsh.conf against the audit line contract.

    python3 deploy/fail2ban/test_filter.py

Standard library only, and no fail2ban installation needed — which is the
point. A log filter that has never been run against real lines is a guess, and
a filter that quietly matches nothing fails silently forever.

What this does:

  * loads the filter with configparser using the same interpolation rules
    fail2ban uses, so a `%` that is not escaped as `%%` fails here rather than
    at reload time;
  * translates the one fail2ban convention the filter uses, `<HOST>`;
  * runs the result against every line of the real capture in
    docs/ssh.md#audit, plus the two failure events that capture does not
    contain, constructed from the field order in ssh/audit.odin;
  * asserts that the extracted host is the line's own `addr=` value, including
    for lines whose client-controlled fields are doing their best to look like
    an address.

What it cannot check, because fail2ban is not installed: that fail2ban's real
`<HOST>` regex behaves like the approximation below, that `datepattern` is
converted to the regex fail2ban expects, and that the jail's systemd backend
hands the filter the line shape assumed here. Those are noted as caveats rather
than claimed as verified. The approximation is deliberately *more* permissive
than any real `<HOST>`: if a host cannot be shifted out of position under a
looser pattern, it cannot be shifted under a tighter one.
"""
import configparser
import os
import re
import sys
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
FILTER = os.path.join(HERE, "filter.d", "otsh.conf")

# Approximation of fail2ban 0.10+/1.x `<HOST>`, which is "an IPv4 address, an
# IPv6 address (optionally bracketed), or a DNS name". Deliberately loose. The
# one property that matters for this filter is the one every version shares:
# it cannot match a space, so it cannot escape the field it is anchored to.
HOST = (
    r"(?P<host>"
    r"(?:\d{1,3}\.){3}\d{1,3}"                       # IPv4 dotted quad
    r"|\[?[0-9A-Fa-f:]*:[0-9A-Fa-f:.]+\]?(?:%[\w.-]+)?"  # IPv6, optional %zone
    r"|[\w\-.^_]*\w"                                 # DNS name
    r")"
)

# The exactly-20-character ts every line carries, per the contract.
TS = "2026-07-29T19:34:21Z"

# --- the corpus --------------------------------------------------------------
#
# (label, line, should_match, expected_host)
#
# Lifted verbatim from the real capture in docs/ssh.md#audit. A connection that
# authenticated with a key and quit after a few seconds: one refused `none`
# attempt, then success.
CAPTURE = [
    ("capture: listen",
     "otsh: audit ts=2026-07-29T19:34:20Z event=listen host=0.0.0.0 port=2229",
     False, None),
    ("capture: accept",
     "otsh: audit ts=2026-07-29T19:34:21Z event=accept addr=127.0.0.1",
     False, None),
    ("capture: auth ok=false (method=none)",
     "otsh: audit ts=2026-07-29T19:34:21Z event=auth addr=127.0.0.1 "
     "method=none user=souris ok=false",
     True, "127.0.0.1"),
    ("capture: auth ok=true",
     "otsh: audit ts=2026-07-29T19:34:21Z event=auth addr=127.0.0.1 "
     "method=publickey user=souris ok=true id=8550aab27bd698618495ca868215c5b7",
     False, None),
    ("capture: session_start",
     "otsh: audit ts=2026-07-29T19:34:21Z event=session_start addr=127.0.0.1 "
     "user=souris term=xterm-ghostty cols=120 rows=40 "
     "id=8550aab27bd698618495ca868215c5b7",
     False, None),
    ("capture: session_end",
     "otsh: audit ts=2026-07-29T19:34:24Z event=session_end addr=127.0.0.1 "
     "secs=3.412 id=8550aab27bd698618495ca868215c5b7",
     False, None),
]

# The capture contains no reject and no kex_fail — a healthy server produces
# neither. These are built from the field order in ssh/audit.odin's contract:
#   reject    addr limit
#   kex_fail  addr
CONTRACT = [
    ("contract: reject per_ip",
     "otsh: audit ts=%s event=reject addr=203.0.113.9 limit=per_ip" % TS,
     True, "203.0.113.9"),
    ("contract: reject sessions",
     "otsh: audit ts=%s event=reject addr=198.51.100.4 limit=sessions" % TS,
     True, "198.51.100.4"),
    ("contract: kex_fail v4",
     "otsh: audit ts=%s event=kex_fail addr=192.0.2.5" % TS,
     True, "192.0.2.5"),
    ("contract: kex_fail v6",
     "otsh: audit ts=%s event=kex_fail addr=2001:db8::dead" % TS,
     True, "2001:db8::dead"),
    ("contract: reject v6",
     "otsh: audit ts=%s event=reject addr=2001:db8::1 limit=per_ip" % TS,
     True, "2001:db8::1"),
    # docs/ssh.md#audit's single-line example of the format.
    ("contract: auth ok=false (docs example)",
     "otsh: audit ts=2026-07-29T12:00:00Z event=auth addr=203.0.113.7 "
     "method=publickey user=git ok=false",
     True, "203.0.113.7"),
    # A key that verified, so the session has an id, but the Authenticator
    # refused it: the optional trailing id is present on a failure line.
    ("contract: auth ok=false with id",
     "otsh: audit ts=%s event=auth addr=203.0.113.7 method=publickey "
     "user=git ok=false id=8550aab27bd698618495ca868215c5b7" % TS,
     True, "203.0.113.7"),
    # Empty values are written as '-', never omitted.
    ("contract: auth ok=false, empty user",
     "otsh: audit ts=%s event=auth addr=203.0.113.7 method=none user=- ok=false" % TS,
     True, "203.0.113.7"),
]

# The same lines as they arrive through a log prefix. fail2ban's systemd
# backend formats each entry as "<host> <ident>[<pid>]: <message>"; a syslog
# file uses a date-first prefix. Both must still match, and must still yield
# the address from `addr=` rather than anything in the prefix.
PREFIXED = [
    ("prefixed: journal (systemd backend)",
     " myhost otsh[1234]: otsh: audit ts=%s event=auth addr=203.0.113.7 "
     "method=none user=souris ok=false" % TS,
     True, "203.0.113.7"),
    ("prefixed: syslog file",
     "Jul 29 19:34:21 myhost otsh[1234]: otsh: audit ts=%s event=kex_fail "
     "addr=203.0.113.9" % TS,
     True, "203.0.113.9"),
    ("prefixed: journal, benign line stays benign",
     " myhost otsh[1234]: otsh: audit ts=%s event=accept addr=203.0.113.7" % TS,
     False, None),
]

# Client-controlled text doing its best to look like an address field. Per the
# scrubbing rules in ssh/audit.odin, every byte outside [A-Za-z0-9.:_@/+,%-]
# becomes '?', so a username can never contain a space or an '=' — these are
# the strongest forgeries the format actually permits.
HOSTILE = [
    ("hostile: user=addr?1.2.3.4",
     "otsh: audit ts=%s event=auth addr=203.0.113.7 method=none "
     "user=addr?1.2.3.4 ok=false" % TS,
     True, "203.0.113.7"),
    ("hostile: user is a bare IP",
     "otsh: audit ts=%s event=auth addr=203.0.113.7 method=none "
     "user=9.9.9.9 ok=false" % TS,
     True, "203.0.113.7"),
    ("hostile: user is a scrubbed fake record (capped at 32 bytes)",
     "otsh: audit ts=%s event=auth addr=203.0.113.7 method=none "
     "user=addr?9.9.9.9?ok?false ok=false" % TS,
     True, "203.0.113.7"),
    ("hostile: user=addr?1.2.3.4 on a benign event stays benign",
     "otsh: audit ts=%s event=session_start addr=203.0.113.7 "
     "user=addr?1.2.3.4 term=xterm cols=80 rows=24" % TS,
     False, None),
    ("hostile: term claims ok?false on a session_start",
     "otsh: audit ts=%s event=session_start addr=203.0.113.7 user=souris "
     "term=ok?false cols=80 rows=24" % TS,
     False, None),
    ("hostile: id-shaped junk in user",
     "otsh: audit ts=%s event=auth addr=2001:db8::7 method=publickey "
     "user=id?deadbeef ok=false" % TS,
     True, "2001:db8::7"),
]

# Not a hostile *input* — an impossible one. This is what a line would look
# like if the scrub in audit_put_field did not exist, and it is here to record
# that the filter's positional guarantee rests on that scrub, not on the regex
# alone. The extracted host shifts to the injected value; the assertion below
# says so out loud.
UNSCRUBBED = (
    "unscrubbed (impossible per contract): user injects a whole second record",
    "otsh: audit ts=%s event=auth addr=203.0.113.7 method=none user=x "
    "otsh: audit ts=%s event=auth addr=9.9.9.9 method=none user=y ok=false"
    % (TS, TS),
    True, "9.9.9.9",
)


def load_filter(path):
    """Read the filter the way fail2ban does, and refuse anything this script
    would have to guess at."""
    raw = open(path).read()
    # fail2ban parses filter files with interpolation enabled, so a literal '%'
    # in a value must be written '%%'. Using the same parser means a mistake
    # there is an error here.
    cp = configparser.ConfigParser(interpolation=configparser.BasicInterpolation())
    cp.read_string(raw)
    d = cp["Definition"]

    failregex = [ln for ln in d.get("failregex", "").split("\n") if ln.strip()]
    ignoreregex = [ln for ln in d.get("ignoreregex", "").split("\n") if ln.strip()]
    datepattern = [ln for ln in d.get("datepattern", "").split("\n") if ln.strip()]

    # Any %(...)s in a value would mean this script and fail2ban are reading
    # two different filters. The filter is written without it. Comments are
    # excluded because configparser drops them before interpolating, and the
    # filter's own prose mentions the syntax it avoids.
    settings = "\n".join(ln for ln in raw.split("\n") if not ln.lstrip().startswith("#"))
    if "%(" in settings:
        sys.exit("this filter uses %(...)s interpolation; the translation "
                 "below is no longer honest")
    if not failregex:
        sys.exit("no failregex found in " + path)

    # Commented alternatives the filter offers, e.g.
    #   # alt-failregex: ^...
    alts = re.findall(r"^#\s*alt-failregex:\s*(.+)$", raw, re.M)
    return failregex, ignoreregex, datepattern, alts


def translate(rx):
    """fail2ban tag -> Python regex. Exactly one tag is in use."""
    tags = set(re.findall(r"<[A-Z_]+>", rx))
    unknown = tags - {"<HOST>"}
    if unknown:
        sys.exit("unhandled fail2ban tag(s) %s — extend translate()"
                 % ", ".join(sorted(unknown)))
    return rx.replace("<HOST>", HOST)


def addr_field(line):
    """The line's own addr= value, parsed independently of the filter."""
    m = re.search(r"(?:^| )addr=(\S+)", line)
    return m.group(1) if m else None


def match(regexes, line):
    """fail2ban tries each failregex with .search(); first hit wins."""
    for i, rx in enumerate(regexes):
        m = rx.search(line)
        if m:
            return i, m.group("host")
    return None, None


def main():
    failregex, ignoreregex, datepattern, alts = load_filter(FILTER)
    compiled = [re.compile(translate(rx)) for rx in failregex]
    alt_compiled = [re.compile(translate(rx)) for rx in alts]

    print("filter:      %s" % os.path.relpath(FILTER, os.path.dirname(HERE)))
    print("failregex:   %d" % len(compiled))
    print("ignoreregex: %d (expected 0)" % len(ignoreregex))
    print("datepattern: %d" % len(datepattern))
    print()

    failures = []

    def check(label, line, want_match, want_host):
        idx, host = match(compiled, line)
        got_match = idx is not None
        ok = got_match == want_match and (not want_match or host == want_host)
        # An extracted host must always be the line's own addr= value.
        if got_match and want_match and want_host is not None:
            declared = addr_field(line)
            if declared is not None and host != declared and want_host == declared:
                ok = False
        verdict = "MATCH#%d host=%s" % (idx, host) if got_match else "no match"
        print("  %-6s %-62s %s" % ("ok" if ok else "FAIL", label, verdict))
        if not ok:
            failures.append(label)

    for title, group in (
        ("a) the documented capture (docs/ssh.md#audit), verbatim", CAPTURE),
        ("b) the two failure events, built from the field-order contract", CONTRACT),
        ("c) the same lines behind a log prefix", PREFIXED),
        ("d) forged client-controlled fields, within the scrubbing rules", HOSTILE),
    ):
        print(title)
        for label, line, want, host in group:
            check(label, line, want, host)
        print()

    print("e) the contract dependency, stated rather than assumed")
    label, line, want, host = UNSCRUBBED
    check(label, line, want, host)
    print("     ^ the scrub in audit_put_field is what keeps this line")
    print("       impossible: a space or an '=' from a client becomes '?'.")
    print()

    # The commented alternative that ignores the `none` method every OpenSSH
    # client tries first.
    print("f) alt-failregex (%d) — same lines, method=none excluded" % len(alt_compiled))
    if alt_compiled:
        for label, line, want in (
            ("alt: method=none is NOT a failure",
             "otsh: audit ts=%s event=auth addr=203.0.113.7 method=none "
             "user=souris ok=false" % TS, False),
            ("alt: method=publickey ok=false still is",
             "otsh: audit ts=%s event=auth addr=203.0.113.7 method=publickey "
             "user=souris ok=false" % TS, True),
        ):
            idx, host = match(alt_compiled, line)
            got = idx is not None
            ok = got == want and (not want or host == "203.0.113.7")
            print("  %-6s %-62s %s" % ("ok" if ok else "FAIL", label,
                                       "MATCH host=%s" % host if got else "no match"))
            if not ok:
                failures.append(label)
    print()

    # datepattern: the strftime half can be checked here; fail2ban's conversion
    # of it into a regex cannot.
    print("g) datepattern")
    for pat in datepattern:
        i = pat.find("%Y")
        fmt = pat[i:] if i >= 0 else pat
        try:
            parsed = datetime.strptime(TS, fmt)
            ok = fmt == "%Y-%m-%dT%H:%M:%SZ" and len(TS) == 20
            print("  %-6s %-62s -> %s" % ("ok" if ok else "FAIL", pat.strip(), parsed))
        except ValueError as e:
            ok = False
            print("  %-6s %-62s -> %s" % ("FAIL", pat.strip(), e))
        if not ok:
            failures.append("datepattern " + pat.strip())
    print()

    total = (len(CAPTURE) + len(CONTRACT) + len(PREFIXED) + len(HOSTILE) + 1
             + (2 if alt_compiled else 0) + len(datepattern))
    if failures:
        print("%d of %d checks FAILED:" % (len(failures), total))
        for f in failures:
            print("  " + f)
        return 1
    print("all %d checks passed" % total)
    print()
    print("not verified here (no fail2ban on this machine):")
    print("  * fail2ban's real <HOST> regex. IPv6 needs fail2ban >= 0.10; on")
    print("    0.9 the v6 lines above match nothing and no ban is issued.")
    print("  * the datepattern -> regex conversion fail2ban performs.")
    print("  * the exact line shape the systemd backend produces.")
    print("  Run `fail2ban-regex <logfile> filter.d/otsh.conf` where fail2ban")
    print("  is installed to close those three.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
