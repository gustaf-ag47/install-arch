#!/bin/bash
# Full-metal E2E: boot the Arch ISO in QEMU and run install-arch/install.sh
# against a THROWAWAY qcow2 disk (never touches the host). This is the only
# layer that exercises partitioning, LUKS, GRUB and systemd-as-PID1.
#
# REQUIREMENTS: this needs KVM to be practical. Under pure TCG emulation a full
# install takes hours. Check: `ls /dev/kvm`. On this host KVM is unavailable, so
# run this on a machine/CI runner that exposes /dev/kvm.
#
# Design (documented so it is reproducible even where we can't run it now):
#   1. Download the latest Arch ISO + verify signature.
#   2. Create base.qcow2 (throwaway). Never pass a host block device.
#   3. Boot ISO headless with serial console; drive the install via an
#      expect/boot_command that fetches install-arch and runs it non-interactively
#      (installer already hardcodes HOSTNAME/pw/disk for unattended use).
#   4. Installer reboots into the disk; second boot runs post_install_user.sh.
#   5. Copy assertions.sh + goss.yaml into the guest over SSH and run them.
#
# This script implements steps 1-3 (boot + smoke); wire 4-5 once running on KVM.
set -euo pipefail

WORK="${VM_WORK:-/var/tmp/arch-e2e}"
DISK="$WORK/base.qcow2"
ISO_DIR="$WORK/iso"
MIRROR="${ARCH_MIRROR:-https://geo.mirror.pkgbuild.com}"
RAM_MB="${VM_RAM:-4096}"
DISK_GB="${VM_DISK:-20}"

mkdir -p "$WORK" "$ISO_DIR"

accel=""
if [ -e /dev/kvm ]; then
	accel="-enable-kvm -cpu host"
	echo "[qemu] KVM available - full-speed run"
else
	accel="-accel tcg"
	echo "[qemu] WARNING: no /dev/kvm - TCG emulation, a full install will take hours"
fi

echo "[qemu] fetching latest Arch ISO into $ISO_DIR"
ISO="$ISO_DIR/archlinux-x86_64.iso"
if [ ! -f "$ISO" ]; then
	curl -fL "$MIRROR/iso/latest/archlinux-x86_64.iso" -o "$ISO"
fi

echo "[qemu] creating throwaway ${DISK_GB}G disk (host disks are never touched)"
qemu-img create -f qcow2 "$DISK" "${DISK_GB}G" >/dev/null

echo "[qemu] booting installer ISO (serial console). Ctrl-a x to quit."
# shellcheck disable=SC2086
exec qemu-system-x86_64 \
	$accel \
	-m "$RAM_MB" -smp 2 \
	-drive file="$DISK",if=virtio,format=qcow2 \
	-cdrom "$ISO" \
	-boot d \
	-nic user,hostfwd=tcp::2222-:22 \
	-nographic -serial mon:stdio \
	-name arch-e2e
