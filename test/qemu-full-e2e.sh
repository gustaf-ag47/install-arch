#!/bin/bash
# L3 full-metal E2E on a LOCAL KVM host: the real one-shot install, end to end.
#
#   curl .../install.sh | PROFILE=<p> bash   (answers the /dev/tty prompts)
#   -> reboot -> LUKS unlock -> first root login runs firstboot.sh
#   -> post_install_root.sh -> dotfiles -> system layer -> reboot again
#
# Port of proxmox-full-e2e.sh to plain QEMU (OVMF, Secure Boot off, NVMe disk so
# the guest sees /dev/nvme0n1 exactly like the laptops). Serves THIS working tree
# and the dotfiles working tree over HTTP, so unpushed code is what gets tested.
# Never touches a host block device: the disk is a throwaway qcow2.
#
# Usage: ISO=~/Downloads/archlinux-YYYY.MM.DD-x86_64.iso test/qemu-full-e2e.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOTFILES_SRC="${DOTFILES_SRC:-$HOME/sync/src/dotfiles}"
ISO="${ISO:?set ISO to a verified Arch ISO}"
WORK="${VM_WORK:-/var/tmp/arch-e2e-local}"
PORT="${PORT:-8099}"
BASE="http://10.0.2.2:$PORT"            # the host, seen from QEMU user networking
# Not $PROFILE/$GUEST_HOST: dotfiles shells export PROFILE (the host's own name).
PROFILE="${E2E_PROFILE:-arch-e2e}"
GUEST_HOST="${E2E_HOST:-arch-e2e}"      # PROFILE_HOSTNAME of that profile
HARD_DRIVE=/dev/nvme0n1
SWAP_GIB="${SWAP_GIB:-2}"
DISK_GB="${DISK_GB:-30}"
RAM_MB="${VM_RAM:-6144}"
CPUS="${VM_CPUS:-6}"
DOTFILES_REF="${DOTFILES_REF:-$(git -C "$DOTFILES_SRC" branch --show-current)}"
INSTALL_TIMEOUT="${INSTALL_TIMEOUT:-2400}"
POST_TIMEOUT="${POST_TIMEOUT:-5400}"
LUKS_PW='luks-e2e-Pass1' ROOT_PW='root-e2e-Pass2' NEWUSER=gustaf NEWPW='user-e2e-Pass3'
OVMF_CODE=/usr/share/edk2/x64/OVMF_CODE.4m.fd
OVMF_VARS_SRC=/usr/share/edk2/x64/OVMF_VARS.4m.fd
LOG="$WORK/serial.log" FIFO="$WORK/serial.fifo"

say() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
fail() { echo "FAIL: $*"; strip <"$LOG" | tail -30; exit 1; }
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
resetlog() { [ -f "$LOG" ] && cat "$LOG" >>"$LOG.all"; : >"$LOG"; }
mon() { echo "$1" | socat - UNIX-CONNECT:"$WORK/mon.sock" >/dev/null 2>&1; }

vm_start() { # extra qemu args...
	qemu-system-x86_64 -name arch-e2e -enable-kvm -cpu host -smp "$CPUS" -m "$RAM_MB" -machine q35 \
		-drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
		-drive if=pflash,format=raw,file="$WORK/OVMF_VARS.fd" \
		-drive file="$WORK/disk.qcow2",if=none,id=nvm,format=qcow2 -device nvme,serial=e2e0001,drive=nvm \
		-netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
		-vga std -display none \
		-serial unix:"$WORK/serial.sock",server=on,wait=off \
		-monitor unix:"$WORK/mon.sock",server=on,wait=off \
		-pidfile "$WORK/qemu.pid" -daemonize "$@" || fail "qemu did not start"
	sleep 2
	rm -f "$FIFO"; mkfifo "$FIFO"
	socat UNIX-CONNECT:"$WORK/serial.sock" - <"$FIFO" >>"$LOG" 2>&1 &
	SOCAT_PID=$!
	exec 3>"$FIFO"
}
vm_stop() {
	{ exec 3>&-; } 2>/dev/null
	# Never `kill "${PID:-0}"`: kill 0 signals the whole process group, i.e. this
	# script (that is how the first run killed itself before booting anything).
	[ -n "${SOCAT_PID:-}" ] && kill "$SOCAT_PID" 2>/dev/null
	SOCAT_PID=""
	[ -f "$WORK/qemu.pid" ] && kill "$(cat "$WORK/qemu.pid")" 2>/dev/null
	for _ in $(seq 1 20); do [ -f "$WORK/qemu.pid" ] && kill -0 "$(cat "$WORK/qemu.pid")" 2>/dev/null || break; sleep 1; done
	rm -f "$WORK/qemu.pid"
}
cleanup() { vm_stop; [ -n "${HTTP_PID:-}" ] && kill "$HTTP_PID" 2>/dev/null; }
trap cleanup EXIT

