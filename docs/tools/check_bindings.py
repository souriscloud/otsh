#!/usr/bin/env python3
"""Compare libssh/libssh.odin against the libssh headers actually installed here.

    python3 docs/tools/check_bindings.py            # full report, always exits 0
    python3 docs/tools/check_bindings.py --check    # only problems; exit 1 if any

The bindings mirror C declarations by hand. Nothing in the Odin compiler knows
that, so a mirror that has drifted still compiles, still links, and still runs —
it just calls the wrong function, or reads a field libssh never wrote. This file
is the only thing in the repository that can notice.

What it compares, and why each one can fail silently at runtime:

  struct layout   `Server_Callbacks` and `Channel_Callbacks` against
                  `struct ssh_server_callbacks_struct` / `ssh_channel_callbacks_struct`
                  in callbacks.h — field count and field order. libssh indexes
                  these by C offset, so a swapped pair wires one callback to
                  another event with no diagnostic anywhere.

  callback shape  Each `#type proc "c"` against the C typedef it stands for:
                  parameter count and whether the return is void. A missing
                  parameter is stack corruption on some ABIs and a garbage
                  argument on the rest.

  enums           `Bind_Option`, `Session_Option`, `Keytype`, `Auth`,
                  `Pubkey_Hash_Type`, `Pubkey_State` against the C enums, by
                  *value*, so an enumerator inserted in the middle upstream is
                  caught. Extra trailing C enumerators are reported as news, not
                  as failure — appending is the one change that is safe.

  constants       `OK`/`ERROR`/`AGAIN`/`EOF` and the `AUTH_METHOD_*` bitmask
                  against the `#define`s.

  symbols         Every `@(link_name = ...)` against the exported symbols of the
                  installed shared library (nm), falling back to a header scan
                  where nm is unavailable. This is the check that catches a
                  binding to a function that is declared but not defined.

  portability     Symbols libssh declares on every platform but only *defines*
                  on some. `ssh_threads_get_pthread` is the known one: it lives
                  in src/threads/pthread.c, which src/CMakeLists.txt compiles
                  only under CMAKE_USE_PTHREADS_INIT, so a Windows libssh
                  exports no such symbol and the link fails with LNK2019. nm on
                  a unix box cannot see that; this list can.

  pinned facts    Two type-mapping decisions that depend on how libssh spells
                  something: `socket_t` (int vs SOCKET) and the `char` in
                  `ssh_auth_pubkey_callback`, which is why `Pubkey_State` is a
                  signed enum. If either spelling changes upstream, the Odin
                  side needs revisiting.

Headers are found via pkg-config, then the usual install prefixes. When they are
not installed the tool prints why and exits 0 — a machine without libssh headers
is not a broken repository. Standard library only, like the rest of docs/tools.

See docs/bindings.md for what to do about anything reported here.
"""
import argparse, os, re, shutil, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ODIN_BINDINGS = os.path.join(ROOT, "libssh", "libssh.odin")

# --- what is mirrored -------------------------------------------------------

# (Odin struct, C struct, header)
STRUCTS = [
    ("Server_Callbacks", "ssh_server_callbacks_struct", "callbacks.h"),
    ("Channel_Callbacks", "ssh_channel_callbacks_struct", "callbacks.h"),
]

