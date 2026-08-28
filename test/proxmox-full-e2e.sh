#!/bin/bash
# Single-shot E2E: blank disk -> install-arch -> reboot -> post-install ->
# dotfiles installed, with NO manual intervention between phases.
#
# Phase 0  wipe disk, restore ISO + direct-kernel boot args
# Phase 1  live ISO: run install.sh (partition/LUKS/pacstrap/chroot/GRUB)
# Phase 2  live ISO again: assert chroot artefacts, add serial+vga console
#          (test fixture), boot from disk, unlock LUKS, run post_install_root.sh
# Phase 3  assertions + screendump
#
# Harness rules (see PROXMOX.md):
#  - socat + FIFO, never expect
#  - the guest echoes what we type, so sentinels are split by a quote pair and
#    only the unquoted form is matched. In THIS file that split must live inside
#    single quotes, or bash concatenates it away before the guest sees it.
#  - `exec bash --norc --noprofile` must be sent alone (grml-zsh PS1 rewriting).
set -uo pipefail

VMID="${VMID:-990}"
# Proxmox host address. Required: set PVE_IP=<host> (no default, so this
# public repo does not carry a private LAN address).
PVE_IP="${PVE_IP:?set PVE_IP to your Proxmox host, e.g. PVE_IP=10.0.0.5}"
LOG="/tmp/${VMID}-serial.log"
FIFO="/tmp/${VMID}.in"
BASE="http://$PVE_IP:8099"
DOTFILES_REPO="${DOTFILES_REPO:-$BASE/dotfiles.git}"
ISO="local:iso/archlinux-x86_64.iso"
ISOLABEL="${ISOLABEL:-ARCH_202608}"
LUKS_PW=pass
ROOT_PW=pass
NEWUSER="${NEWUSER:-gustaf}"
NEWPW="${NEWPW:-testpass}"
INSTALL_TIMEOUT="${INSTALL_TIMEOUT:-2400}"
POST_TIMEOUT="${POST_TIMEOUT:-3600}"

say() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
send() { printf '%s\r' "$1" >&3; sleep 0.4; }
strip() { sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' -e 's/\x1b\][0-9;]*[^\x07]*\x07//g' -e 's/\r//g'; }
waitre() {
	local p=$1 s=$2 i
	for ((i = 0; i < s; i++)); do
		strip <"$LOG" | grep -qaE -- "$p" && return 0
		sleep 1
	done
	return 1
}
attach() {
	rm -f "$FIFO"
	mkfifo "$FIFO"
	socat UNIX-CONNECT:/var/run/qemu-server/"$VMID".serial0 - <"$FIFO" >>"$LOG" 2>&1 &
	SOCAT_PID=$!
	exec 3>"$FIFO"
}
detach() {
	exec 3>&- 2>/dev/null
	kill "${SOCAT_PID:-0}" 2>/dev/null
	sleep 1
}
trap detach EXIT

##############################################################################
say "PHASE 0: wiping VM $VMID's disk (genuinely blank drive)"
qm stop "$VMID" >/dev/null 2>&1
sleep 5
for d in scsi0 unused0 unused1 unused2; do
	qm disk unlink "$VMID" --idlist "$d" --force 1 >/dev/null 2>&1
done
sleep 2
qm set "$VMID" --scsi0 local-lvm:20 || exit 1
qm set "$VMID" --ide2 "$ISO,media=cdrom" --boot order=scsi0 --vga std --serial0 socket || exit 1
qm set "$VMID" --args "-kernel /var/lib/vz/template/iso/archboot/vmlinuz-linux \
-initrd /var/lib/vz/template/iso/archboot/initramfs-linux.img \
-append \"archisobasedir=arch archisolabel=$ISOLABEL console=ttyS0,115200 rw\"" || exit 1
echo "  disk re-created blank:"
qm config "$VMID" | grep -E '^(scsi0|ide2|args|vga|boot)'

