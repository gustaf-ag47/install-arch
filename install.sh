#!/bin/bash
set -euo pipefail
set -x

# NOTE: no trailing path segment -- chroot.sh and post_install_root.sh live at the
# repo root. A stale "/arch-linux" suffix here made every fetch 404, and because
# curl without -f exits 0 on HTTP errors, `set -e` did not catch it: the 404 body
# was written to chroot.sh and executed, producing a system with no bootloader.
# Overridable so a test harness can point at a local tree instead of GitHub.
INSTALLER_URL="${INSTALLER_URL:-https://raw.githubusercontent.com/gustaf-ag47/install-arch/master}"

# Machine facts come from a profile in the dotfiles repo (profiles/<name>.env),
# so a machine is described in ONE place and the same file drives both the
# install and the later config linking. See dotfiles/profiles/README.md.
#
# PROFILE=<name> is fetched over the network; PROFILE_URL overrides the source.
PROFILE="${PROFILE:-}"
PROFILE_URL="${PROFILE_URL:-https://raw.githubusercontent.com/gustaf-ag47/dotfiles/master/profiles}"
if [ -n "$PROFILE" ]; then
	echo "Fetching profile: $PROFILE"
	curl -fsSL "$PROFILE_URL/$PROFILE.env" -o /tmp/profile.env
	# shellcheck disable=SC1091
	. /tmp/profile.env
fi

# NOT "HOSTNAME": bash sets that automatically to the CURRENT machine's name,
# so ${HOSTNAME:-...} silently resolved to the live ISO's "archiso" and the
# profile value was never used. Override with TARGET_HOSTNAME.
HOSTNAME="${TARGET_HOSTNAME:-${PROFILE_HOSTNAME:-}}"
{ set +x; } 2>/dev/null  # secrets may come from the environment; keep them out of xtrace
ROOT_PASSWORD="${ROOT_PASSWORD:-}"
ENCRYPTION_PASSWORD="${ENCRYPTION_PASSWORD:-}"
# First-boot user (post_install_root.sh): asked now so the first root login can
# finish the whole setup unattended. FIRSTBOOT=0 keeps the old manual step.
FIRSTBOOT="${FIRSTBOOT:-1}"
USERNAME="${USERNAME:-}"
USER_PASSWORD="${USER_PASSWORD:-}"
set -x

# One-shot use is `curl -fsSL .../install.sh | PROFILE=<name> bash`: stdin is the
# script itself, so every prompt reads from /dev/tty. Secrets are asked for, not
# passed on the command line (shell history, `ps`), and never reach xtrace.
TTY=/dev/tty
have_tty() { [ -r "$TTY" ] && [ -w "$TTY" ] && { : <"$TTY"; } 2>/dev/null; }
ask_secret() {
	{ set +x; } 2>/dev/null
	local var=$1 prompt=$2 a b
	if [ -z "${!var:-}" ]; then
		have_tty || { echo "error: $var is not set and there is no terminal to ask on" >&2; exit 1; }
		while :; do
			read -rsp "$prompt: " a <"$TTY"; echo >"$TTY"
			read -rsp "Repeat $prompt: " b <"$TTY"; echo >"$TTY"
			[ -n "$a" ] && [ "$a" = "$b" ] && break
			echo "Empty or not matching, try again." >"$TTY"
		done
		printf -v "$var" '%s' "$a"
	fi
	set -x
}
ask_value() {
	local var=$1 prompt=$2 a=""
	[ -n "${!var:-}" ] && return 0
	have_tty || { echo "error: $var is not set and there is no terminal to ask on" >&2; exit 1; }
	while [ -z "$a" ]; do read -rp "$prompt: " a <"$TTY"; done
	printf -v "$var" '%s' "$a"
}

ask_secret ENCRYPTION_PASSWORD "Disk encryption (LUKS) passphrase"
ask_secret ROOT_PASSWORD "Root password"
if [ "$FIRSTBOOT" = 1 ]; then
	ask_value USERNAME "Username for your account"
	ask_secret USER_PASSWORD "Password for $USERNAME"
