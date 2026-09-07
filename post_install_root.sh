#!/bin/bash
set -euo pipefail
set -x

# Overridable so an unattended/test run can supply them without a TTY.
USERNAME="${USERNAME:-}"
PASSWORD="${PASSWORD:-}"
PASSWORD_CONFIRM=""

INSTALLER_URL="${INSTALLER_URL:-https://raw.githubusercontent.com/gustaf-ag47/install-arch/master}"
SUDOERS="%wheel ALL=(ALL) NOPASSWD: ALL"

USER_SCRIPT="post_install_user.sh"
APPS_CSV="apps.csv"
FP_USER_SCRIPT="/tmp/$USER_SCRIPT"
FP_APPS_CSV="/tmp/$APPS_CSV"
FP_AUR_QUEUE="/tmp/aur_queue"

user_input() {
	# NB: the username loop previously had no break and used -s (silent), so it
	# spun forever reading invisible input. It was also never called from main(),
	# leaving USERNAME empty and making useradd fail with "invalid user name ''".
	while [ -z "$USERNAME" ]; do
		read -rp "Enter username: " USERNAME
	done

	while [ -z "$PASSWORD" ]; do
		read -rsp "Enter password: " PASSWORD
		echo
		read -rsp "Confirm password: " PASSWORD_CONFIRM
		echo

		if [ "$PASSWORD" != "$PASSWORD_CONFIRM" ]; then
			echo "Passwords do not match. Please try again."
			PASSWORD=""
		fi
	done
}

install_package() {
	local package=$1
	if ! pacman -S --noconfirm "$package"; then
		echo "$package" >>"$FP_AUR_QUEUE"
	fi
}

install_packages() {
	curl -fsSL "$INSTALLER_URL/$APPS_CSV" >"$FP_APPS_CSV"
	# shellcheck disable=SC2034  # category/description are positional CSV fields
	while IFS=, read -r category package description; do
		install_package "$package"
	done <$FP_APPS_CSV
}

user_and_groups() {
	if ! id "$USERNAME" &>/dev/null; then
		useradd -m -g wheel -s /bin/bash "$USERNAME"
		echo "$USERNAME:$PASSWORD" | chpasswd
	fi

	# Outside the guard on purpose. This used to sit inside it, so a re-run --
	# or any install where the user already existed -- skipped the sudoers drop
	# entirely. Everything downstream that calls sudo (set_keymap, the AUR
	# queue, docker/bluetooth/tailscale enablement) then failed with
	# "sudo: a password is required" and took the whole post-install down.
	echo "$SUDOERS" >/etc/sudoers.d/username_wheel
	chmod 0440 /etc/sudoers.d/username_wheel
	visudo -cf /etc/sudoers.d/username_wheel >/dev/null
}

change_shell() {
	chsh -s /bin/zsh "$USERNAME"
}

user() {
	curl -fsSL "$INSTALLER_URL/$USER_SCRIPT" >$FP_USER_SCRIPT
	sudo -u "$USERNAME" sh "$FP_USER_SCRIPT"
}

main() {
	user_input
	install_packages
	user_and_groups
	change_shell
	user
	cleanup
}

cleanup() {
	rm -rf $FP_APPS_CSV
	rm -rf $FP_AUR_QUEUE
	rm -rf $FP_USER_SCRIPT
}

main