# (Odin proc type, C function-pointer typedef, header)
CALLBACKS = [
    ("Auth_None_Proc", "ssh_auth_none_callback", "callbacks.h"),
    ("Auth_Password_Proc", "ssh_auth_password_callback", "callbacks.h"),
    ("Auth_Pubkey_Proc", "ssh_auth_pubkey_callback", "callbacks.h"),
    ("Channel_Open_Session_Proc", "ssh_channel_open_request_session_callback", "callbacks.h"),
    ("Channel_Data_Proc", "ssh_channel_data_callback", "callbacks.h"),
    ("Channel_Eof_Proc", "ssh_channel_eof_callback", "callbacks.h"),
    ("Channel_Close_Proc", "ssh_channel_close_callback", "callbacks.h"),
    ("Channel_Pty_Proc", "ssh_channel_pty_request_callback", "callbacks.h"),
    ("Channel_Shell_Proc", "ssh_channel_shell_request_callback", "callbacks.h"),
    ("Channel_Window_Change_Proc", "ssh_channel_pty_window_change_callback", "callbacks.h"),
    ("Channel_Env_Proc", "ssh_channel_env_request_callback", "callbacks.h"),
    ("Channel_Exec_Proc", "ssh_channel_exec_request_callback", "callbacks.h"),
]

# (Odin enum, C enum, C enumerator prefix, header). The Odin member name upper-
# cased and prefixed gives the C enumerator: Bindport_Str -> BINDPORT_STR.
ENUMS = [
    ("Bind_Option", "ssh_bind_options_e", "SSH_BIND_OPTIONS_", "server.h"),
    ("Session_Option", "ssh_options_e", "SSH_OPTIONS_", "libssh.h"),
    ("Keytype", "ssh_keytypes_e", "SSH_KEYTYPE_", "libssh.h"),
    ("Auth", "ssh_auth_e", "SSH_AUTH_", "libssh.h"),
    ("Pubkey_Hash_Type", "ssh_publickey_hash_type", "SSH_PUBLICKEY_HASH_", "libssh.h"),
    ("Pubkey_State", "ssh_publickey_state_e", "SSH_PUBLICKEY_STATE_", "libssh.h"),
]

# (Odin constant, C macro, header)
CONSTANTS = [
    ("OK", "SSH_OK", "libssh.h"),
    ("ERROR", "SSH_ERROR", "libssh.h"),
    ("AGAIN", "SSH_AGAIN", "libssh.h"),
    ("EOF", "SSH_EOF", "libssh.h"),
    ("AUTH_METHOD_UNKNOWN", "SSH_AUTH_METHOD_UNKNOWN", "libssh.h"),
    ("AUTH_METHOD_NONE", "SSH_AUTH_METHOD_NONE", "libssh.h"),
    ("AUTH_METHOD_PASSWORD", "SSH_AUTH_METHOD_PASSWORD", "libssh.h"),
    ("AUTH_METHOD_PUBLICKEY", "SSH_AUTH_METHOD_PUBLICKEY", "libssh.h"),
    ("AUTH_METHOD_HOSTBASED", "SSH_AUTH_METHOD_HOSTBASED", "libssh.h"),
    ("AUTH_METHOD_INTERACTIVE", "SSH_AUTH_METHOD_INTERACTIVE", "libssh.h"),
]

# Declared in a header on every platform, defined only on some. nm on the local
# machine cannot see a symbol that is missing somewhere else, so the fact is
# recorded here instead. Each entry: symbol -> (where it is defined, why it is
# not everywhere).
CONDITIONAL_SYMBOLS = {
    "ssh_threads_get_pthread": (
        "src/threads/pthread.c",
        "src/CMakeLists.txt compiles it only under CMAKE_USE_PTHREADS_INIT; a "
        "Windows build gets threads/winlocks.c instead, so the symbol does not "
        "exist there and the link fails with LNK2019. Bind ssh_threads_get_default.",
    ),
}

# Spellings the Odin side is built on. Text that must still be in the header.
PINNED = [
    ("libssh.h", "typedef SOCKET socket_t;",
     "Socket is uintptr on Windows because socket_t is a SOCKET (UINT_PTR) there"),
    ("libssh.h", "typedef int socket_t;",
     "Socket is c.int elsewhere because socket_t is a plain fd"),
    ("callbacks.h", "char signature_state",
     "Pubkey_State is spelled `enum i8` because this parameter is a plain char, "
     "which is unsigned on some platforms while SSH_PUBLICKEY_STATE_ERROR is -1"),
]