fi
# GiB, converted to MiB below. This used to be a bare "8" spliced straight into
# a MiB-denominated parted call, which produced an 8 MiB swap partition.
SWAP_GIB="${SWAP_GIB:-${PROFILE_SWAP_GIB:-8}}"
SWAP_SIZE=$((SWAP_GIB * 1024))
HARD_DRIVE="${HARD_DRIVE:-${PROFILE_DISK:-}}"

# Refuse to guess. Each of these either wipes the wrong disk or leaves a machine
# whose full-disk encryption passphrase is published in a public git repo.
: "${HARD_DRIVE:?set PROFILE=<name> or HARD_DRIVE=/dev/... -- refusing to guess which disk to partition}"
: "${HOSTNAME:?set PROFILE=<name> or TARGET_HOSTNAME=...}"
# xtrace off: `: "${VAR:?}"` is traced WITH the value expanded (leaked both
# passwords into the log in the first one-shot e2e run).
{ set +x; } 2>/dev/null
: "${ROOT_PASSWORD:?set ROOT_PASSWORD -- there is deliberately no default}"
: "${ENCRYPTION_PASSWORD:?set ENCRYPTION_PASSWORD -- there is deliberately no default}"
set -x

[ -b "$HARD_DRIVE" ] || { echo "error: $HARD_DRIVE is not a block device" >&2; exit 1; }
echo "About to ERASE $HARD_DRIVE ($(lsblk -dno SIZE,MODEL "$HARD_DRIVE" 2>/dev/null | xargs))"
echo "  hostname=$HOSTNAME swap=${SWAP_GIB}GiB"
# Last chance before the disk is wiped. ASSUME_YES=1 for unattended test runs.
if [ "${ASSUME_YES:-0}" != 1 ]; then
	have_tty || { echo "error: no terminal to confirm on; set ASSUME_YES=1 to skip" >&2; exit 1; }
	lsblk "$HARD_DRIVE" >"$TTY" 2>&1 || true
	read -rp "Type the hostname ($HOSTNAME) to erase $HARD_DRIVE: " confirm <"$TTY"
	[ "$confirm" = "$HOSTNAME" ] || { echo "Not confirmed, nothing changed." >&2; exit 1; }
fi

BOOT_PARTITION=1
SWAP_PARTITION=2
ROOT_PARTITION=3

verify_boot_mode() {
	UEFI=0

	if [[ -d /sys/firmware/efi ]]; then
		UEFI=1
		echo "System is in UEFI mode."
	else
		echo "System is in Legacy/BIOS mode."
	fi
}

update_system_clock() {
	timedatectl set-ntp true
}

partition_disks() {
	if [ -z "$SWAP_SIZE" ]; then
		ROOT_PARTITION=$((ROOT_PARTITION - 1))
	fi

	partprobe "$HARD_DRIVE"

	if [ "$UEFI" -eq 1 ]; then
		parted --script "$HARD_DRIVE" mklabel gpt
		parted --script "$HARD_DRIVE" mkpart ESP fat32 1MiB 512MiB
		parted --script "$HARD_DRIVE" set 1 esp on
	else
		parted --script "$HARD_DRIVE" mklabel msdos
		parted --script "$HARD_DRIVE" mkpart primary ext4 1MiB 512MiB
		parted --script "$HARD_DRIVE" set 1 boot on
	fi

	if [ -n "$SWAP_SIZE" ]; then
		parted --script "$HARD_DRIVE" mkpart primary linux-swap 513MiB $((SWAP_SIZE + 513))MiB
		parted --script "$HARD_DRIVE" mkpart primary ext4 $((SWAP_SIZE + 514))MiB 100%
	else
		parted --script "$HARD_DRIVE" mkpart primary ext4 513MiB 100%
	fi

	partprobe "$HARD_DRIVE"
}

format_partition() {
	echo "$HARD_DRIVE" | grep -E 'nvme' &>/dev/null && HARD_DRIVE="${HARD_DRIVE}p"

	cryptsetup luksFormat "${HARD_DRIVE}${ROOT_PARTITION}" <<<"$ENCRYPTION_PASSWORD"
	cryptsetup open "${HARD_DRIVE}${ROOT_PARTITION}" root <<<"$ENCRYPTION_PASSWORD"

	mkfs.ext4 /dev/mapper/root

	[ -n "$SWAP_SIZE" ] && mkswap "${HARD_DRIVE}${SWAP_PARTITION}"

	if [ "$UEFI" -eq 1 ]; then
		mkfs.fat -F32 "${HARD_DRIVE}${BOOT_PARTITION}"
	else
		mkfs.ext4 "${HARD_DRIVE}${BOOT_PARTITION}"
	fi
}

