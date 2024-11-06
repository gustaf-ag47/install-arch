#!/bin/bash
set -euo pipefail
set -x

USERNAME=""
PASSWORD=""
PASSWORD_CONFIRM=""

INSTALLER_URL="https://raw.githubusercontent.com/gustaf-ag47/install-arch/master"
SUDOERS="%wheel ALL=(ALL) NOPASSWD: ALL"

USER_SCRIPT="post_install_user.sh"
APPS_CSV="apps.csv"
FP_USER_SCRIPT="/tmp/$USER_SCRIPT"
FP_APPS_CSV="/tmp/$APPS_CSV"
FP_AUR_QUEUE="/tmp/aur_queue"

user_input() {
	if [ -z "$USERNAME" ]; then
		while true; do
			read -rsp "Enter username: " USERNAME
		done
	fi

	if [ -z "$PASSWORD" ]; then
		while true; do
			read -rsp "Enter password: " PASSWORD
			echo
			read -rsp "Confirm password: " PASSWORD_CONFIRM
			echo

			if [ "$PASSWORD" = "$PASSWORD_CONFIRM" ]; then
				break
			else
				echo "Passwords do not match. Please try again."
			fi
		done
	fi
}

install_package() {
	local package=$1
	if ! pacman -S --noconfirm "$package"; then
		echo "$package" >>"$FP_AUR_QUEUE"
	fi
}

install_packages() {
	curl "$INSTALLER_URL/$APPS_CSV" >"$FP_APPS_CSV"
	while IFS=, read -r category package description; do
		install_package "$package"
	done <$FP_APPS_CSV
}

user_and_groups() {
	if ! id "$USERNAME" &>/dev/null; then
		useradd -m -g wheel -s /bin/bash "$USERNAME"
		echo "$USERNAME:$PASSWORD" | chpasswd
		echo "$SUDOERS" >/etc/sudoers.d/username_wheel
	fi
}

change_shell() {
	chsh -s /bin/zsh "$USERNAME"
}

user() {
	curl "$INSTALLER_URL/$USER_SCRIPT" >$FP_USER_SCRIPT
	sudo -u "$USERNAME" sh "$FP_USER_SCRIPT"
}

main() {
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
