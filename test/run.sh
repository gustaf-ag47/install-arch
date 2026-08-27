#!/bin/bash
# Top-level local E2E runner. Layers:
#   L0 lint      - bash -n + shellcheck (if present) on installer + dotfiles scripts
#   L1 rotation  - pure-logic account-rotation test (fast, host python)
#   L2 container - real `make install` on archlinux:latest + assertions
#
# Usage: install-arch/test/run.sh [--no-container]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DOT="${DOTFILES:-$HOME/sync/src/dotfiles}"
ARCH="$(cd "$HERE/.." && pwd)"
NO_CONTAINER=0
[ "${1:-}" = "--no-container" ] && NO_CONTAINER=1

rc=0
line() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

line "L0 lint: bash -n"
for f in "$ARCH"/*.sh "$ARCH"/test/*.sh "$DOT"/scripts/*.sh "$DOT"/bin/pi-claude-sub \
         "$DOT"/bin/claude-token-refresh "$DOT"/bin/cctoken-from-pass; do
	[ -f "$f" ] || continue
	if bash -n "$f" 2>/dev/null; then echo "  ok   $f"; else echo "  FAIL $f"; rc=1; fi
done

if command -v shellcheck >/dev/null 2>&1; then
	line "L0 lint: shellcheck (warnings non-fatal)"
	shellcheck -S error "$ARCH"/*.sh "$HERE"/*.sh 2>&1 | head -40 || true
else
	echo "  (shellcheck not installed - skipping strict lint)"
fi

line "L1 rotation logic"
python3 "$HERE/token-rotation-test.py" || rc=1

if [ "$NO_CONTAINER" -eq 1 ]; then
	echo "(skipping L2 container per --no-container)"
else
	line "L2 container E2E (real make install on archlinux:latest)"
	if command -v docker >/dev/null 2>&1; then
		"$HERE/e2e-container.sh" || rc=1
	else
		echo "  docker not available - skipping L2"
	fi
fi

line "RESULT"
[ "$rc" -eq 0 ] && echo "ALL LAYERS PASSED" || echo "FAILURES ABOVE"
exit "$rc"