mount_file_system() {
	# mkfs closes the partitions it just wrote, which makes udev re-probe them
	# (the "watch" rule). Mounting inside that window intermittently failed
	# with exit 32 on the vfat ESP of a UEFI e2e run; wait for udev first.
	udevadm settle
	mount /dev/mapper/root /mnt
	mount --mkdir "${HARD_DRIVE}${BOOT_PARTITION}" /mnt/boot
	[ -n "$SWAP_SIZE" ] && swapon "${HARD_DRIVE}${SWAP_PARTITION}"
}

select_mirrors() {
	reflector --verbose --latest 20 --sort rate --save /etc/pacman.d/mirrorlist
	pacman -Syy
}

install_essential_packages() {
	# CPU microcode, installed before chroot.sh's grub-mkconfig so GRUB loads it
	# as an early initrd. It was in no layer at all, so machines ran unpatched.
	local ucode=""
	grep -q GenuineIntel /proc/cpuinfo && ucode=intel-ucode
	grep -q AuthenticAMD /proc/cpuinfo && ucode=amd-ucode
	# shellcheck disable=SC2086  # $ucode is empty or one word
	pacstrap -K /mnt base base-devel linux linux-firmware networkmanager iwd neovim git $ucode
}

fstab() {
	genfstab -U /mnt >>/mnt/etc/fstab
}

chroot() {
	echo "$HARD_DRIVE" >/mnt/var_hard_drive
	echo "$HOSTNAME" >/mnt/var_hostname
	echo "$ROOT_PARTITION" >/mnt/var_root_partition
	{ set +x; } 2>/dev/null
	(umask 077 && printf '%s\n' "$ROOT_PASSWORD" >/mnt/var_root_password)
	set -x
	echo "$UEFI" >/mnt/var_uefi

	curl -fsSL "$INSTALLER_URL/chroot.sh" >/mnt/chroot.sh
	arch-chroot /mnt bash chroot.sh
}

pre_installation() {
	verify_boot_mode
	update_system_clock
	partition_disks
	format_partition
	mount_file_system
}

installation() {
	select_mirrors
	install_essential_packages
}

configure_system() {
	fstab
	chroot
}

prepare_post_install() {
	curl -fsSL "$INSTALLER_URL/post_install_root.sh" >/mnt/root/post_install_root.sh
	[ "$FIRSTBOOT" = 1 ] || return 0

	# First root login runs firstboot.sh once: network, then post_install_root.sh
	# with the user asked for above. The env file holds that password, so it is
	# root-only, lives inside the LUKS volume, and firstboot.sh deletes it.
	curl -fsSL "$INSTALLER_URL/firstboot.sh" >/mnt/root/firstboot.sh
	{ set +x; } 2>/dev/null
	(
		umask 077
		{
			printf 'USERNAME=%q\n' "$USERNAME"
			printf 'PASSWORD=%q\n' "$USER_PASSWORD"
			printf 'INSTALLER_URL=%q\n' "$INSTALLER_URL"
			[ -n "${DOTFILES_REPO:-}" ] && printf 'DOTFILES_REPO=%q\n' "$DOTFILES_REPO"
			[ -n "${DOTFILES_REF:-}" ] && printf 'DOTFILES_REF=%q\n' "$DOTFILES_REF"
		} >/mnt/root/.firstboot.env
	)
	set -x
	cat >>/mnt/root/.bash_profile <<'EOF'
# >>> install-arch firstboot (removed automatically once setup succeeds)
[[ $- == *i* && -f /root/.firstboot.env ]] && bash /root/firstboot.sh
# <<< install-arch firstboot
EOF
}

cleanup_and_reboot() {
	rm -rf /mnt/var_hard_drive
	rm -rf /mnt/var_hostname
	rm -rf /mnt/var_root_partition
	rm -rf /mnt/var_root_password
	rm -rf /mnt/var_uefi
	rm -rf /mnt/chroot.sh
	reboot
}

main() {
	pre_installation
	installation
	configure_system
	prepare_post_install
	cleanup_and_reboot
}

main
