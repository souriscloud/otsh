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
step "packages + default example" ./build.sh
for ex in examples/*/; do
	step "example $(basename "$ex")" ./build.sh "$ex"
done
rm -f tracker whoami members guestbook stopwatch notes
rm -f tracker.exe whoami.exe members.exe guestbook.exe stopwatch.exe notes.exe *.pdb

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
