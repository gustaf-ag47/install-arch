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
	git clone https://github.com/cl4irv0yant/dotfiles.git >"$HOME"

	cd "$HOME/dotfiles"
	make install

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

	source "$ZDOTDIR/.zshrc"

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
	install_python
	process_aur_queue
	install_bluetooth
	install_python
	install_docker
	install_tailscale
	install_node
}

main