HEADERS = ["libssh.h", "callbacks.h", "server.h", "libssh_version.h"]


# --- locating libssh --------------------------------------------------------

def pkg_config(*args):
    if not shutil.which("pkg-config"):
        return None
    try:
        r = subprocess.run(["pkg-config", *args, "libssh"],
                           capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout.strip() if r.returncode == 0 else None


def has_headers(d):
    return bool(d) and all(os.path.isfile(os.path.join(d, "libssh", h)) for h in HEADERS)


def find_headers(override=None):
    """Directory D such that D/libssh/callbacks.h exists.

    An explicit --headers is used as given: if it is wrong the caller wants to
    know, not to be quietly checked against some other libssh.
    """
    if override:
        return override if has_headers(override) else None
    cands = []
    if os.environ.get("LIBSSH_INCLUDE_DIR"):
        cands.append(os.environ["LIBSSH_INCLUDE_DIR"])
    cflags = pkg_config("--cflags")
    if cflags:
        cands += [tok[2:] for tok in cflags.split() if tok.startswith("-I")]
    cands += [
        "/opt/homebrew/opt/libssh/include",   # Homebrew, Apple silicon
        "/usr/local/opt/libssh/include",      # Homebrew, Intel
        "/opt/homebrew/include",
        "/usr/local/include",
        "/usr/include",
        "/opt/local/include",                 # MacPorts
    ]
    for d in cands:
        if has_headers(d):
            return d
    return None


def find_library(override=None):
    names = ["libssh.dylib", "libssh.so", "libssh.so.4", "ssh.lib", "libssh.a"]
    cands = []
    if override:
        return override if os.path.isfile(override) else None
    if os.environ.get("LIBSSH_LIB"):
        cands.append(os.environ["LIBSSH_LIB"])
    dirs = []
    libs = pkg_config("--libs")
    if libs:
        dirs += [tok[2:] for tok in libs.split() if tok.startswith("-L")]
    dirs += [
        "/opt/homebrew/opt/libssh/lib", "/usr/local/opt/libssh/lib",
        "/opt/homebrew/lib", "/usr/local/lib", "/usr/lib",
        "/usr/lib/x86_64-linux-gnu", "/usr/lib/aarch64-linux-gnu",
        "/opt/local/lib",
    ]
    for d in dirs:
        for n in names:
            cands.append(os.path.join(d, n))
    for p in cands:
        if p and os.path.isfile(p):
            return p
    return None


def library_symbols(path):
    """Exported symbol names, or None if no usable symbol reader is available."""
    if not path:
        return None
    attempts = [
        ["nm", "-gU", path],                # Mach-O: defined external
        ["nm", "-D", "--defined-only", path],  # ELF dynamic
        ["nm", "--defined-only", path],
    ]
    if shutil.which("dumpbin"):             # MSVC toolchain
        attempts.insert(0, ["dumpbin", "/EXPORTS", path])
    for cmd in attempts:
        if not shutil.which(cmd[0]):
            continue
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        except (OSError, subprocess.SubprocessError):
            continue
        if r.returncode != 0:
            continue
        syms = set()
        for line in r.stdout.splitlines():
            for tok in line.split():
                # Mach-O prefixes an underscore; ELF appends @@VERSION when the
                # library uses symbol versioning, which libssh does.
                tok = tok.lstrip("_").split("@", 1)[0]
                if tok.startswith("ssh_"):
                    syms.add(tok)
        # Sanity: a reader that found nothing recognisable did not work.
        if "ssh_init" in syms:
            return syms
    return None


def header_declared(headers_text):
    """Every identifier declared with LIBSSH_API, as the no-nm fallback."""
    out = set()
    for name, text in headers_text.items():
        for m in re.finditer(r"LIBSSH_API\b(.*?)\(", strip_c_comments(text), re.S):
            ids = re.findall(r"[A-Za-z_]\w*", m.group(1))
            if ids:
                out.add(ids[-1])
    return out


# --- C parsing --------------------------------------------------------------

def strip_c_comments(text):
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return re.sub(r"//[^\n]*", " ", text)


def balanced(text, start, open_ch, close_ch):
    """Body between the delimiters, given the index of the opening one."""
    depth, i = 0, start
    while i < len(text):
        if text[i] == open_ch:
            depth += 1
        elif text[i] == close_ch:
            depth -= 1
            if depth == 0:
                return text[start + 1:i]
        i += 1
    return None


def c_struct_fields(text, name):
    """Declared field names of `struct name`, in order. None if not found."""
    m = re.search(r"\bstruct\s+" + re.escape(name) + r"\s*\{", text)
    if not m:
        return None
    body = balanced(text, m.end() - 1, "{", "}")
    if body is None:
        return None
    fields = []
    for decl in body.split(";"):
        decl = decl.strip()
        if not decl:
            continue
        decl = re.sub(r"\[[^\]]*\]", "", decl)          # drop array suffixes
        ids = re.findall(r"[A-Za-z_]\w*", decl)
        if ids:
            fields.append(ids[-1])
    return fields


def c_enum_members(text, name):
    """[(enumerator, value)] for `enum name`, in order. None if not found."""
    m = re.search(r"\benum\s+" + re.escape(name) + r"\s*\{", text)
    if not m:
        return None
    body = balanced(text, m.end() - 1, "{", "}")
    if body is None:
        return None
    out, nxt = [], 0
    for item in body.split(","):
        item = item.strip()
        if not item:
            continue
        if "=" in item:
            ident, _, val = item.partition("=")
            val = val.strip().rstrip("uUlL")
            try:
                nxt = int(val, 0)
            except ValueError:
                return None       # an expression we cannot evaluate: stay honest
            ident = ident.strip()
        else:
            ident = item
        if not re.fullmatch(r"[A-Za-z_]\w*", ident):
            return None
        out.append((ident, nxt))
        nxt += 1
    return out


def c_define(text, name):
    m = re.search(r"^\s*#\s*define\s+" + re.escape(name) + r"\s+(\S+)", text, re.M)
    if not m:
        return None
    try:
        return int(m.group(1).rstrip("uUlL"), 0)
    except ValueError:
        return None


def split_top_commas(s):
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur)
    return out


