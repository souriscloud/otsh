#!/bin/sh
# Builds an app against the otsh packages, dropping the binary in the current
# directory. Unchanged in what it does; it is now a wrapper.
#
#   ./build.sh                      # builds examples/tracker -> ./tracker
#   ./build.sh path/to/yourapp      # builds your app  -> ./<dirname>
#
# The compiler and libssh are located by ./otsh, which is the one entry point
# these packages have — `./otsh build path/to/yourapp` is the same build with
# the binary left beside its source instead, and `./otsh flags` prints the two
# flags to paste into a Makefile or an IDE. This file stays because CI, the
# docs and a decade of muscle memory all type `./build.sh`, and because "build
# it into the directory I am standing in" is still the right default from
# inside this repo. /bin/sh rather than bash for the same reason ./otsh is:
# this has to run on machines where bash does not exist.
set -eu

OTSH="$(CDPATH='' cd -P "$(dirname "$0")" && pwd)"

SRC="${1:-$OTSH/examples/tracker}"
if [ "$#" -gt 0 ]; then shift; fi

# --out-dir "$PWD" keeps the historical output location: check.sh and CI both
# `rm -f tracker whoami ...` from the repository root afterwards. OTSH_PROG
# makes otsh's diagnostics say "build.sh", which is what the caller actually
# ran; OTSH_QUIET keeps this script's output exactly the compiler's, as it has
# always been.
export OTSH_PROG=build.sh OTSH_QUIET=1
exec "$OTSH/otsh" build --out-dir "$PWD" "$SRC" "$@"
