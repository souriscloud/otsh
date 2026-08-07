# Maintaining the libssh bindings

`libssh/libssh.odin` is a hand-written mirror of part of libssh's C server API:
two structs copied field for field, twelve function-pointer signatures, six
enums, and 49 foreign symbols. Everything else in this repository is built on
the assumption that the mirror is exact.

Nothing checks that assumption at compile time. Odin's `foreign` blocks are a
promise, not a verification: you tell the compiler what a C symbol looks like
and it believes you. Get a struct field order wrong and the program still
compiles, still links, and still runs — libssh simply reads the field it wants
at *its* offset, finds whatever you put there, and calls it. The symptom is a
callback that never fires, or one that fires with someone else's arguments. No
error, no crash, no stack trace pointing anywhere near the mistake.

This page is how to work on that file without introducing one of those. There
is also a checker, `docs/tools/check_bindings.py`, which compares the bindings
against the libssh headers installed on the machine; it runs as part of
`./check.sh`. It is described at the end, along with what it cannot see.

For how the bindings are *used* — the connection lifecycle, which callback runs
on which thread, the input path — see [Architecture](architecture.md). This page
is only about the boundary itself.

## What is in the file, in order

The layout is deliberate; keep additions in the section they belong to.

| Section | Contents |
| --- | --- |
| `foreign import` | Which library to link, per platform, and the Windows-specific notes about vcpkg |
| Opaque handles | `Session`, `Channel`, `Bind`, `Event`, `Key`, `Threads_Callbacks` — one `distinct rawptr` per C `struct foo *` typedef |
| Platform types | `Socket`, `INVALID_SOCKET`, `socket_valid`, `version_int` |
| Version floor | `MIN_MAJOR` / `MIN_MINOR` / `MIN_MICRO` |
| Return codes | `OK`, `ERROR`, `AGAIN`, `EOF`, and the `Auth` / `Pubkey_State` enums |
| Auth method bitmask | `AUTH_METHOD_*` |
| Options and key types | `Bind_Option`, `Session_Option`, `Pubkey_Hash_Type`, `Keytype` |
| Callback signatures | The `*_Proc` types, one per C function-pointer typedef |
| Callback structs | `Server_Callbacks`, `Channel_Callbacks` |
| `foreign lib { ... }` | Every bound function, grouped: threads, bind, session, event loop, channel, pki, fingerprints |

Two rules about the file as a whole:

- **Only bind what is used.** The package is a server-side subset on purpose.
  A binding nobody calls is a mirror nobody maintains, and it is exactly where
  drift accumulates unnoticed.
- **Odin names drop the `ssh_` prefix**, because callers write `ls.channel_write`
  and the prefix would stutter. The `@(link_name = ...)` attribute is what makes
  that rename safe: it is the real symbol. Drop it and Odin looks for a symbol
  named after the Odin declaration — `channel_write` — which does not exist, and
  the link fails. That failure is at least loud. `gen_api.py` reads the same
  attribute to print "C: `ssh_channel_write`" next to each entry on the API page.
- **The whole `foreign lib` block is `@(default_calling_convention = "c")`**, so
  individual declarations do not repeat it. Callback *types* still have to say
  `proc "c"` explicitly, because they are ordinary top-level declarations
  outside the block.

## Mirroring a C struct

Two structs are mirrored: `Server_Callbacks` and `Channel_Callbacks`, from
`struct ssh_server_callbacks_struct` and `struct ssh_channel_callbacks_struct`
in `libssh/callbacks.h`.

### Field order is the entire contract

libssh reaches into these structs by C field offset. This is the dispatch guard
it uses for every callback, verbatim from `callbacks.h`:

```c
#define ssh_callbacks_exists(p,c) (\
  (p != NULL) && ( (char *)&((p)-> c) < (char *)(p) + (p)->size ) && \
  ((p)-> c != NULL) \
  )
```

`&((p)->c)` is computed by the C compiler from libssh's own struct definition.
If your Odin struct puts `auth_none_function` where C puts
`auth_password_function`, then a client authenticating with a password gets your
none-auth handler called, with a password-auth argument list — a `cstring` more
than it expects, at ABI positions it will read as something else. Both functions
are non-nil pointers, so the guard passes. Nothing anywhere reports a problem.