def c_fnptr_typedef(text, name):
    """(param count, returns_void) for `typedef R (*name)(...)`."""
    # The return type may not contain a paren or a semicolon, which keeps the
    # match from starting at some earlier typedef and swallowing everything up
    # to this one.
    m = re.search(r"typedef\s+([^;()]+?)\s*\(\s*\*\s*" + re.escape(name) + r"\s*\)\s*\(",
                  text, re.S)
    if not m:
        return None
    params = balanced(text, m.end() - 1, "(", ")")
    if params is None:
        return None
    parts = [p.strip() for p in split_top_commas(params) if p.strip()]
    if len(parts) == 1 and parts[0] == "void":
        parts = []
    ret = m.group(1).strip()
    return len(parts), ret == "void"


# --- Odin parsing -----------------------------------------------------------

def odin_block(text, decl):
    """Body of a `Name :: <decl> {` ... `}` top-level declaration."""
    m = re.search(r"^" + re.escape(decl) + r"\s*::\s*[^\n{]*\{$", text, re.M)
    if not m:
        return None
    end = text.find("\n}", m.end())
    return text[m.end():end] if end != -1 else None


def odin_struct_fields(text, name):
    body = odin_block(text, name)
    if body is None:
        return None
    fields = []
    for line in body.split("\n"):
        line = re.sub(r"//.*", "", line).strip()
        if not line:
            continue
        m = re.match(r"([A-Za-z_]\w*)\s*:", line)
        if m:
            fields.append(m.group(1))
    return fields