live_shell() { # tag
	send ""
	waitre "archiso login:" 240 || fail "no live login prompt"
	send "root"; sleep 3
	send "exec bash --norc --noprofile"; sleep 3
	send "set +H"; sleep 1
	send "echo ${1}_\"\"READY"
	waitre "${1}_READY" 60 || fail "no live shell"
}

##############################################################################
say "SETUP: work dir, ISO kernel, HTTP server for both working trees"
mkdir -p "$WORK"
vm_stop 2>/dev/null
rm -f "$LOG" "$LOG.all" "$WORK/disk.qcow2"
qemu-img create -q -f qcow2 "$WORK/disk.qcow2" "${DISK_GB}G"
cp "$OVMF_VARS_SRC" "$WORK/OVMF_VARS.fd"     # fresh NVRAM: no stale boot entries
ISOLABEL=$(blkid -o value -s LABEL "$ISO")
bsdtar -xf "$ISO" -C "$WORK" arch/boot/x86_64/vmlinuz-linux arch/boot/x86_64/initramfs-linux.img
WWW="$WORK/www"; rm -rf "$WWW"; mkdir -p "$WWW"
rsync -a --exclude .git "$HERE/" "$WWW/"
rsync -a "$DOTFILES_SRC/profiles/" "$WWW/profiles/"
git clone -q --bare --branch "$DOTFILES_REF" "$DOTFILES_SRC" "$WWW/dotfiles.git"
git -C "$WWW/dotfiles.git" update-server-info
DOTFILES_REPO="$BASE/dotfiles.git"
(cd "$WWW" && exec python3 -m http.server "$PORT" --bind 0.0.0.0 >"$WORK/http.log" 2>&1) &
HTTP_PID=$!
sleep 1
curl -fsS -o /dev/null "http://127.0.0.1:$PORT/install.sh" || fail "http server"
echo "  ISO=$ISO label=$ISOLABEL  dotfiles ref=$DOTFILES_REF  profile=$PROFILE"

##############################################################################
say "PHASE 1: live ISO, the real one-liner with interactive prompts"
resetlog
vm_start -cdrom "$ISO" -kernel "$WORK/arch/boot/x86_64/vmlinuz-linux" \
	-initrd "$WORK/arch/boot/x86_64/initramfs-linux.img" \
	-append "archisobasedir=arch archisolabel=$ISOLABEL console=ttyS0,115200 rw"
live_shell P1
send 'ping -c1 -W5 archlinux.org >/dev/null 2>&1 && echo NET_""UP || echo NET_""DOWN'
waitre "NET_UP" 90 || fail "no network in live ISO"
send "mkdir -p /root/bin && curl -fsSL -o /root/bin/reboot $BASE/test/fixtures/reboot-shim.sh && chmod +x /root/bin/reboot && echo SHIM_\"\"OK"
waitre "SHIM_OK" 60 || fail "reboot shim"
# Exactly the one-liner (plus test-only sources/disk overrides). No secrets in
# the environment: every one of them is typed at a /dev/tty prompt below.
send "curl -fsSL $BASE/install.sh | env PATH=/root/bin:\$PATH INSTALLER_URL=$BASE PROFILE=$PROFILE PROFILE_URL=$BASE/profiles HARD_DRIVE=$HARD_DRIVE SWAP_GIB=$SWAP_GIB DOTFILES_REPO=$DOTFILES_REPO DOTFILES_REF=$DOTFILES_REF bash 2>&1 | tee /root/inst.log; echo HARNESS_\"\"RC=\${PIPESTATUS[1]}"
answer() { waitre "$1" 120 || fail "no prompt: $1"; sleep 0.5; send "$2"; }
answer 'Disk encryption \(LUKS\) passphrase: ' "$LUKS_PW"
answer 'Repeat Disk encryption' "$LUKS_PW"
answer 'Root password: ' "$ROOT_PW"
answer 'Repeat Root password' "$ROOT_PW"
answer 'Username for your account: ' "$NEWUSER"
answer "Password for $NEWUSER: " "$NEWPW"
answer "Repeat Password for $NEWUSER" "$NEWPW"
answer "Type the hostname \\($GUEST_HOST\\) to erase" "$GUEST_HOST"
if waitre 'HARNESS_RC=[0-9]|INSTALLER_REACHED_REBOOT' "$INSTALL_TIMEOUT"; then
	say "INSTALLER COMPLETED: $(strip <"$LOG" | grep -aoE 'HARNESS_RC=[0-9]+|INSTALLER_REACHED_REBOOT' | tail -1)"
	strip <"$LOG" | grep -aqE 'HARNESS_RC=[1-9]' && fail "installer exited non-zero"