So: **the fields must appear in exactly the order the C header declares them,
with no gaps and no reordering for tidiness.** Alphabetising this struct, or
grouping the auth callbacks together, would be a serious bug that no test in
this repository is guaranteed to catch.

Copy the field names verbatim from the header too, even for slots you type as
`rawptr`. They cost nothing and they are what makes an automated comparison
possible.

### `size` is not optional

Both structs begin with `size: c.size_t`. In C you are supposed to fill it with
the `ssh_callbacks_init` macro:

```c
#define ssh_callbacks_init(p) do {\
	(p)->size=sizeof(*(p)); \
} while(0);
```

There is no macro to call from Odin, so the field is set by hand at both
construction sites in `ssh/server.odin`:

<!-- check:skip fields elided with `// ...`; see ssh/server.odin for the full literal construction -->
```odin
s.server_cb = ls.Server_Callbacks {
	size     = size_of(ls.Server_Callbacks),
	userdata = s,
	// ...
}
```

Leave it zero and the struct is still *accepted* — `ssh_set_server_callbacks`
validates it with `is_callback_valid`, which in libssh 0.10.6 through 0.12.0 is
written `(cb->size > 0 || cb->size <= 1024 * sizeof(void *))` and is therefore
true for everything, zero included. What happens instead is that
`ssh_callbacks_exists` then evaluates `&(p->field) < (char *)p + 0` for every
field, which is false for every field, and libssh silently calls none of your
callbacks. The connection hangs at the first thing that needed one. If you ever
see that, check `size` first.

### Slots you do not use

Type them `rawptr` and leave them at Odin's zero value, which is a null pointer
— exactly what libssh's `((p)->c != NULL)` test treats as "not implemented".
`Server_Callbacks` has seven such slots (the GSSAPI ones,
`service_request_function`, `channel_open_request_direct_tcpip_function`,
`auth_kbdint_function`); `Channel_Callbacks` has nine.

Do not delete them to shorten the struct. A deleted slot in the middle shifts
every field after it, which is the catastrophic case above. A deleted slot at
the end is merely useless: it makes `size_of` smaller, so `size` is smaller, so
the trailing callbacks are reported absent — which they already were.

Give a slot a real type only when you are about to install a function in it, and
add the matching `*_Proc` type at the same time.

### libssh does not copy the struct

From `callbacks.h`, on `ssh_set_server_callbacks`:

> Note, that the structure is not copied to the session structure so it needs to
> be valid for the whole session lifetime.

That is why `ssh.Session` embeds `server_cb` and `channel_cb` **by value** rather
than building them on the stack. A stack temporary would be a dangling pointer
the moment the setup function returned, and libssh would then dispatch through
freed memory. If you add a third callback struct, it goes in `Session` too.

### When the two sides are different lengths

They will be. libssh appends callbacks to the end of these structs between
releases, and this package supports 0.10.6 upward, so:

- **Odin longer than C** (running against an older libssh): harmless. libssh
  never looks past its own last field; the extra slots are simply never read.
  This is the case today on libssh 0.10.6, where `Server_Callbacks` declares two
  slots — `channel_open_request_direct_tcpip_function`, `auth_kbdint_function` —
  that the 0.10.6 header does not have.
- **C longer than Odin** (running against a newer libssh): also harmless, but
  the new callbacks are unreachable. `size` is smaller than libssh's own
  `sizeof`, so it treats the trailing fields as absent instead of reading past
  the end of your allocation. That bound is the entire reason `size` exists.
- **Any disagreement inside the shared prefix**: catastrophic, per above.

The checker encodes exactly this: a prefix mismatch is a failure, a length
difference is a note.

## Callbacks: `proc "c"` and the missing context

Every function pointer handed to libssh must be declared `proc "c"`, both in the
signature type and at the definition:

<!-- check:verbatim libssh/libssh.odin -->
```odin
Auth_None_Proc :: #type proc "c" (session: Session, user: cstring, userdata: rawptr) -> c.int
```