def odin_enum_members(text, name):
    body = odin_block(text, name)
    if body is None:
        return None
    out, nxt = [], 0
    for line in body.split("\n"):
        line = re.sub(r"//.*", "", line).strip().rstrip(",").strip()
        if not line:
            continue
        if "=" in line:
            ident, _, val = line.partition("=")
            try:
                nxt = int(val.strip(), 0)
            except ValueError:
                return None
            ident = ident.strip()
        else:
            ident = line
        if not re.fullmatch(r"[A-Za-z_]\w*", ident):
            return None
        out.append((ident, nxt))
        nxt += 1
    return out


def odin_constant(text, name):
    m = re.search(r"^" + re.escape(name) + r"\s*::\s*(-?\w+)\s*$", text, re.M)
    if not m:
        return None
    try:
        return int(m.group(1), 0)
    except ValueError:
        return None


def odin_proc_type(text, name):
    """(param count, returns_void) for `Name :: #type proc "c" (...) -> R`."""
    m = re.search(r"^" + re.escape(name) + r'\s*::\s*#type\s+proc\s+"c"\s*\(', text, re.M)
    if not m:
        return None
    params = balanced(text, m.end() - 1, "(", ")")
    if params is None:
        return None
    tail = text[text.index(params, m.end() - 1) + len(params):]
    tail = tail[:tail.find("\n")]
    parts = [p for p in split_top_commas(params) if p.strip()]
    return len(parts), "->" not in tail


def odin_link_names(text):
    return re.findall(r'@\(link_name\s*=\s*"([A-Za-z_]\w*)"\)', text)


# --- the checks -------------------------------------------------------------

class Report:
    def __init__(self, verbose):
        self.verbose, self.fails, self.notes = verbose, [], []

    def ok(self, group, msg):
        if self.verbose:
            print(f"  ok    {group}: {msg}")

    def note(self, group, msg):
        self.notes.append((group, msg))
        if self.verbose:
            print(f"  note  {group}: {msg}")

    def fail(self, group, msg):
        self.fails.append((group, msg))
        print(f"  FAIL  {group}: {msg}")


def check_structs(rep, odin, hdr):
    for oname, cname, header in STRUCTS:
        of = odin_struct_fields(odin, oname)
        cf = c_struct_fields(hdr[header], cname)
        if of is None:
            rep.fail("struct", f"{oname} not found in {ODIN_BINDINGS}")
            continue
        if cf is None:
            rep.fail("struct", f"struct {cname} not found in {header}")
            continue
        # Only the shared prefix has to agree. A struct that is longer on one
        # side is what libssh's `size` field exists for: the shorter of the two
        # bounds how far libssh will look, and it looks at C offsets, so a
        # matching prefix is exactly the condition for correctness. A mismatch
        # *inside* the prefix is the catastrophic case.
        n = min(len(of), len(cf))
        bad = [i for i in range(n) if of[i] != cf[i]]
        for i in bad:
            rep.fail("struct", f"{oname} slot {i}: Odin `{of[i]}` vs C `{cf[i]}` "
                               f"— libssh reads this slot as {cf[i]}, so whatever "
                               f"is assigned to `{of[i]}` is called on that event")
        if bad:
            continue
        if of[:2] != ["size", "userdata"]:
            rep.fail("struct", f"{oname} must start with size, userdata "
                               f"(found {of[:2]})")
            continue
        rep.ok("struct", f"{oname} matches {cname} on all {n} shared fields, in order")
        if len(of) > len(cf):
            tail = ", ".join(of[len(cf):])
            rep.note("struct", f"{oname} declares {len(of) - len(cf)} slot(s) this "
                               f"libssh does not have ({tail}) — harmless, an older "
                               f"libssh never reads past its own last field")
        elif len(cf) > len(of):
            tail = ", ".join(cf[len(of):])
            rep.note("struct", f"{cname} has {len(cf) - len(of)} slot(s) {oname} does "
                               f"not declare ({tail}) — unreachable until added here")


