#!/bin/bash
# install-arch first boot: finish the setup on the first root login.
#
# install.sh writes /root/.firstboot.env (user, password, installer source) and a
# hook in /root/.bash_profile that runs this script. It brings the network up
# (asking for Wi-Fi in nmtui only if needed), then runs post_install_root.sh with
# that user. On success it deletes the env file (it holds a password) and the
# hook; on failure both stay, so the next root login retries.
set -uo pipefail

ENV_FILE=/root/.firstboot.env
LOG=/root/firstboot.log
PROFILE_RC=/root/.bash_profile

[ -f "$ENV_FILE" ] || exit 0
# shellcheck disable=SC1090
. "$ENV_FILE"
export USERNAME PASSWORD INSTALLER_URL
[ -n "${DOTFILES_REPO:-}" ] && export DOTFILES_REPO
[ -n "${DOTFILES_REF:-}" ] && export DOTFILES_REF

echo
echo "== install-arch first boot: finishing the setup for '$USERNAME' =="
echo "   (log: $LOG; Ctrl-C to stop, it resumes on the next root login)"

online() { curl -fsS -o /dev/null --max-time 5 https://archlinux.org/ 2>/dev/null; }

systemctl start NetworkManager 2>/dev/null
for _ in $(seq 1 15); do online && break; sleep 2; done
while ! online; do
	echo "No internet. Pick your Wi-Fi in nmtui (Activate a connection), then Quit."
	read -rp "Press Enter to open nmtui (or type 'skip' to stop for now): " ans
	[ "$ans" = skip ] && { echo "Stopped. Log in as root again to resume."; exit 1; }
	nmtui-connect || true
	for _ in $(seq 1 10); do online && break; sleep 2; done
done
echo "Network up."

script=/root/post_install_root.sh
[ -s "$script" ] || curl -fsSL "$INSTALLER_URL/post_install_root.sh" -o "$script"

bash "$script" 2>&1 | tee -a "$LOG"
rc=${PIPESTATUS[0]}
echo "FIRSTBOOT_RC=$rc"

if [ "$rc" -eq 0 ]; then
	rm -f "$ENV_FILE"
	sed -i '/# >>> install-arch firstboot/,/# <<< install-arch firstboot/d' "$PROFILE_RC"
	echo
	echo "== Setup complete. Reboot, then log in as $USERNAME. =="
	echo "   Still manual: Syncthing/Tailscale admission (see the dotfiles runbook)."
else
	echo
	echo "== Setup failed (exit $rc). Fix the cause (see $LOG) and log in as root again. =="
	echo "   $ENV_FILE (your password) stays until it succeeds; delete it to give up."
fi
exit "$rc"