Odin's default calling convention passes an implicit `context` pointer. C knows
nothing about that, so a `proc "odin"` used as a C callback would read the
context out of a register C never set. `proc "c"` uses the platform C ABI and has
no context at all.

The consequence is that **inside a callback, `context` does not exist**. Not
"is empty" — the language will not let you touch anything that needs one, which
in Odin is most of it: `new`, `make`, `append`, `delete`, `fmt.println`, string
concatenation, `strings.Builder`, anything taking an implicit allocator.

Where a callback genuinely has to call ordinary Odin code, it establishes one
explicitly:

<!-- check:verbatim ssh/server.odin -->
```odin
context = runtime.default_context()
```

This happens in exactly two places in `ssh/server.odin`, both of them one level
below the callbacks themselves: `allow`, because it calls the user's
`Authenticator` and the audit sink, and `derive_id`, because the HMAC helpers it
calls are ordinary Odin procs. `derive_id` still allocates nothing —
`pseudonym` writes its hex into the session's own buffer — so there is no arena
to tear down afterwards.

Do not scatter `context = runtime.default_context()` through the callbacks as a
reflex. `default_context()` hands out the heap allocator, and a heap allocation
on the callback path is a thing that can fail, block, or fragment while libssh
is mid-packet. If you find yourself needing one, ask first whether the data can
live in a fixed buffer instead.

### What a callback must not do

| Forbidden | Why |
| --- | --- |
| Allocate | There is no context, and the explicit one is a heap allocator on libssh's own packet-processing path |
| Block — a lock, a socket read, a sleep | Callbacks run inside `ssh_event_dopoll` on the connection's session thread. Blocking there stops that connection's protocol handling, including its keepalives |
| Print | `fmt` needs a context, and stdio is a process-wide lock shared with every other session thread |
| Panic, or let a runtime check fire | The unwind would cross back into C, which is undefined behaviour |
| Keep a pointer to any argument | The `cstring`s are libssh's buffers; they are gone when the callback returns |

Signal handlers are the same shape and the same rules — `ssh/signal_posix.odin`'s
`stop_handler` is `proc "c"` and does exactly one thing, an atomic store, which
is the only thing that is safe there.

### Why `ssh.Session` is full of fixed-size arrays

Because "keep a pointer to any argument" is forbidden and "allocate" is
forbidden, the only remaining way to keep a username past the end of
`cb_auth_none` is to copy it into storage that already exists:

<!-- check:skip fields paired per line for readability; ssh/server.odin's Session struct declares each buf/len on its own line -->
```odin
user_buf: [64]u8,   user_len: int,
term_buf: [32]u8,   term_len: int,
fp_buf:   [96]u8,   fp_len:   int,
kt_buf:   [64]u8,   kt_len:   int,
id_buf:   [ID_SIZE]u8, id_len: int,
addr_buf: [64]u8,   addr_len: int,
```

`copy_cstr` fills one, bounded by the buffer, and the accessors (`user`, `term`,
`fingerprint`, `key_type`, `id`, `remote_addr`) return a `string` viewing it.
All of them are `proc "contextless"`, which is the same ABI as Odin's default
minus the context — a compile-time guarantee that they cannot allocate even by
accident. Truncation is the deliberate trade: a client-supplied username longer
than 63 bytes is cut, not rejected and not heap-allocated.

If you add a new piece of per-connection data captured in a callback, follow the
pattern: fixed buffer plus length, `contextless` accessor.

## Type mapping

| C | Odin | Note |
| --- | --- | --- |
| `int` | `c.int` | `i32` everywhere Odin supports |
| `unsigned int` | `c.uint` | |
| `uint32_t` | `u32` | Spell fixed-width C types as fixed-width Odin types |
| `size_t` | `c.size_t` | `uint`, so pointer-width |
| `char *` (borrowed) | `cstring` | |
| `unsigned char **` | `^[^]u8` | Pointer to a multi-pointer, for out-parameters |
| `void *` | `rawptr` | |
| `struct foo_struct *` | `distinct rawptr` | One named handle type per C typedef, so `Session` and `Channel` cannot be swapped |
| `enum foo_e` | `enum c.int` | C enums are `int` here; see below |
| `socket_t` | `Socket` | See below |
| `char` as a small signed code | not `c.char` | See below |