def check_callbacks(rep, odin, hdr):
    for oname, cname, header in CALLBACKS:
        o = odin_proc_type(odin, oname)
        c = c_fnptr_typedef(hdr[header], cname)
        if o is None:
            rep.fail("callback", f"{oname} not found or unparseable in {ODIN_BINDINGS}")
            continue
        if c is None:
            rep.fail("callback", f"typedef {cname} not found in {header}")
            continue
        if o[0] != c[0]:
            rep.fail("callback", f"{oname} takes {o[0]} parameters, {cname} takes {c[0]}")
        elif o[1] != c[1]:
            want = "void" if c[1] else "a value"
            rep.fail("callback", f"{oname} returns {'void' if o[1] else 'a value'}, "
                                 f"{cname} returns {want}")
        else:
            rep.ok("callback", f"{oname} matches {cname} ({o[0]} params)")


def check_enums(rep, odin, hdr):
    for oname, cname, prefix, header in ENUMS:
        om = odin_enum_members(odin, oname)
        cm = c_enum_members(hdr[header], cname)
        if om is None:
            rep.fail("enum", f"{oname} not found or unparseable in {ODIN_BINDINGS}")
            continue
        if cm is None:
            rep.fail("enum", f"enum {cname} not found or unparseable in {header}")
            continue
        cvals = dict(cm)
        cmax = max(v for _, v in cm)
        bad, ahead = False, []
        for ident, val in om:
            want = prefix + ident.upper()
            if want in cvals:
                if cvals[want] != val:
                    rep.fail("enum", f"{oname}.{ident} = {val} but {want} = {cvals[want]}")
                    bad = True
            elif val > cmax:
                # Past the end of this libssh's enum: a value only a newer
                # library defines. Harmless unless it is actually passed.
                ahead.append(ident)
            else:
                at = next((n for n, v in cm if v == val), "nothing")
                rep.fail("enum", f"{oname}.{ident} = {val}, but {cname} does not "
                                 f"define {want} and {val} is {at}")
                bad = True
        if not bad:
            n = len(om) - len(ahead)
            rep.ok("enum", f"{oname} agrees with {cname} on all {n} shared values")
            if ahead:
                rep.note("enum", f"{oname} names {len(ahead)} value(s) past the end of "
                                 f"this libssh's {cname} ({', '.join(ahead)}) — added "
                                 f"upstream after this version, harmless unless passed")
            extra = len(cm) - len(om)
            if extra > 0:
                tail = ", ".join(n for n, _ in cm[len(om):][:3])
                rep.note("enum", f"{cname} has {extra} enumerator(s) {oname} does not "
                                 f"bind ({tail}{'...' if extra > 3 else ''}) — "
                                 f"appended upstream, harmless")


def check_constants(rep, odin, hdr):
    for oname, cname, header in CONSTANTS:
        ov = odin_constant(odin, oname)
        cv = c_define(hdr[header], cname)
        if ov is None:
            rep.fail("constant", f"{oname} not found in {ODIN_BINDINGS}")
        elif cv is None:
            rep.fail("constant", f"#define {cname} not found in {header}")
        elif ov != cv:
            rep.fail("constant", f"{oname} = {ov} but {cname} = {cv}")
        else:
            rep.ok("constant", f"{oname} = {ov} = {cname}")


