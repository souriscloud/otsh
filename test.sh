#!/usr/bin/env bash
# Runs the Odin test suite. Same libssh discovery as build.sh.
#
#   ./test.sh              run everything
#   ./test.sh -define:ODIN_TEST_NAMES=otsh_tests.ring_wraps_around
set -euo pipefail

OTSH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Same compiler resolution as build.sh: $ODIN, then .odin-path, then PATH.
if [ -z "${ODIN:-}" ] && [ -f "$OTSH/.odin-path" ]; then
	ODIN="$(cat "$OTSH/.odin-path")"
fi
ODIN="${ODIN:-odin}"
if ! command -v "$ODIN" >/dev/null; then
	echo "test.sh: odin compiler not found (tried '$ODIN')." >&2
	echo "  Install Odin (https://odin-lang.org), set ODIN=/path/to/odin, or write" >&2
	echo "  the path into $OTSH/.odin-path" >&2
	exit 1
fi

if command -v pkg-config >/dev/null && pkg-config --exists libssh; then
	LIBDIR="$(pkg-config --variable=libdir libssh)"
elif [ -d /opt/homebrew/opt/libssh/lib ]; then
	LIBDIR="/opt/homebrew/opt/libssh/lib"
else
	LIBDIR="/usr/local/lib"
fi

exec "$ODIN" test "$OTSH/tests" \
	-collection:otsh="$OTSH" \
	-extra-linker-flags:"-L${LIBDIR} -Wl,-rpath,${LIBDIR}" \
	"$@"