### `socket_t`: the same name, two widths

`libssh.h`:

```c
#ifdef _WIN32
typedef SOCKET socket_t;
#else
typedef int socket_t;
#endif
#define SSH_INVALID_SOCKET ((socket_t) -1)
```

A Windows `SOCKET` is a `UINT_PTR` — unsigned, and 64 bits wide on a 64-bit
build. Binding `ssh_get_fd` as `c.int` would truncate its return there. Hence:

<!-- check:verbatim libssh/libssh.odin -->
```odin
Socket :: uintptr when ODIN_OS == .Windows else c.int
INVALID_SOCKET :: ~Socket(0) when ODIN_OS == .Windows else Socket(-1)
```

And hence `socket_valid`, which exists because the obvious `fd < 0` test is
silently always false on Windows where the type is unsigned. Use it; do not
compare against `-1` by hand.

The general rule this is an instance of: **a C typedef that changes width or
signedness across platforms must be mirrored with a `when ODIN_OS` expression,
not with whichever spelling happens to work on the machine you are on.** The
cross-type-check CI steps (`odin check -target:windows_amd64` and
`-target:freebsd_amd64`) exist partly to catch the version of this mistake that
does produce a type error.

### `c.char` is unsigned, always

Odin's `core:c` declares:

<!-- check:skip quoted from Odin's core:c package (core/c/c.odin), outside this repo, to show why c.char is unsigned everywhere -->
```odin
char :: builtin.u8  // assuming -funsigned-char
```

— unconditionally, on every target, regardless of whether the platform's C
compiler treats `char` as signed. So `c.char` is `u8` and cannot hold a negative
value.

libssh passes the public-key probe state as a plain `char`:

```c
typedef int (*ssh_auth_pubkey_callback) (ssh_session session, const char *user,
		struct ssh_key_struct *pubkey, char signature_state, void *userdata);
```

with `SSH_PUBLICKEY_STATE_ERROR = -1`. The binding keeps the parameter as
`c.char` — right width, right ABI slot — and declares the enum signed so the
error value is representable:

<!-- check:verbatim libssh/libssh.odin -->
```odin
// c.char is unsigned on this platform, so the signed enum is spelled out.
Pubkey_State :: enum i8 {
	Error = -1,
	None  = 0,
	Valid = 1,
	Wrong = 2,
}
```

The reinterpretation happens at the call site, `ls.Pubkey_State(i8(signature_state))`
in `cb_auth_pubkey`. That is the pattern for any C parameter whose declared type
is wider or differently-signed than the value space it actually carries: bind
the C type, convert at the edge, and say why in a comment.

### Enums: bound by value, not by name

C enums here are plain `int`, so the Odin mirrors are `enum c.int` and the
members must land on the same numbers. Two ways they can be wrong:

- **Omit an entry in the middle.** Odin auto-increments, so every entry after
  the omission is off by one, and `bind_options_set` starts setting the wrong
  option. This is why `Bind_Option` lists all 25 entries including three marked
  `// deprecated` that this package never passes.
- **Rely on an ordering libssh changed.** libssh appends, so far, but only
  values that are actually spelled out in the header are guaranteed. Where a
  binding takes only a few entries out of a long enum, give them explicit
  values, as `Session_Option` does:

<!-- check:verbatim libssh/libssh.odin -->
```odin
// Only the entries we use; the ordering matches libssh's enum ssh_options_e.
Session_Option :: enum c.int {
	Host    = 0,
	Port    = 1,
	Timeout = 9, // seconds, as a uint64
}
```

`Keytype` takes the opposite approach — a prefix of `ssh_keytypes_e` with values
written out — which is also fine, because it is a prefix and the values are
explicit.

### Strings: who frees what

There is no single rule; libssh's own doc comments are authoritative, and they
are worth reading before binding anything that returns a `char *`. The three
patterns in use:

