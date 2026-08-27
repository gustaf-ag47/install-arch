#!/bin/bash
# Runs as root inside archlinux:latest. Prepares a fresh user, deploys the
# dotfiles working tree (mounted at /src) exactly like a fresh clone, runs
# `make install`, then drops to the tester user to run assertions.
set -euo pipefail

echo "== [container] pacman bootstrap =="
pacman -Syu --noconfirm --needed \
	base-devel git rsync zsh tmux neovim curl fzf sudo python jq >/dev/null

echo "== [container] create tester user =="
id tester >/dev/null 2>&1 || useradd -m -G wheel tester
echo 'tester ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/tester
chmod 0440 /etc/sudoers.d/tester

echo "== [container] deploy dotfiles working tree to tester HOME =="
install -d -o tester -g tester /home/tester/sync/src
rsync -a --delete \
	--exclude '.git' --exclude 'node_modules' --exclude 'local' \
	/src/ /home/tester/sync/src/dotfiles/
chown -R tester:tester /home/tester/sync

# Fake, non-secret token file so token-layer assertions have something to read.
install -o tester -g tester -m 600 /test/fixtures/cctoken.fake /home/tester/cctoken

echo "== [container] run make install as tester =="
su - tester -c 'cd ~/sync/src/dotfiles && make install' || {
	echo "make install returned non-zero (expected for systemctl --user in a container)"; }

echo "== [container] install/symlink assertions =="
su - tester -c 'bash /test/assertions.sh'
rc_install=$?

echo "== [container] token rotation logic =="
su - tester -c 'CC_PROXY_PATH=$HOME/sync/src/dotfiles/bin/claude-token-proxy python3 /test/token-rotation-test.py'
rc_rot=$?

exit $(( rc_install || rc_rot ))
