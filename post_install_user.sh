#!/bin/bash

set -euo pipefail
set -x

process_aur_queue() {
	# Subshell: a failed build leaves the cwd inside the extracted package dir
	# (`cd -` never runs), which then breaks every later package.
	aur_install() (
		echo "Installing $1 from AUR"
		# -f matters: a name that is in neither the repos nor the AUR (e.g. a
		# typo, or "nvidia", which pacman could not find) returns a 404 HTML
		# page. Without -f curl happily writes it to $1.tar.gz and tar dies with
		# "gzip: stdin: not in gzip format" -- the same 404-as-payload bug that
		# once produced a system with no bootloader.
		curl -fsSL -O "https://aur.archlinux.org/cgit/aur.git/snapshot/$1.tar.gz" &&
			tar -xvf "$1.tar.gz" &&
			cd "$1" &&
			makepkg --noconfirm -si &&
			cd - &&
			rm -rf "$1" "$1.tar.gz"
	)

	aur_check() {
		qm=$(pacman -Qm | awk '{print $1}')
		for arg in "$@"; do
			if [[ $qm != *"$arg"* ]]; then
				# One unresolvable package must not abort the whole post-install.
				# This runs under `set -e`, so before the trailing `|| echo` a
				# single bad entry in apps.csv killed everything after it:
				# no bluetooth, no docker, no tailscale, no pyenv, no node.
				paru --noconfirm -S "$arg" &>>/tmp/aur_install ||
					aur_install "$arg" &>>/tmp/aur_install ||
					echo "warning: skipping $arg (not in the repos or the AUR)" >&2
			fi
		done
	}

	install_paru() {
		if ! pacman -Qs paru >/dev/null; then
			cd /tmp && aur_install paru-bin
		fi
	}

	install_aur_queue() {
		cat /tmp/aur_queue | while read -r line; do
			aur_check "$line"
		done
	}

	install_paru
	install_aur_queue
}

set_keymap() {
	sudo localectl set-x11-keymap se
}

install_dotfiles() {
	# Pinnable so a test run (or a rollback) can install a known ref instead of
	# whatever master happens to be.
	git clone --branch "${DOTFILES_REF:-master}" \
		"${DOTFILES_REPO:-https://github.com/gustaf-ag47/dotfiles.git}" "$HOME/dotfiles"

	cd "$HOME/dotfiles"
	make install
}

# `make install` rsyncs the clone to $DOTFILES (~/sync/src/dotfiles) and then
# deletes the original ~/dotfiles, so anything that later assumes ~/dotfiles is
# cd'ing into a directory that no longer exists.
dotfiles_dir() {
	if [ -d "$HOME/sync/src/dotfiles" ]; then
		echo "$HOME/sync/src/dotfiles"
	else
		echo "$HOME/dotfiles"
	fi
}

bootstrap_sync() {
	# Bootstrap Syncthing with YubiKey-encrypted config
	# This sets up sync with existing machines
	cd "$(dotfiles_dir)"

	if [ -f "./scripts/bootstrap-sync.sh" ]; then
		echo ""
		echo "=== Syncthing Bootstrap ==="
		echo "This will set up sync with your existing machines."
		echo "You'll need your YubiKey if you have encrypted config."
		echo ""
		read -p "Run Syncthing bootstrap now? [Y/n] " -n 1 -r
		echo
		if [[ ! $REPLY =~ ^[Nn]$ ]]; then
			./scripts/bootstrap-sync.sh
		else
			echo "Skipped. Run later with: ~/dotfiles/scripts/bootstrap-sync.sh"
		fi
	fi
}

install_bluetooth() {
	sudo systemctl enable bluetooth.service
	sudo systemctl start bluetooth.service
}

install_docker() {
	sudo systemctl enable docker
	sudo systemctl start docker
	sudo usermod -aG docker "$(whoami)"
}

install_tailscale() {
	sudo systemctl enable tailscaled
	sudo systemctl start tailscaled
}

install_python() {
	curl -fsSL https://pyenv.run | bash

	# Do NOT source the zsh rc here: this is bash under `set -euo pipefail`, and
	# .zshrc references zsh-only vars (fpath) plus $ZDOTDIR, which is unset in a
	# non-login bash shell -- `set -u` then aborts the whole post-install run.
	export PYENV_ROOT="$HOME/.pyenv"
	export PATH="$PYENV_ROOT/bin:$PATH"
	eval "$(pyenv init -)"

	pyenv install 3.11
	pyenv global 3.11

	curl -fsSL https://install.python-poetry.org | python3 -
}

install_node() {
	curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir "./.fnm" --skip-shell
}

enable_smartcard() {
	# age-plugin-yubikey talks to the key over PC/SC. The pcsclite package ships
	# pcscd.socket DISABLED by default on Arch, so on a fresh machine the plugin
	# finds no reader, the yubikey adapter fails, and the bootstrap kit is
	# silently skipped. Enable the socket before anything needs the key.
	sudo systemctl enable --now pcscd.socket 2>/dev/null || true
}

restore_bootstrap_kit() {
	# Tier 0: decrypt the committed bootstrap kit and place the machine identity
	# (Syncthing cert/key/config, SSH keys, tokens) before anything that needs
	# them. Everything else arrives afterwards via Syncthing.
	#
	# Unlocking is a port with swappable adapters (see dotfiles bin/bootstrap-kit):
	# a YubiKey in production, a plain age identity file in tests. Selection is
	# automatic, so nothing here changes when the adapter changes.
	local kit_bin="$HOME/.local/bin/bootstrap-kit"
	local kit="${BOOTSTRAP_KIT:-$HOME/sync/src/dotfiles/secrets/bootstrap.tar.age}"

	if [ ! -x "$kit_bin" ]; then
		echo "bootstrap-kit not installed, skipping identity restore"
		return 0
	fi
	if [ ! -f "$kit" ]; then
		echo "no bootstrap kit at $kit, skipping identity restore"
		return 0
	fi

	sudo pacman -S --noconfirm --needed age >/dev/null 2>&1 || true

	# Prove the available adapter can actually open the kit before touching the
	# filesystem, so a missing YubiKey fails loudly here rather than halfway
	# through placing files.
	if ! "$kit_bin" verify "$kit"; then
		echo "WARNING: no adapter can decrypt the bootstrap kit; skipping restore" >&2
		echo "  plug in your YubiKey, or set BOOTSTRAP_ADAPTER/BOOTSTRAP_FILE_IDENTITY" >&2
		return 0
	fi

	"$kit_bin" restore "$kit"
}

main() {
	install_dotfiles
	enable_smartcard
	restore_bootstrap_kit
	set_keymap
	process_aur_queue
	install_bluetooth
	install_docker
	install_tailscale
	install_python
	install_node

	# Last step: bootstrap sync with existing machines
	bootstrap_sync
}

main