| Function | Ownership |
| --- | --- |
| `ssh_get_error`, `ssh_get_clientbanner`, `ssh_version`, `ssh_key_type_to_char` | Return `const char *` into libssh's own storage or a string literal. **Do not free.** Copy out if you need it past the call |
| `ssh_get_fingerprint_hash` | "The caller needs to free the memory using `ssh_string_free_char()`" |
| `ssh_get_publickey_hash` | Fills an out-parameter buffer that "can be freed using `ssh_clean_pubkey_hash()`" |

Both freeing functions are bound and both are used, paired with their producers,
in `capture_key_identity`:

<!-- check:verbatim ssh/server.odin -->
```odin
hash: [^]u8
hlen: c.size_t
if ls.get_publickey_hash(pubkey, .Sha256, &hash, &hlen) != ls.OK {
	return
}
defer ls.clean_pubkey_hash(&hash)

if fp := ls.get_fingerprint_hash(.Sha256, hash, hlen); fp != nil {
	copy_cstr(s.fp_buf[:], &s.fp_len, fp)
	ls.string_free_char(fp)
}
```

Note that these are *libssh's* deallocators, not `free`. libssh spells out why,
in the doc comment on `ssh_clean_pubkey_hash`:

> This is required under Microsoft platform as this library might use a
> different C library than your software, hence a different heap.

Calling Odin's `free` on a libssh allocation would work on Linux and macOS and
corrupt the heap on Windows. **Whenever you bind a function that returns
allocated memory, bind its matching deallocator in the same change.**

## Linking

<!-- check:verbatim libssh/libssh.odin -->
```odin
LIB :: #config(OTSH_LIBSSH, "system:ssh.lib" when ODIN_OS == .Windows else "system:ssh")

foreign import lib {LIB}
```

`system:` means "ask the platform linker for this", so the linker still needs
the directory. `build.sh` supplies it — with `-L$LIBDIR -Wl,-rpath,$LIBDIR` on
unix-likes and `/LIBPATH:$LIBDIR` for MSVC, where `$LIBDIR` comes from
`pkg-config --variable=libdir libssh` or the vcpkg install root. There is no
rpath on Windows, so `ssh.dll` must also be on `%PATH%` at run time.

The library is named through a constant rather than written into the
`foreign import` directly so that a `-define` can replace it — pointing it at
a `libssh.a` is what produces a binary with no libssh dependency. The braced
form is required for that: `foreign import` takes a string *literal*, so
`foreign import lib LIB` is a syntax error, and only `foreign import lib {LIB}`
accepts a compile-time constant. See [Static linking](static-linking.md).

One trap here has already bitten, and it is the reason the symbol check exists.
`callbacks.h` declares `ssh_threads_get_pthread` on every platform, but
libssh's `src/CMakeLists.txt` compiles `threads/pthread.c` only under
`CMAKE_USE_PTHREADS_INIT`; a Windows build gets `threads/winlocks.c` instead. So
the symbol is declared everywhere and *defined* only on unix, and binding it
produced:

```
error LNK2019: unresolved external symbol ssh_threads_get_pthread
```

on Windows and nowhere else. The binding uses `ssh_threads_get_default`, which
every backend defines and which returns the same thing on unix.

**A declaration in a header is not evidence that a symbol exists.** Check the
library, and check libssh's build files for anything conditional.

## Adding a binding, step by step

1. **Read the C declaration in the installed header**, not in documentation, not
   from memory: `/opt/homebrew/opt/libssh/include/libssh/` on Homebrew,
   `/usr/include/libssh/` on Linux, or wherever `pkg-config --cflags libssh`
   points. Read the doc comment above it too — that is where ownership and
   lifetime rules are written.
2. **Check whether the symbol is conditional.** Grep libssh's
   `src/CMakeLists.txt` for the file it lives in. If the file is compiled under
   an `if`, the symbol is not portable; find the unconditional equivalent. The
   source mirror is at <https://gitlab.com/libssh/libssh-mirror>.
3. **Check the version floor.** The declared minimum is 0.10.6
   (`MIN_MAJOR`/`MIN_MINOR`/`MIN_MICRO`, chosen because that is where the
   Terrapin fix landed). A function added in 0.11 cannot be bound without either
   raising the floor or arranging a fallback — there is no weak linking here.
