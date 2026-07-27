#!/usr/bin/env bash
# Runs the Odin test suite. Same libssh discovery as build.sh.
#
#   ./test.sh              run everything
#   ./test.sh -define:ODIN_TEST_NAMES=otsh_tests.ring_wraps_around
set -euo pipefail

OTSH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ODIN="${ODIN:-odin}"
command -v "$ODIN" >/dev/null || ODIN=/Users/souris/work/bench/odin/odin-lang/odin

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
