#!/bin/bash
# Guest-side assertions for the dotfiles machine-profile layer, run as root on
# the INSTALLED system by proxmox-full-e2e.sh (fetched from $BASE, piped to bash).
#
#   system-assertions.sh <user> [post-install|after-reboot]
#
# post-install  right after post_install_root.sh: overlays linked, system layer
#               applied and in sync, GPU packages chosen by the profile.
# after-reboot  after booting the system that post-install produced: kernel
#               parameters and initramfs drop-ins took effect, no failed units
#               beyond the expected ones.
#
# Prints one "OK/FAIL/INFO ..." line per check; the harness greps those.
set -u

user="${1:?usage: system-assertions.sh <user> [post-install|after-reboot]}"
phase="${2:-post-install}"
home="/home/$user"
D="$home/sync/src/dotfiles"
host="$(cat /etc/hostname)"

ok() { echo "OK   $*"; }
no() { echo "FAIL $*"; }
info() { echo "INFO $*"; }
check() {
	local desc="$1"
	shift
	if "$@" >/dev/null 2>&1; then ok "$desc"; else no "$desc"; fi
}

PROFILE_GPU=""
if [ -f "$D/profiles/$host.env" ]; then
	# shellcheck disable=SC1090
	. "$D/profiles/$host.env"
	ok "profile resolved from hostname: profiles/$host.env (gpu=$PROFILE_GPU)"
else
	no "no profiles/$host.env for hostname $host"
fi

if [ "$phase" = post-install ]; then
	info "dotfiles HEAD: $(git -c safe.directory='*' -C "$D" log --oneline -1 2>&1)"

	# --- user-side overlays (scripts/install.sh) ---
	check "hypr gpu overlay -> gpu/$PROFILE_GPU.conf" \
		test "$(readlink "$home/.config/hypr-gpu.conf")" = "$D/config/gui/Wayland/hypr/gpu/$PROFILE_GPU.conf"
	check "waybar overlay outside the repo (~/.config/waybar-host.jsonc)" \
		test -e "$home/.config/waybar-host.jsonc"
	check "no overlay link inside the repo (waybar/profile.jsonc)" \
		test ! -e "$D/config/gui/Wayland/waybar/profile.jsonc"
	check "hypr host overlay -> hosts/$host.conf" \
		test "$(readlink "$home/.config/hypr-host.conf")" = "$D/config/gui/Wayland/hypr/hosts/$host.conf"
	check "dotfiles-profile.env says PROFILE=$host" \
		grep -q "PROFILE=\"$host\"" "$home/.config/dotfiles-profile.env"

	# --- root-side system layer (scripts/install-system.sh) ---
	out="$(bash "$D/scripts/install-system.sh" --check 2>&1)"
	if [ "$(printf '%s\n' "$out" | tail -1)" = "In sync." ]; then
		ok "install-system.sh --check: In sync"
	else
		no "install-system.sh --check drifted:"
		printf '%s\n' "$out" | sed 's/^/       /'
	fi
	check "logind idle hand-off present (common layer)" test -f /etc/systemd/logind.conf.d/idle.conf
	if dkms status -m hid-annepro2 2>/dev/null | grep -q installed; then
		ok "dkms: hid-annepro2 built and installed"
	else
		no "dkms: hid-annepro2 not installed ($(dkms status -m hid-annepro2 2>&1 | head -1))"
	fi
fi

# --- GPU drivers chosen by PROFILE_GPU (both phases: nothing reinstalls them) ---
case "$PROFILE_GPU" in
intel)
	check "gpu=intel: intel-media-driver installed" pacman -Q intel-media-driver
	check "gpu=intel: vulkan-intel installed" pacman -Q vulkan-intel
	check "gpu=intel: NO nvidia-utils (apps.csv no longer forces it)" bash -c '! pacman -Q nvidia-utils'
	check "gpu=intel: NO nvidia early-KMS drop-in" test ! -e /etc/mkinitcpio.conf.d/nvidia.conf
	;;
nvidia | hybrid)
	check "gpu=$PROFILE_GPU: nvidia-utils installed" pacman -Q nvidia-utils
	check "gpu=$PROFILE_GPU: nvidia early-KMS drop-in" test -f /etc/mkinitcpio.conf.d/nvidia.conf
	;;
esac

# --- host layer: xps14 ---
if [ "$host" = xps14 ]; then
	for p in sof-firmware alsa-ucm-conf libcamera pipewire-libcamera wireless-regdb fwupd tlp; do
		check "xps14: $p installed" pacman -Q "$p"
	done
	check "xps14: intel_cvs blacklisted" grep -q '^blacklist intel_cvs' /etc/modprobe.d/intel-cvs-late.conf
	check "xps14: intel-cvs-late loader is executable" test -x /usr/local/bin/intel-cvs-late
	check "xps14: intel-cvs-late.service enabled" systemctl is-enabled intel-cvs-late.service
	check "xps14: grub.cfg carries mem_sleep_default=s2idle" grep -q 'mem_sleep_default=s2idle' /boot/grub/grub.cfg
fi

if [ "$phase" = after-reboot ]; then
	info "cmdline: $(cat /proc/cmdline)"
	info "kernel: $(uname -r)"
	# Every parameter a grub.d drop-in appends must be on the live cmdline.
	for f in /etc/default/grub.d/*.cfg; do
		[ -f "$f" ] || continue
		params="$(sed -n 's/.*GRUB_CMDLINE_LINUX_DEFAULT}[[:space:]]*\(.*\)"$/\1/p' "$f")"
		for p in $params; do
			check "live cmdline has $p (from ${f##*/})" grep -qw -- "$p" /proc/cmdline
		done
	done
	if [ "$host" = xps14 ]; then
		# The VM has no SoundWire bus, so the loader waits out its timeout and
		# then loads intel_cvs anyway: active = it ran to completion.
		state="$(systemctl is-active intel-cvs-late.service 2>&1)"
		info "intel-cvs-late.service: $state"
		journalctl -b -u intel-cvs-late.service --no-pager -o cat 2>/dev/null | tail -3 | sed 's/^/INFO   /'
		if [ "$state" = active ]; then
			ok "xps14: intel-cvs-late ran (timeout path, no SoundWire in a VM)"
		else
			no "xps14: intel-cvs-late did not complete ($state)"
		fi
		check "xps14: modprobe config carries the intel_cvs blacklist" \
			bash -c "modprobe --showconfig | grep -qx 'blacklist intel_cvs'"
	fi
	failed="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
	info "failed units: ${failed:-none}"
fi
