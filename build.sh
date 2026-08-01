#!/usr/bin/env bash
# Builds an app against the otsh packages.
#
#   ./build.sh                      # builds examples/tracker -> ./tracker
#   ./build.sh path/to/yourapp      # builds your app  -> ./<dirname>
#
# To build from your own project instead, copy the two flags below:
#   -collection:otsh=/path/to/otsh
#   -extra-linker-flags:"-L<libssh libdir> -Wl,-rpath,<libssh libdir>"
set -euo pipefail

OTSH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Compiler resolution: $ODIN if set, else a gitignored .odin-path file next to
# this script (for machines where the compiler is not on PATH), else `odin`.
# .odin-path is only taken when it actually resolves: one checkout can be seen
# by two machines at once — a container with the worktree bind-mounted in, for
# instance — and a path written on the other one must not shadow a perfectly
# good `odin` on this one's $PATH.
if [ -z "${ODIN:-}" ] && [ -f "$OTSH/.odin-path" ]; then
	odin_path="$(cat "$OTSH/.odin-path")"
	if command -v "$odin_path" >/dev/null; then
		ODIN="$odin_path"
	fi
fi
ODIN="${ODIN:-odin}"
if ! command -v "$ODIN" >/dev/null; then
	echo "build.sh: odin compiler not found (tried '$ODIN')." >&2
	echo "  Install Odin (https://odin-lang.org), set ODIN=/path/to/odin, or write" >&2
	echo "  the path into $OTSH/.odin-path" >&2
	exit 1
fi

SRC="${1:-$OTSH/examples/tracker}"
shift || true
OUT="$(basename "$SRC")"

if [ ! -d "$SRC" ]; then
	echo "build.sh: no such package directory: $SRC" >&2
	echo "  usage: ./build.sh [path/to/package]   (default: examples/tracker)" >&2
	exit 1
fi

# libssh is not on the default linker search path on macOS/Homebrew, and on
# Windows it is not on any path at all.
case "$(uname -s)" in
MINGW*|MSYS*|CYGWIN*)
	# This branch exists so CI and Git Bash on Windows can run the same script.
	# It built every package and all five examples by hand on Windows 11 with
	# vcpkg libssh 0.12.0 on 2026-07-31; the hosted CI windows job itself has
	# still never run. vcpkg is the expected libssh provider on Windows, and the
	# MSVC linker spells a library search path /LIBPATH:, not -L. There is no
	# rpath equivalent — ssh.dll has to be on %PATH% at run time.
	VCPKG="${VCPKG_ROOT:-${VCPKG_INSTALLATION_ROOT:-C:/vcpkg}}"
	LIBDIR="${VCPKG}/installed/x64-windows/lib"
	LDFLAGS="/LIBPATH:${LIBDIR}"
	# Odin refuses an -out: without a recognised extension on Windows:
	#   Output path C:/otsh-ci/otsh/tracker must have an appropriate extension.
	# basename gives an extensionless name, so add the one Windows wants.
	OUT="${OUT}.exe"
	;;
*)
	if command -v pkg-config >/dev/null && pkg-config --exists libssh; then
		LIBDIR="$(pkg-config --variable=libdir libssh)"
	elif [ -d /opt/homebrew/opt/libssh/lib ]; then
		LIBDIR="/opt/homebrew/opt/libssh/lib"
	else
		LIBDIR="/usr/local/lib"
	fi
	LDFLAGS="-L${LIBDIR} -Wl,-rpath,${LIBDIR}"
	;;
esac

exec "$ODIN" build "$SRC" \
	-out:"$OUT" \
	-collection:otsh="$OTSH" \
	-extra-linker-flags:"${LDFLAGS}" \
	"$@"
