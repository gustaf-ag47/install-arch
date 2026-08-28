#!/bin/bash
# Post-install E2E assertions, run as the tester user inside the container.
# Exits non-zero if any assertion fails.
set -uo pipefail

PASS=0
FAIL=0
DOT="$HOME/sync/src/dotfiles"

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

is_link_into_dot() { # $1 = path that should be a symlink pointing inside $DOT
	local tgt
	[ -L "$1" ] || { bad "symlink missing: $1"; return; }
	tgt="$(readlink -f "$1")"
	case "$tgt" in
		"$DOT"/*) ok "symlink $1 -> $tgt" ;;
		*) bad "symlink $1 points outside dotfiles: $tgt" ;;
	esac
}

exists_exec() { [ -x "$1" ] && ok "executable present: $1" || bad "missing/!exec: $1"; }

echo "--- symlinks ---"
is_link_into_dot "$HOME/.zshenv"
is_link_into_dot "$HOME/.config/zsh/.zshrc"
is_link_into_dot "$HOME/.config/nvim"
is_link_into_dot "$HOME/.config/tmux"
is_link_into_dot "$HOME/.config/git"
is_link_into_dot "$HOME/.config/claude-code/env.sh"
is_link_into_dot "$HOME/.config/systemd/user/claude-token-proxy.service"

echo "--- bin symlinks into ~/.local/bin ---"
exists_exec "$HOME/.local/bin/pi-claude-sub"
exists_exec "$HOME/.local/bin/claude-token-proxy"
exists_exec "$HOME/.local/bin/claude-token-refresh"
exists_exec "$HOME/.local/bin/cctoken-from-pass"

echo "--- zsh plugins cloned ---"
[ -d "$HOME/.config/zsh/plugins/zsh-syntax-highlighting" ] && ok "zsh-syntax-highlighting cloned" || bad "zsh-syntax-highlighting missing"
[ -d "$HOME/.config/zsh/plugins/zsh-autosuggestions" ] && ok "zsh-autosuggestions cloned" || bad "zsh-autosuggestions missing"

echo "--- env resolves in a real zsh ---"
GOT_DOT="$(zsh -ic 'printf %s "$DOTFILES"' 2>/dev/null)"
[ "$GOT_DOT" = "$DOT" ] && ok "\$DOTFILES resolves to $GOT_DOT" || bad "\$DOTFILES was '$GOT_DOT' (want $DOT)"
GOT_PATH="$(zsh -ic 'case ":$PATH:" in *:$HOME/.local/bin:*) echo yes;; *) echo no;; esac' 2>/dev/null)"
[ "$GOT_PATH" = yes ] && ok "local/bin on PATH" || bad "local/bin not on PATH"

echo "--- token layer wiring ---"
grep -q 'CCTOKEN_FILE' "$HOME/.local/bin/claude-token-refresh" && ok "token-refresh reads CCTOKEN_FILE" || bad "token-refresh missing CCTOKEN_FILE"
# extract_tokens should find BOTH fake tokens from the fixture (order-independent).
N="$(awk -F= '/^export (CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_OAUTH_TOKEN)=/{c++} END{print c+0}' "$HOME/cctoken")"
[ "$N" = 2 ] && ok "cctoken exposes 2 accounts" || bad "expected 2 accounts in cctoken, got $N"

echo
echo "==================== E2E SUMMARY ===================="
printf 'PASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
