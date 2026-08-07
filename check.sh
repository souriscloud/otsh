#!/usr/bin/env bash
# Everything CI runs, runnable locally. Exits non-zero if anything fails.
#
# This exists because ad-hoc verification lies. A chain like
#
#     ./build.sh >/dev/null 2>&1 && for ex in examples/*/; do ...; done
#     echo "all examples build"
#
# prints success even when the first command failed and the loop never ran —
# which is exactly how a broken default target survived several "verified" runs.
# Here every step is checked and the failures are counted.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
fails=0

step() {
	local name="$1"; shift
	if "$@" >/tmp/otsh_check.log 2>&1; then
		printf '  ok    %s\n' "$name"
	else
		printf '  FAIL  %s\n' "$name"
		sed 's/^/          /' /tmp/otsh_check.log | head -12
		fails=$((fails + 1))
	fi
}

echo "build"
# The otsh tool itself, first and by name: everything below goes through it,
# and "the tool does not compile" should be reported as that rather than as
# six cascading example failures. `version` is the cheapest command that
# forces the bootstrap to build cmd/otsh.
step "the otsh tool builds" ./otsh version
step "packages + default example" ./build.sh
for ex in examples/*/; do
	step "example $(basename "$ex")" ./build.sh "$ex"
done
rm -f tracker whoami members guestbook stopwatch notes
rm -f tracker.exe whoami.exe members.exe guestbook.exe stopwatch.exe notes.exe *.pdb

echo "scaffold"
# `otsh new` writes Odin source out of a shell script, and it is the first
# thing a new reader runs. Nothing else here would notice it drifting from the
# tui/sshtui API — the examples would still build fine — so scaffold one into a
# temporary directory and build it, outside the repository, the way a user
# would. A scaffold that does not compile is the worst failure this tool has.
scaffold_root="$(mktemp -d)"
step "otsh new scaffolds a project" ./otsh new "$scaffold_root/probe"
step "the scaffolded project builds" ./otsh build "$scaffold_root/probe"
rm -rf "$scaffold_root"

echo "tests"
if out=$(./test.sh 2>&1); then
	printf '  ok    %s\n' "$(echo "$out" | grep -o 'Finished [0-9]* test.*' | tail -1)"
else
	printf '  FAIL  test suite\n'
	echo "$out" | grep -E "FAIL|expected|Error" | head -12 | sed 's/^/          /'
	fails=$((fails + 1))
fi

echo "docs"
step "api reference is current" python3 docs/tools/gen_api.py --check
step "site builds and validates" python3 docs/tools/build_site.py --check
step "symbol index current, hover links resolve" python3 docs/tools/gen_symbols.py --check
step "doc code samples are real" python3 docs/tools/check_examples.py --strict

echo "bindings"
# Compares libssh/libssh.odin against the libssh headers installed here. Skips
# with exit 0 where those headers are absent — see docs/bindings.md.
step "bindings match installed libssh" python3 docs/tools/check_bindings.py --check

echo
if [ "$fails" -eq 0 ]; then
	echo "all checks passed"
else
	echo "$fails check(s) failed"
fi
exit "$fails"