else
	fail "PHASE 1 TIMEOUT after ${INSTALL_TIMEOUT}s"
fi
sleep 5
vm_stop

##############################################################################
say "PHASE 2: live ISO again: inspect the target, add serial console (fixture)"
resetlog
vm_start -cdrom "$ISO" -kernel "$WORK/arch/boot/x86_64/vmlinuz-linux" \
	-initrd "$WORK/arch/boot/x86_64/initramfs-linux.img" \
	-append "archisobasedir=arch archisolabel=$ISOLABEL console=ttyS0,115200 rw"
live_shell P2
send "printf '%s' '$LUKS_PW' | cryptsetup open ${HARD_DRIVE}p3 root - && mount /dev/mapper/root /mnt && mount ${HARD_DRIVE}p1 /mnt/boot && echo MNT_\"\"OK"
waitre "MNT_OK" 90 || fail "could not mount the installed system"
send "echo A1_\"\"S; \
for f in /mnt/etc/hostname /mnt/boot/grub/grub.cfg /mnt/root/firstboot.sh /mnt/root/post_install_root.sh; do [ -s \$f ] && echo OK   present \$f || echo FAIL missing \$f; done; \
grep -qx $GUEST_HOST /mnt/etc/hostname && echo 'OK   hostname' || echo 'FAIL hostname'; \
[ -f /mnt/boot/intel-ucode.img ] && echo 'OK   intel-ucode.img on /boot' || echo 'FAIL no microcode'; \
grep -q 'intel-ucode.img' /mnt/boot/grub/grub.cfg && echo 'OK   grub loads microcode' || echo 'FAIL grub has no microcode initrd'; \
[ \"\$(stat -c %a /mnt/root/.firstboot.env)\" = 600 ] && echo 'OK   firstboot env is 0600' || echo 'FAIL firstboot env perms'; \
grep -q 'install-arch firstboot' /mnt/root/.bash_profile && echo 'OK   first-login hook installed' || echo 'FAIL no hook'; \
[ ! -e /mnt/var_root_password ] && echo 'OK   var_root_password cleaned up' || echo 'FAIL var_root_password left'; \
for s in '$LUKS_PW' '$ROOT_PW' '$NEWPW'; do grep -qF \"\$s\" /mnt/root/inst.log && echo 'FAIL a secret is in inst.log' || echo 'OK   secret absent from inst.log'; done; \
grep -q '^root:[^!*]' /mnt/etc/shadow && echo 'OK   root password hash set' || echo 'FAIL root password unset'; \
echo A1_\"\"E"
waitre "A1_E" 90
strip <"$LOG" | sed -n '/^A1_S/,/^A1_E/p' | grep -aE '^(OK|FAIL)' | tee "$WORK/assert-phase2.txt"
send "arch-chroot /mnt bash -c \"sed -i 's|^GRUB_CMDLINE_LINUX=\\\"|GRUB_CMDLINE_LINUX=\\\"console=tty0 console=ttyS0,115200 |' /etc/default/grub && grub-mkconfig -o /boot/grub/grub.cfg\" >/dev/null 2>&1; echo GRUB_\"\"PATCHED"
waitre "GRUB_PATCHED" 300 || fail "grub patch"
# sudo's env_reset would drop DOTFILES_REPO/REF before post_install_user.sh, so
# the guest would clone GitHub master instead of the tree under test.
send "printf 'Defaults env_keep += \"DOTFILES_REPO DOTFILES_REF\"\n' > /mnt/etc/sudoers.d/e2e_env; chmod 0440 /mnt/etc/sudoers.d/e2e_env; umount -R /mnt; cryptsetup close root; sync; echo CLEAN_\"\"DONE"
waitre "CLEAN_DONE" 90 || fail "unmount"
vm_stop