##############################################################################
say "PHASE 1: booting live ISO and running the real installer"
: >"$LOG"
qm start "$VMID" || exit 1
sleep 5
attach
send ""
waitre "archiso login:" 240 || {
	echo "FAIL: no live login prompt"
	exit 1
}
send "root"
sleep 3
send "exec bash --norc --noprofile"
sleep 3
send 'echo P1_""READY'
waitre "P1_READY" 60 || {
	echo "FAIL: no shell"
	exit 1
}
echo "  live shell ready"

send 'timedatectl set-ntp true >/dev/null 2>&1; ping -c1 -W5 8.8.8.8 >/dev/null 2>&1 && echo NET_""UP || echo NET_""DOWN'
waitre "NET_UP" 90 || {
	echo "FAIL: no network in live ISO"
	exit 1
}
echo "  network up"

send "curl -fsSL -o /root/install.sh $BASE/install.sh && echo FETCH_\"\"OK || echo FETCH_\"\"FAIL"
waitre "FETCH_OK" 90 || {
	echo "FAIL: could not fetch install.sh from $BASE"
	exit 1
}
echo "  installer fetched from local working tree"

# install.sh ends with `reboot`, so `echo HARNESS_RC=$?` races systemd's
# shutdown of the serial console (it won run 1 and lost run 2). The shim makes
# reaching the reboot step a deterministic sentinel and preserves inst.log on
# the target filesystem. Accept either signal.
send "mkdir -p /root/bin && curl -fsSL -o /root/bin/reboot $BASE/test/fixtures/reboot-shim.sh && chmod +x /root/bin/reboot && echo SHIM_\"\"OK"
waitre "SHIM_OK" 60 || {
	echo "FAIL: could not install the reboot shim"
	exit 1
}
send "PATH=/root/bin:\$PATH INSTALLER_URL='$BASE' bash /root/install.sh > /root/inst.log 2>&1; echo HARNESS_\"\"RC=\$? INSTALL_\"\"FINISHED"
if waitre 'HARNESS_RC=[0-9]|INSTALLER_REACHED_REBOOT' "$INSTALL_TIMEOUT"; then
	INST_RC=$(strip <"$LOG" | grep -aoE 'HARNESS_RC=[0-9]+' | tail -1)
	say "INSTALLER COMPLETED: ${INST_RC:-reached its reboot step under set -euo pipefail}"
else
	say "PHASE 1 TIMEOUT after ${INSTALL_TIMEOUT}s"
	strip <"$LOG" | tail -40
	exit 2
fi
detach

##############################################################################
say "PHASE 2: rebooting into the live ISO to inspect the installed system"
qm stop "$VMID" >/dev/null 2>&1
sleep 5
: >"$LOG"
qm start "$VMID" || exit 1
sleep 5
attach
send ""
waitre "archiso login:" 240 || {
	echo "FAIL: no live login (phase 2)"
	exit 1
}
send "root"
sleep 3
send "exec bash --norc --noprofile"
sleep 3
send 'echo P2_""READY'
waitre "P2_READY" 60 || {
	echo "FAIL: no shell (phase 2)"
	exit 1
}

send "printf '%s' '$LUKS_PW' | cryptsetup open /dev/sda3 root -"
sleep 10
send 'mount /dev/mapper/root /mnt && mount /dev/sda1 /mnt/boot && echo MNT_""OK || echo MNT_""BAD'
waitre "MNT_OK" 90 || {
	echo "FAIL: could not mount the installed system"
	strip <"$LOG" | tail -20
	exit 1
}
echo "  installed root mounted"

# The reboot shim copied the installer's own log onto the target fs.
send 'echo ILOG_""S; tail -n 8 /mnt/root/inst.log 2>/dev/null || echo "(no inst.log preserved)"; echo ILOG_""E'
waitre 'ILOG_E' 90
strip <"$LOG" | sed -n '/^ILOG_S/,/^ILOG_E/p' | grep -v '^\s*$'

send 'echo ASSERT_""START; for f in /mnt/etc/locale.conf /mnt/etc/hostname /mnt/etc/vconsole.conf /mnt/boot/grub/grub.cfg; do [ -e "$f" ] && echo "OK   present $f" || echo "FAIL missing $f"; done; grep -q "^root:[^!*]" /mnt/etc/shadow && echo "OK   root password hash set" || echo "FAIL root password unset"; echo ASSERT_""END'
waitre "ASSERT_END" 90
strip <"$LOG" | sed -n '/^ASSERT_START/,/^ASSERT_END/p' | grep -E '^(OK|FAIL)'

