#!/bin/bash

set -euo pipefail
set -x

process_aur_queue() {
	aur_install() {
		echo "Installing $1 from AUR"
		curl -O "https://aur.archlinux.org/cgit/aur.git/snapshot/$1.tar.gz" &&
			tar -xvf "$1.tar.gz" &&
			cd "$1" &&
			makepkg --noconfirm -si &&
			cd - &&
			rm -rf "$1" "$1.tar.gz"
	}

	aur_check() {
		qm=$(pacman -Qm | awk '{print $1}')
		for arg in "$@"; do
			if [[ $qm != *"$arg"* ]]; then
				paru --noconfirm -S "$arg" &>>/tmp/aur_install ||
					aur_install "$arg" &>>/tmp/aur_install
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

bootstrap_sync() {
	# Bootstrap Syncthing with YubiKey-encrypted config
	# This sets up sync with existing machines
	cd "$HOME/dotfiles"

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
	curl https://pyenv.run | bash

	# Do NOT source the zsh rc here: this is bash under `set -euo pipefail`, and
	# .zshrc references zsh-only vars (fpath) plus $ZDOTDIR, which is unset in a
	# non-login bash shell -- `set -u` then aborts the whole post-install run.
	export PYENV_ROOT="$HOME/.pyenv"
	export PATH="$PYENV_ROOT/bin:$PATH"
	eval "$(pyenv init -)"

	pyenv install 3.11
	pyenv global 3.11

	curl -sSL https://install.python-poetry.org | python3 -
}

install_node() {
	curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir "./.fnm" --skip-shell
}

main() {
	install_dotfiles
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
