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
if [ -z "${ODIN:-}" ] && [ -f "$OTSH/.odin-path" ]; then
	ODIN="$(cat "$OTSH/.odin-path")"
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
	# EXPERIMENTAL, and the only reason this branch exists is so CI can run the
	# same script: vcpkg is the expected libssh provider on Windows, and the
	# MSVC linker spells a library search path /LIBPATH:, not -L. There is no
	# rpath equivalent — ssh.dll has to be on %PATH% at run time.
	VCPKG="${VCPKG_ROOT:-${VCPKG_INSTALLATION_ROOT:-C:/vcpkg}}"
	LIBDIR="${VCPKG}/installed/x64-windows/lib"
	LDFLAGS="/LIBPATH:${LIBDIR}"
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
