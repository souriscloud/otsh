#!/usr/bin/env bash
# Runs the Odin test suite. Same compiler and libssh discovery as build.sh,
# because both now go through ./otsh, which owns it.
#
#   ./test.sh              run everything
#   ./test.sh -define:ODIN_TEST_NAMES=otsh_tests.session_stays_small
#
# `./otsh test path/to/yourpackage` runs someone else's tests the same way.
set -euo pipefail

OTSH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export OTSH_PROG=test.sh
exec "$OTSH/otsh" test "$OTSH/tests" "$@"