##############################################################################
say "PHASE 3: boot from disk, unlock LUKS, first root login runs firstboot.sh"
resetlog
vm_start
waitre "Enter passphrase" 240 || fail "no LUKS prompt from the installed system"
send "$LUKS_PW"
waitre "$GUEST_HOST login:" 300 || fail "LUKS unlock / boot to userspace"
echo "  OK   LUKS unlock, reached '$GUEST_HOST login:'"
send "root"; sleep 2
send "$ROOT_PW"
waitre "install-arch first boot: finishing the setup for '$NEWUSER'" 120 || fail "first-login hook did not start"
echo "  OK   first-login hook started firstboot.sh"
if waitre 'FIRSTBOOT_RC=[0-9]+' "$POST_TIMEOUT"; then
	say "firstboot: $(strip <"$LOG" | grep -aoE 'FIRSTBOOT_RC=[0-9]+' | tail -1)"
else
	fail "PHASE 3 TIMEOUT after ${POST_TIMEOUT}s"
fi
sleep 3
send "exec bash --norc --noprofile"; sleep 2
send "set +H"; sleep 1
send "echo A2_\"\"S; \
[ ! -e /root/.firstboot.env ] && echo 'OK   env file (password) deleted' || echo 'FAIL env file still there'; \
for s in '$LUKS_PW' '$ROOT_PW' '$NEWPW'; do grep -qF \"\$s\" /root/firstboot.log && echo 'FAIL a secret is in firstboot.log' || echo 'OK   secret absent from firstboot.log'; done; \
grep -q 'install-arch firstboot' /root/.bash_profile && echo 'FAIL hook still in .bash_profile' || echo 'OK   hook removed'; \
id $NEWUSER >/dev/null 2>&1 && echo 'OK   user $NEWUSER exists' || echo 'FAIL user missing'; \
getent passwd $NEWUSER | grep -q zsh && echo 'OK   login shell is zsh' || echo 'FAIL login shell not zsh'; \
[ -d /home/$NEWUSER/sync/src/dotfiles ] && echo 'OK   dotfiles tree at \$DOTFILES' || echo 'FAIL no dotfiles tree'; \
[ -L /home/$NEWUSER/.zshenv ] && echo 'OK   ~/.zshenv symlink' || echo 'FAIL .zshenv symlink'; \
[ -L /home/$NEWUSER/.config/nvim ] && echo 'OK   ~/.config/nvim symlink' || echo 'FAIL nvim symlink'; \
[ -L /home/$NEWUSER/.config/hypr ] && echo 'OK   ~/.config/hypr symlink' || echo 'FAIL hypr symlink'; \
n=\$(find /home/$NEWUSER/.config -maxdepth 2 -xtype l 2>/dev/null | wc -l); [ \"\$n\" = 0 ] && echo 'OK   0 broken symlinks' || echo \"FAIL \$n broken symlinks\"; \
echo 'INFO dotfiles HEAD:' \$(git -c safe.directory=\\* -C /home/$NEWUSER/sync/src/dotfiles log --oneline -1 2>&1); \
echo A2_\"\"E"
waitre 'A2_E' 240
strip <"$LOG" | sed -n '/^A2_S/,/^A2_E/p' | grep -aE '^(OK|FAIL|INFO)' | tee "$WORK/assert-phase3.txt"
send "curl -fsSL $BASE/test/system-assertions.sh | bash -s -- $NEWUSER post-install 2>&1 | sed 's/^/@@/'; echo SA_\"\"E"
waitre 'SA_E' 600
strip <"$LOG" | grep -aE '^@@(OK|FAIL|INFO)' | sed 's/^@@/  /' | tee -a "$WORK/assert-phase3.txt"

##############################################################################
say "PHASE 4: reboot the finished system; the hook must not run again"
resetlog
send "systemctl reboot"
waitre "Enter passphrase" 300 || fail "no LUKS prompt after the post-install reboot"
send "$LUKS_PW"
waitre "$GUEST_HOST login:" 300 || fail "post-install system did not reach a login prompt"
send "root"; sleep 2
send "$ROOT_PW"; sleep 6
send 'echo RB_""READY'
waitre "RB_READY" 90 || fail "root login after reboot"
strip <"$LOG" | grep -aq 'install-arch first boot' && echo "FAIL firstboot ran again" | tee -a "$WORK/assert-phase4.txt" ||
	echo "OK   firstboot did not run again" | tee -a "$WORK/assert-phase4.txt"
mon "screendump $WORK/final.ppm"

say "RESULT"
cat "$WORK"/assert-phase*.txt >"$WORK/assert-all.txt"
f=$(grep -c '^ *FAIL' "$WORK/assert-all.txt"); o=$(grep -c '^ *OK' "$WORK/assert-all.txt")
echo "  $o OK, $f FAIL   (logs: $LOG.all, assertions: $WORK/assert-all.txt)"
[ "$f" = 0 ]