# Test fixture only: the installer deliberately does not put a console= on the
# kernel cmdline, so the installed system is invisible on serial. Add tty0+ttyS0
# so we can both drive it over serial AND screendump the VGA console.
send "arch-chroot /mnt bash -c \"sed -i 's|^GRUB_CMDLINE_LINUX=\\\"|GRUB_CMDLINE_LINUX=\\\"console=tty0 console=ttyS0,115200 |' /etc/default/grub && grub-mkconfig -o /boot/grub/grub.cfg\" >/dev/null 2>&1; echo GRUB_\"\"PATCHED"
waitre "GRUB_PATCHED" 300 || {
	echo "FAIL: grub patch"
	exit 1
}
# Fixture: sudo's env_reset would drop DOTFILES_REPO before post_install_user.sh
# runs under `sudo -u $USER`, so the guest would clone GitHub master instead of
# the local working tree we are trying to test.
send "printf 'Defaults env_keep += \"DOTFILES_REPO DOTFILES_REF\"\n' > /mnt/etc/sudoers.d/e2e_env; chmod 0440 /mnt/etc/sudoers.d/e2e_env; echo SUDOERS_\"\"OK"
waitre "SUDOERS_OK" 60
send 'umount -R /mnt; cryptsetup close root; sync; echo CLEAN_""DONE'
waitre "CLEAN_DONE" 90
echo "  fixtures applied, unmounted"
detach

##############################################################################
say "PHASE 2b: booting the INSTALLED system from disk"
qm stop "$VMID" >/dev/null 2>&1
sleep 5
qm set "$VMID" --delete args >/dev/null 2>&1
qm set "$VMID" --delete ide2 >/dev/null 2>&1
qm set "$VMID" --boot order=scsi0 --vga std >/dev/null 2>&1
: >"$LOG"
qm start "$VMID" || exit 1
sleep 6
attach

waitre "Enter passphrase" 240 || {
	echo "FAIL: no LUKS prompt from the installed system"
	strip <"$LOG" | tail -30
	exit 1
}
echo "  OK   LUKS passphrase prompt appeared"
send "$LUKS_PW"
waitre "arch login:" 300 || {
	echo "FAIL: LUKS unlock / boot to userspace"
	strip <"$LOG" | tail -30
	exit 1
}
echo "  OK   LUKS unlock succeeded, reached 'arch login:'"

send "root"
sleep 2
send "$ROOT_PW"
sleep 5
send "exec bash --norc --noprofile"
sleep 3
send 'echo INST_""READY'
waitre "INST_READY" 90 || {
	echo "FAIL: root login on installed system"
	exit 1
}
echo "  OK   root login works (root password really was set)"

send 'systemctl start NetworkManager >/dev/null 2>&1; sleep 8; ping -c1 -W5 8.8.8.8 >/dev/null 2>&1 && echo PNET_""UP || echo PNET_""DOWN'
waitre "PNET_UP" 120 || {
	echo "FAIL: no network on the installed system"
	exit 1
}
echo "  network up"

##############################################################################
say "PHASE 3: post_install_root.sh -> post_install_user.sh -> dotfiles"
send "curl -fsSL -o /root/pir.sh $BASE/post_install_root.sh && echo PIR_\"\"FETCHED"
waitre "PIR_FETCHED" 90 || {
	echo "FAIL: fetch post_install_root.sh"
	exit 1
}
# `yes n |`: bootstrap_sync() in post_install_user.sh ends with an interactive
# `read -p "Run Syncthing bootstrap now?"`. Unattended, answer no.
send "yes n | env USERNAME=$NEWUSER PASSWORD=$NEWPW INSTALLER_URL=$BASE DOTFILES_REPO=$DOTFILES_REPO bash /root/pir.sh > /root/pir.log 2>&1; echo PIR_\"\"RC=\$? PIR_\"\"FINISHED"
if waitre 'PIR_RC=[0-9]' "$POST_TIMEOUT"; then
	PIR_RC=$(strip <"$LOG" | grep -aoE 'PIR_RC=[0-9]+' | tail -1)
	say "post_install_root.sh RETURNED: $PIR_RC"
