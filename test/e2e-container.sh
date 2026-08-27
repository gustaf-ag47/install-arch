#!/bin/bash
# Local E2E: run the REAL dotfiles `make install` on a fresh archlinux:latest
# container against the CURRENT working tree (not GitHub master), then assert.
#
# Usage: install-arch/test/e2e-container.sh [--image archlinux:latest]
set -euo pipefail

IMAGE="archlinux:latest"
[ "${1:-}" = "--image" ] && { IMAGE="$2"; shift 2; }

TESTDIR="$(cd "$(dirname "$0")" && pwd)"
DOTFILES_SRC="${DOTFILES:-$HOME/sync/src/dotfiles}"

[ -d "$DOTFILES_SRC" ] || { echo "dotfiles not found at $DOTFILES_SRC (set \$DOTFILES)"; exit 1; }
command -v docker >/dev/null || { echo "docker required"; exit 1; }

echo "== E2E: image=$IMAGE  dotfiles=$DOTFILES_SRC =="
exec docker run --rm \
	-v "$DOTFILES_SRC:/src:ro" \
	-v "$TESTDIR:/test:ro" \
	"$IMAGE" \
	bash /test/in-container.sh