4. **Write the declaration** in the right section of the `foreign lib` block,
   with `@(link_name = "ssh_...")` and the Odin name with the prefix dropped.
   Map each parameter with the table above.
5. **If it returns allocated memory, bind the deallocator too**, in the same
   change, and pair them at the call site with `defer`.
6. **If it is a callback**, add the `*_Proc` type with `proc "c"`, put the field
   in the struct *at the C offset*, and re-read the "what a callback must not
   do" table before writing the body.
7. **Write the doc comment** on the Odin declaration. `docs/tools/gen_api.py`
   renders it onto [the libssh API page](api-libssh.md), and the C name from
   `link_name` next to it. Say what libssh's own docs do not make obvious —
   `channel_poll` and `channel_read_nonblocking` are the examples to imitate.
8. **Run the checks.**

```sh
python3 docs/tools/check_bindings.py    # full report
python3 docs/tools/gen_api.py           # regenerate the API page if you wrote a doc comment
./check.sh                              # everything
```

## Verifying a binding

`docs/tools/check_bindings.py` compares the file against the libssh headers
installed on this machine. Run it with no arguments for a full report; `--check`
prints only problems and exits non-zero, which is how `./check.sh` invokes it.

```
python3 docs/tools/check_bindings.py            # full report, exit 0
python3 docs/tools/check_bindings.py --check    # problems only, exit 1 if any
python3 docs/tools/check_bindings.py --headers DIR --lib PATH --odin FILE
```

What it compares:

| Check | Catches |
| --- | --- |
| Struct layout | Field count and order of both callback structs against `callbacks.h`. A prefix mismatch fails; a length difference is a note, per the rules above |
| Callback shape | Parameter count and void-ness of each `*_Proc` against the C typedef |
| Enums | Every Odin enumerator against the C enum, **by value** — so an insertion upstream is caught, while an append is reported as news |
| Constants | `OK`/`ERROR`/`AGAIN`/`EOF` and the `AUTH_METHOD_*` mask against the `#define`s |
| Symbols | Every `@(link_name = ...)` against the exported symbols of the installed shared library, read with `nm`; falls back to a header scan where `nm` is unavailable |
| Portability | A curated list of symbols libssh declares everywhere but defines conditionally. `ssh_threads_get_pthread` is on it |
| Pinned spellings | That `libssh.h` still has both `socket_t` typedefs and that the pubkey callback still takes a plain `char` — the two facts the type mapping above is built on |

It finds headers through `pkg-config` and then the usual prefixes. **On a
machine with no libssh headers it prints why and exits 0**, because a checkout
being built for its documentation is not a broken checkout.

The `--odin` flag takes an alternative bindings file, which is how the checker
itself is tested: copy `libssh/libssh.odin` somewhere, break it on purpose, and
confirm the tool says so.

### What the checker cannot see

Do not read a green run as "the bindings are correct". It compares names,
counts, and numbers. It does not compare types, and several classes of mistake
are invisible to it:

- **A wrong parameter type of the right arity.** `c.int` where libssh wants
  `uint32_t` has the same parameter count and will pass. Read the header.
- **A wrong return type.** Only void versus non-void is compared.
- **A missing deallocator, or the wrong one.** Ownership lives in prose in
  libssh's doc comments; nothing machine-readable states it.
- **Anything about a platform that is not this one.** `nm` reads the library
  installed here. A symbol missing only on Windows is invisible unless it is in
  the conditional-symbols list, which is hand-maintained — if you find another
  one, add it there with the source file and the build condition.
- **Semantics.** That `ssh_set_server_callbacks` must be called *before*
  `ssh_handle_key_exchange`, or the handshake hangs one connection in three, is
  a fact no header states. Those live in
  [Architecture](architecture.md#known-rough-edges) and in comments at the call
  sites.
- **Whether the struct is still alive.** libssh keeps the pointer you gave it;
  no static check knows how long your storage lives.

The end-to-end tests in `tests/` are what actually exercise the boundary. Run
them (`./test.sh`) after any change here, and if the change touches the callback
structs, connect a real client to `examples/whoami` and confirm auth, pty and
shell requests all still arrive.
