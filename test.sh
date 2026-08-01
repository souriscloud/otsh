#!/usr/bin/env bash
# Runs the Odin test suite. Same libssh discovery as build.sh.
#
#   ./test.sh              run everything
#   ./test.sh -define:ODIN_TEST_NAMES=otsh_tests.session_stays_small
set -euo pipefail

OTSH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Same compiler resolution as build.sh: $ODIN, then .odin-path if it resolves,
# then PATH. See the comment there for why the "if it resolves" matters.
if [ -z "${ODIN:-}" ] && [ -f "$OTSH/.odin-path" ]; then
	odin_path="$(cat "$OTSH/.odin-path")"
	if command -v "$odin_path" >/dev/null; then
		ODIN="$odin_path"
	fi
fi
ODIN="${ODIN:-odin}"
if ! command -v "$ODIN" >/dev/null; then
	echo "test.sh: odin compiler not found (tried '$ODIN')." >&2
	echo "  Install Odin (https://odin-lang.org), set ODIN=/path/to/odin, or write" >&2
	echo "  the path into $OTSH/.odin-path" >&2
	exit 1
fi

case "$(uname -s)" in
MINGW*|MSYS*|CYGWIN*)
	# See the same branch in build.sh: vcpkg, /LIBPATH:, no rpath. Ran by hand
	# on Windows 11 on 2026-07-31 (67 tests pass; the four Linux-only ones are
	# skipped there); the hosted CI windows job has still never run.
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

exec "$ODIN" test "$OTSH/tests" \
	-collection:otsh="$OTSH" \
	-extra-linker-flags:"${LDFLAGS}" \
	"$@"
