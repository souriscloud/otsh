# Static linking

By default an otsh binary loads libssh from the system at startup, the way
almost every C-linked program does. This page is about the other option:
folding libssh — and, on Linux, everything else — into the executable, so it
runs on a machine that has never heard of libssh.

Everything below is a measurement. Every size, every `ldd` line and every
failure was produced by running the command shown, on the platform named, and
the negative results are here for the same reason as the positive ones: three
of the four things people assume about static linking on these platforms turn
out to be false.

## Read this first: the trade you are making

**A statically linked libssh means a libssh CVE is your problem to redeploy.**

This is not a footnote. otsh is a network-facing SSH server. When the next
advisory lands on [libssh.org/security](https://www.libssh.org/security/):

- A **dynamically** linked binary is fixed by `apt upgrade` or `brew upgrade`
  and a restart. The system package manager does the work, on every host, for
  every program that links libssh.
- A **statically** linked binary is fixed by rebuilding it against a patched
  libssh and shipping a new executable to every machine running it. Until you
  do, the vulnerable code is inside your program and nothing on the host can
  reach it.

The version really is frozen in. A static binary carries libssh's own strings:

```console
$ strings -a ./tracker-static | grep -m1 'Distributed under the LGPL'
0.12.2 (c) 2003-2026 Aris Adamantiadis, Andreas Schneider and libssh
contributors. Distributed under the LGPL, ...
$ strings -a ./tracker-static | grep -m1 'SSH-2.0'
SSH-2.0-libssh_0.12.2
$ strings -a ./tracker-dynamic | grep -c 'SSH-2.0-libssh'
0
```

The dynamically linked binary contains none of it, because on that one the
version arrives at run time from whatever the host has installed.

So: link statically when you are distributing a binary to machines you do not
control the packages on, or into a scratch container, and you have a build
pipeline that can rebuild and redeploy on an advisory. Keep the default — a
dynamic libssh — for anything long-lived on a host with a package manager.
That is the normal case, and it stays the default for a reason.

### How this interacts with the libssh floor

otsh refuses to start on libssh older than 0.10.6, the release carrying the
fix for CVE-2023-48795 (Terrapin). That check is deliberately made at run time
(`check_libssh_version` in `ssh/server.odin`), because the shared library that
gets loaded is not necessarily the one the bindings were compiled against.

Static linking removes that distinction: the archive *is* the library, so the
check runs against a version fixed when you linked. It still fires — a static
binary built against a pre-0.10.6 archive still refuses to bind — but it can
no longer be satisfied by upgrading the host. The floor stops being a runtime
guard and becomes a build-time assertion.

## What is actually possible

| Platform | libssh linked from an archive | No dynamic dependencies at all |
| --- | --- | --- |
| macOS | yes | **impossible** — Apple ships no static libc |
| Linux, glibc | yes | yes, if libssh has no GSSAPI |
| Linux, musl (Alpine) | yes, after building libssh yourself | yes |
| Windows | untested — see [below](#windows) |

Hence two flags rather than one, because a single `--static` that silently
meant different things per platform would be worse than saying so:

```sh
otsh build --static ~/src/myapp        # libssh from an archive; libc dynamic
otsh build --fully-static ~/src/myapp  # nothing dynamic at all (Linux only)
```

`otsh flags --static` and `otsh flags --fully-static` print the same thing for
a Makefile or an IDE, and `--fully-static` on macOS exits non-zero with an
explanation rather than producing a broken command line.

## How it works

The obstacle is that `foreign import lib "system:ssh"` makes the Odin compiler
emit `-lssh`, and **every linker tested resolves `-lssh` to the shared library
even when the archive is also on the command line.** Adding `libssh.a` via
`-extra-linker-flags` therefore does nothing at all: the binary still lists
`libssh.4.dylib` in `otool -L`. That is the false assumption most attempts
start from.

So the `-l` has to go away. `libssh/libssh.odin` names its library through a
compile-time constant:

<!-- check:verbatim libssh/libssh.odin -->
```odin
LIB :: #config(OTSH_LIBSSH, "system:ssh.lib" when ODIN_OS == .Windows else "system:ssh")

foreign import lib {LIB}
```

`system:` followed by an **absolute path** is passed to the linker verbatim as
an input file instead of being turned into a `-l`:

```sh
odin build . -define:OTSH_LIBSSH=system:/usr/lib/x86_64-linux-gnu/libssh.a
```

Two details worth knowing if you build this yourself:

- **`foreign import` needs a string literal.** `foreign import lib LIB` is a
  syntax error — the import path is parsed before constants are evaluated. The
  braced form `foreign import lib {LIB}` is what lets a constant, and therefore
  a `-define`, reach it. This is why the define carries a path rather than
  being a boolean: there is no portable location for a `libssh.a`, and a
  boolean would only move the guessing into the bindings, where it cannot see
  pkg-config.
- **The archive's own dependencies are yours to supply.** `pkg-config --static
  --libs libssh` reports only `-lssh` on Homebrew 0.12.2 and Debian 0.11.5
  alike — it declares no static dependencies whatsoever, so it cannot tell you
  that you need OpenSSL and zlib. `pkg-config --static --libs libcrypto` *does*
  declare its own, which is where the zstd requirement on Debian comes from.
  `otsh build --static` works all of this out; the sections below say what it
  resolves to on each platform.

## macOS

Fully static is not possible, and this is a property of the platform rather
than of otsh. Apple ships no static libc: there is no `libSystem.a` or
`libc.a` anywhere in the SDK, and passing `-static` stops at the C runtime
startup file.

```console
$ ls "$(xcrun --show-sdk-path)"/usr/lib/libSystem*.a "$(xcrun --show-sdk-path)"/usr/lib/libc.a
ls: no matches
$ otsh build --fully-static examples/tracker
otsh: macOS cannot link a fully static executable.
  Apple ships no static libSystem or libc.a ...
```

Forcing it past otsh's check reaches the same wall from clang:

```console
ld: library 'crt0.o' not found
```

What **is** achievable is a binary with no libssh and no OpenSSL dependency.
Homebrew's libssh ships `libssh.a` beside the dylibs, and `openssl@3` ships
`libcrypto.a`:

```console
$ otsh flags --static
-collection:otsh=/path/to/otsh
-define:OTSH_LIBSSH=system:/opt/homebrew/Cellar/libssh/0.12.2/lib/libssh.a
-extra-linker-flags:"/opt/homebrew/Cellar/openssl@3/3.6.3/lib/libcrypto.a -lz -framework Kerberos"

$ otsh build --static examples/tracker
$ otool -L examples/tracker/tracker
	/System/Library/Frameworks/Cocoa.framework/.../Cocoa
	/usr/lib/libSystem.B.dylib
	/usr/lib/libz.1.dylib
	/System/Library/Frameworks/Kerberos.framework/.../Kerberos
```

No libssh, no libcrypto. What remains is libSystem, zlib and Kerberos, all of
which are part of macOS itself — there is no `libz.a` on macOS at all, only
`.tbd` stubs for the system dylib, and Homebrew's libssh is built with GSSAPI
so it needs the system Kerberos framework. All three are present on every mac,
so the binary is portable across machines in a way the default build is not.

Measured on macOS 26.5, arm64, Xcode 26.5 SDK, libssh 0.12.2, OpenSSL 3.6.3,
building `examples/tracker`:

| Build | Binary | Stripped |
| --- | --- | --- |
| default (dynamic) | 654,792 | 609,544 |
| `--static` | 5,363,960 | 4,680,024 |

The 4.7 MB is almost entirely OpenSSL.

## Linux, glibc

Both modes work. Measured on Debian 13 (trixie), aarch64, libssh 0.11.5,
OpenSSL 3.5, glibc 2.41.

`--static` uses the distribution's own `libssh.a` — Debian's `libssh-dev` does
ship one — and resolves the rest from pkg-config:

```console
$ otsh flags --static
-define:OTSH_LIBSSH=system:/usr/lib/aarch64-linux-gnu/libssh.a
-extra-linker-flags:"/usr/lib/.../libcrypto.a /usr/lib/.../libz.a
                     /usr/lib/.../libzstd.a /usr/lib/.../libdl.a -pthread -lgssapi_krb5"

$ ldd tracker
	libm.so.6 => ...
	libc.so.6 => ...
	libgssapi_krb5.so.2 => ...      (and the krb5 chain)
```

No libssh, no OpenSSL, no zlib. Kerberos remains, and that leads to the one
genuine dead end on this platform.

### Debian's libssh cannot be fully statically linked

Debian builds libssh with GSSAPI enabled, so `libssh.a` references
`gss_acquire_cred` and friends. **MIT Kerberos ships no static libraries on
Debian or Ubuntu** — `libkrb5-dev` contains not a single `.a` file:

```console
$ dpkg -L libkrb5-dev | grep '\.a$'          # nothing
$ find / -name 'libgssapi*.a' -o -name 'libkrb5*.a'   # nothing
```

So there is no way to satisfy those symbols in a `-static` link. otsh detects
this by inspecting the archive rather than guessing, and says so:

```console
$ otsh build --fully-static examples/tracker
otsh: /usr/lib/aarch64-linux-gnu/libssh.a was built with GSSAPI, and there is
      no libgssapi_krb5.a to link.
  MIT Kerberos ships no static libraries on Debian or Ubuntu ...
  Either use --static, which links krb5 dynamically and still drops the
  libssh dependency, or build libssh yourself with -DWITH_GSSAPI=OFF.
```

Build libssh yourself with GSSAPI off (see [Building libssh as an
archive](#building-libssh-as-an-archive)) and `--fully-static` works:

```console
$ PKG_CONFIG_PATH=/opt/libssh-static/lib/pkgconfig otsh build --fully-static examples/tracker
$ file tracker
ELF 64-bit LSB executable, ARM aarch64, statically linked, ...
$ ldd tracker
	not a dynamic executable
```

### The glibc static-NSS warnings are real, and harmless here

A `-static` glibc link prints warnings like:

```
warning: Using 'getaddrinfo' in statically linked applications requires at
runtime the shared libraries from the glibc version used for linking
```

They are worth understanding rather than ignoring. glibc's name resolution
loads NSS backends with `dlopen` at run time, so a statically linked binary
that resolves a *hostname* needs the matching glibc shared objects present —
which defeats the point.

**Measured: it does not affect an otsh server.** The fully static binary was
run and driven with a real ssh client over a pty; it bound its port, accepted
the connection, rendered a frame and quit on `q`. otsh binds a numeric address
and only ever calls `getpeername`/`inet_ntop` on an accepted socket, none of
which touch NSS. The warnings come from code paths in libssh's client half and
in OpenSSL's `BIO_gethostbyname` that a server never reaches.

The caveat still applies if *your* app resolves hostnames, reads `/etc/passwd`
through `getpwnam`, or does anything else NSS-backed. If it does, prefer musl.

Sizes, `examples/tracker`:

| Build | Binary | Stripped |
| --- | --- | --- |
| default (dynamic) | 784,504 | 715,992 |
| `--static` (distro libssh) | 7,940,088 | 6,956,024 |
| `--fully-static` (libssh built with GSSAPI off) | 8,379,912 | 7,224,224 |

## Linux, musl (Alpine)

This is where a genuinely static binary is most worth having, and it works —
but not from the packages.

**Alpine ships no static libssh.** `libssh-dev` contains exactly one file:

```console
$ apk info -L libssh-dev | grep -E '\.(a|so)$'
usr/lib/libssh.so
$ find / -name 'libssh.a'        # nothing
```

(`libssh2-static` exists in the repositories and is a different library.)
`openssl-libs-static` and `zlib-static` are there, so OpenSSL and zlib are
fine; libssh is the piece you have to build. otsh says so rather than handing
the linker a broken command line:

```console
$ otsh build --static examples/tracker
otsh: no libssh.a in /usr/lib — nothing to link statically.
  ...
  Alpine's libssh-dev ships only libssh.so — build libssh yourself
```

With libssh built as an archive and `PKG_CONFIG_PATH` pointed at it, both
modes work:

```console
$ export PKG_CONFIG_PATH=/opt/libssh-static/lib/pkgconfig
$ otsh build --fully-static examples/tracker
$ file tracker
ELF 64-bit LSB executable, ARM aarch64, statically linked, ...
$ ldd tracker
/lib/ld-musl-aarch64.so.1: tracker: Not a valid dynamic program
```

Sizes, `examples/tracker`, Alpine 3.22, aarch64, libssh 0.11.5 (source),
OpenSSL 3.5:

| Build | Binary | Stripped |
| --- | --- | --- |
| default (dynamic, packaged libssh 0.11.2) | 786,848 | 715,896 |
| `--static` | 15,835,232 | 5,448,120 |
| `--fully-static` | 16,194,256 | 4,923,784 |

Strip these. Alpine's toolchain keeps debug info that the Debian one does not,
which is why the raw numbers are three times the stripped ones — and why the
fully static binary is *smaller* than the partly static one once stripped, the
dynamic-linking machinery having gone with it.

### The payoff: a container with nothing in it

The reason to do any of this:

```dockerfile
FROM scratch
COPY tracker /tracker
WORKDIR /state
ENTRYPOINT ["/tracker"]
```

```console
$ docker build -t otsh-scratch . && docker run -d --tmpfs /state -p 2299:2222 otsh-scratch
$ docker logs otsh-scratch-run
otsh: generated new ed25519 host key at tracker_hostkey
otsh: listening on [::]:2222  →  ssh -p 2222 localhost
$ ssh -p 2299 localhost         # from the host, a real client, a real frame
```

That image is 7 MB and contains one file. No libssh, no OpenSSL, no libc, no
shell. It was built, run, and connected to with a real ssh client over a pty
from the host; a frame rendered and `q` quit cleanly.

## Building libssh as an archive

Needed on Alpine always, and on Debian/Ubuntu when you want `--fully-static`.
`-DWITH_GSSAPI=OFF` is the load-bearing flag — otsh never uses GSSAPI
authentication, and leaving it on is what makes a fully static link
impossible on glibc distributions:

```sh
curl -fsSLO https://www.libssh.org/files/0.11/libssh-0.11.5.tar.xz
tar -xf libssh-0.11.5.tar.xz
cmake -S libssh-0.11.5 -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/opt/libssh-static \
    -DBUILD_SHARED_LIBS=OFF \
    -DWITH_GSSAPI=OFF \
    -DWITH_EXAMPLES=OFF \
    -DUNIT_TESTING=OFF
cmake --build build -j"$(nproc)"
cmake --install build
```

Then point otsh at it. `otsh` finds libssh through pkg-config first, so the
installed `.pc` file is all it takes — no new flag:

```sh
export PKG_CONFIG_PATH=/opt/libssh-static/lib/pkgconfig
otsh build --fully-static ~/src/myapp
```

Check what it picked up before building, with `otsh flags --fully-static`.

Keep track of the version you built. This is the copy that ships inside your
binary, and nothing on the host will ever update it.

## Doing it without the otsh wrapper

`otsh flags --static` prints exactly the three flags to paste. If you would
rather assemble them yourself, the shape is:

```sh
odin build . \
    -collection:otsh=/path/to/otsh \
    -define:OTSH_LIBSSH=system:/abs/path/to/libssh.a \
    -extra-linker-flags:"/abs/path/to/libcrypto.a /abs/path/to/libz.a ..."
```

Two traps:

- **Pass archives by path, not as `-l`.** Giving the linker `-lcrypto`
  alongside `libcrypto.a` still records a dependency on `libcrypto.so.3`, and
  you get a "static" binary that loads OpenSSL dynamically anyway. This is a
  quiet failure — the build succeeds — so check `ldd` afterwards.
- **Odin accepts only one `-extra-linker-flags`.** A second is rejected with
  `Previous flag set: 'extra-linker-flags'`. `otsh build` folds any
  `-extra-linker-flags:` you pass into the one it constructs, so
  `otsh build --static ~/app -extra-linker-flags:"-lmylib"` works; a
  hand-written `odin build` command line has to merge them itself.

## Windows

`otsh build --static` refuses on Windows. vcpkg's `libssh:x64-windows` triplet
produces a DLL plus an import library — there is no static `libssh.lib` to
link against. The `x64-windows-static` triplet builds one, and the
`OTSH_LIBSSH` define would accept its path in the same way, but otsh has never
been built or run against it and this page does not claim results it does not
have. See [Compatibility](compatibility.md) for what Windows support does
rest on.

## What was not measured

- **x86_64.** Every measurement on this page is aarch64 — an Apple Silicon mac
  and arm64 containers on it. Nothing here is architecture-specific in
  principle, but the numbers would differ and the link behaviour is unverified.
- **The `x64-windows-static` vcpkg triplet**, as above.
- **Long-running static binaries.** The static builds were driven through a
  connect / render / quit cycle, not soaked. No behavioural difference from a
  dynamic build was observed in that cycle: identical frame bytes, identical
  exit.
- **libssh built against a crypto backend other than OpenSSL.** libssh can use
  mbedTLS or gcrypt; otsh has only ever been linked against the OpenSSL build,
  static or otherwise.