def check_symbols(rep, odin, hdr, libpath):
    names = odin_link_names(odin)
    if not names:
        rep.fail("symbol", f"no @(link_name = ...) found in {ODIN_BINDINGS}")
        return
    dupes = sorted({n for n in names if names.count(n) > 1})
    for d in dupes:
        rep.note("symbol", f"{d} is bound more than once")

    syms = library_symbols(libpath)
    if syms is not None:
        source = f"{os.path.basename(libpath)} (nm)"
    else:
        syms = header_declared(hdr)
        source = "header declarations (no usable nm)"
        rep.note("symbol", "no symbol reader available; falling back to a header "
                           "scan, which cannot see a declared-but-undefined symbol")
    missing = [n for n in names if n not in syms]
    for n in missing:
        rep.fail("symbol", f"{n} is bound but not present in {source}")
    if not missing:
        rep.ok("symbol", f"all {len(names)} bound symbols found in {source}")

    for n in names:
        if n in CONDITIONAL_SYMBOLS:
            where, why = CONDITIONAL_SYMBOLS[n]
            rep.fail("symbol", f"{n} is not defined on every supported platform "
                               f"({where}): {why}")
    if not any(n in CONDITIONAL_SYMBOLS for n in names):
        rep.ok("symbol", f"none of the {len(CONDITIONAL_SYMBOLS)} known "
                         f"platform-conditional symbols are bound")


def check_pinned(rep, hdr):
    for header, text, why in PINNED:
        if text in hdr[header]:
            rep.ok("pinned", f"{header} still says `{text}`")
        else:
            rep.fail("pinned", f"{header} no longer contains `{text}` — {why}")


# --- main -------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--check", action="store_true",
                    help="print only problems and exit 1 if there are any")
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="print every check, even under --check")
    ap.add_argument("--headers", metavar="DIR",
                    help="directory containing libssh/callbacks.h (overrides discovery)")
    ap.add_argument("--lib", metavar="PATH",
                    help="shared library to read symbols from (overrides discovery)")
    ap.add_argument("--odin", metavar="PATH", default=ODIN_BINDINGS,
                    help="bindings file to check (default: libssh/libssh.odin)")
    a = ap.parse_args()

    inc = find_headers(a.headers)
    if inc is None and a.headers:
        need = ", ".join(HEADERS)
        print(f"bindings check failed: --headers {a.headers} has no libssh/ "
              f"containing {need}")
        return 1
    if inc is None:
        # Not every machine that builds these docs has libssh's development
        # headers — the CI docs job does not. Absent headers are a reason to
        # say nothing, not a reason to fail.
        print("bindings check skipped: no libssh headers found "
              "(looked via pkg-config and the usual prefixes). "
              "Install libssh's development headers, or pass --headers DIR.")
        return 0

    if not os.path.isfile(a.odin):
        print(f"bindings check failed: {a.odin} does not exist")
        return 1

    odin = open(a.odin, encoding="utf-8").read()
    hdr = {h: strip_c_comments(open(os.path.join(inc, "libssh", h),
                                    encoding="utf-8").read()) for h in HEADERS}
    libpath = find_library(a.lib)

    verbose = a.verbose or not a.check
    rep = Report(verbose)
    if verbose:
        parts = [re.search(r"#define\s+LIBSSH_VERSION_" + p + r"\s+(\d+)",
                           hdr["libssh_version.h"]) for p in ("MAJOR", "MINOR", "MICRO")]
        v = ".".join(m.group(1) for m in parts if m) if all(parts) else "unknown version"
        print(f"headers  {os.path.join(inc, 'libssh')}  (libssh {v})")
        print(f"library  {libpath or 'not found — symbol check falls back to headers'}")
        print(f"odin     {a.odin}")
        print()

    check_structs(rep, odin, hdr)
    check_callbacks(rep, odin, hdr)
    check_enums(rep, odin, hdr)
    check_constants(rep, odin, hdr)
    check_symbols(rep, odin, hdr, libpath)
    check_pinned(rep, hdr)

    if rep.fails:
        print(f"\n{len(rep.fails)} binding divergence(s) — see docs/bindings.md")
        return 1 if a.check else 0
    if verbose:
        print("\nbindings match the installed libssh headers")
    else:
        print("bindings match the installed libssh headers")
    return 0


if __name__ == "__main__":
    sys.exit(main())