else
	say "PHASE 3 TIMEOUT after ${POST_TIMEOUT}s - progress:"
	send 'echo Q_""S; tail -n 25 /root/pir.log; echo Q_""E'
	waitre 'Q_E' 90
	strip <"$LOG" | sed -n '/^Q_S/,/^Q_E/p'
	exit 2
fi
send 'echo LG_""S; tail -n 25 /root/pir.log; echo LG_""E'
waitre 'LG_E' 120
strip <"$LOG" | sed -n '/^LG_S/,/^LG_E/p' | grep -v '^\s*$'

say "FINAL ASSERTIONS"
send "echo A_\"\"S; \
id $NEWUSER >/dev/null 2>&1 && echo 'OK   user $NEWUSER exists' || echo 'FAIL user missing'; \
getent passwd $NEWUSER | grep -q zsh && echo 'OK   login shell is zsh' || echo 'FAIL login shell not zsh'; \
[ -d /home/$NEWUSER/sync/src/dotfiles ] && echo 'OK   dotfiles tree at \$DOTFILES' || echo 'FAIL no dotfiles tree'; \
[ -L /home/$NEWUSER/.zshenv ] && echo 'OK   ~/.zshenv symlink' || echo 'FAIL .zshenv symlink'; \
[ -L /home/$NEWUSER/.config/nvim ] && echo 'OK   ~/.config/nvim symlink' || echo 'FAIL nvim symlink'; \
[ -L /home/$NEWUSER/.config/tmux ] && echo 'OK   ~/.config/tmux symlink' || echo 'FAIL tmux symlink'; \
[ -L /home/$NEWUSER/.config/hypr ] && echo 'OK   ~/.config/hypr symlink' || echo 'FAIL hypr symlink'; \
[ -L /home/$NEWUSER/.local/bin/git-setup-hooks ] && echo 'OK   ~/.local/bin/git-setup-hooks symlink' || echo 'FAIL bin symlink'; \
[ -d /home/$NEWUSER/.config/zsh/plugins/zsh-autosuggestions ] && echo 'OK   zsh plugins cloned' || echo 'FAIL zsh plugins'; \
[ -f /home/$NEWUSER/.config/tmux/tmux.conf ] && echo 'OK   tmux.conf resolves' || echo 'FAIL tmux.conf'; \
n=\$(find /home/$NEWUSER/.config -maxdepth 2 -xtype l 2>/dev/null | wc -l); [ \"\$n\" = 0 ] && echo 'OK   0 broken symlinks' || echo \"FAIL \$n broken symlinks\"; \
find /home/$NEWUSER/.config -maxdepth 2 -xtype l 2>/dev/null; \
echo 'INFO dotfiles HEAD:' \$(git -C /home/$NEWUSER/sync/src/dotfiles log --oneline -1 2>&1); \
echo A_\"\"E"
waitre 'A_E' 240
strip <"$LOG" | sed -n '/^A_S/,/^A_E/p' | grep -E '^(OK|FAIL|INFO|/home)'

##############################################################################
say "PHASE 4: logging in on tty1 for a VGA screendump"
detach
sleep 1
for k in g u s t a f ret; do echo "sendkey $k" | qm monitor "$VMID" >/dev/null; sleep 0.3; done
sleep 1
for k in t e s t p a s s ret; do echo "sendkey $k" | qm monitor "$VMID" >/dev/null; sleep 0.3; done
sleep 6
for k in l s space minus a space dot z s h e n v ret; do echo "sendkey $k" | qm monitor "$VMID" >/dev/null; sleep 0.25; done
sleep 3
rm -f /tmp/arch-e2e-final.ppm
echo "screendump /tmp/arch-e2e-final.ppm" | qm monitor "$VMID" >/dev/null
sleep 3
ls -la /tmp/arch-e2e-final.ppm

say "DONE"
