#!/bin/bash

set -euo pipefail
set -x

HARD_DRIVE=$(cat /var_hard_drive)
HOSTNAME="$(cat /var_hostname)"
ROOT_PARTITION=$(cat /var_root_partition)
ROOT_PASSWORD=$(cat /var_root_password)
UEFI=$(cat /var_uefi)

time_zone() {
	ln -sf /usr/share/zoneinfo/Europe/Stockholm /etc/localtime
	hwclock --systohc
}

localization() {
	echo "en_US.UTF-8 UTF-8" >>/etc/locale.gen
	locale-gen
	echo "LANG=en_US.UTF-8" >/etc/locale.conf
	echo "KEYMAP=sv-latin1" >>/etc/vconsole.conf
}

network_configuration() {
	systemctl enable NetworkManager
	systemctl start NetworkManager

	echo "$HOSTNAME" >/etc/hostname
	{
		echo "127.0.0.1       localhost"
		echo "::1             localhost"
		echo "127.0.1.1       $HOSTNAME"
	} >>/etc/hosts
}

initramfs() {
	# Intel VMD ("RAID On" in Dell BIOSes, the factory default on some XPS
	# models) puts the NVMe drive behind the vmd driver. Without it in the
	# initramfs the encrypted root is invisible at boot. The live ISO has the
	# same kernel, so the module being loaded right now means VMD is active.
	# Setting the BIOS to "AHCI/NVMe" is the clean fix; this is the safety net.
	if [ -d /sys/module/vmd ]; then
		mkdir -p /etc/mkinitcpio.conf.d
		echo 'MODULES+=(vmd)' >/etc/mkinitcpio.conf.d/vmd.conf
		echo "Intel VMD active: added vmd to the initramfs"
	fi

	sed -i "s/^HOOKS=.*/HOOKS=(base udev keyboard autodetect modconf kms keymap consolefont block encrypt filesystems fsck)/g" /etc/mkinitcpio.conf
	mkinitcpio -P
}

root_password() {
	echo "root:$ROOT_PASSWORD" | chpasswd
}

boot_loader() {
	pacman -S --noconfirm grub

	cryptuuid=$(blkid -o value -s UUID "${HARD_DRIVE}${ROOT_PARTITION}")
	decryptuuid=$(blkid -o value -s UUID /dev/mapper/root)

	sed -i "s/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=$cryptuuid:root root=UUID=$decryptuuid\"/" /etc/default/grub

	if [ "$UEFI" = 1 ]; then
		pacman -S --noconfirm efibootmgr
		grub-install --target=x86_64-efi \
			--bootloader-id=GRUB \
			--efi-directory=/boot
	else
		grub-install "$HARD_DRIVE"
	fi
	grub-mkconfig -o /boot/grub/grub.cfg
}

main() {
	time_zone
	localization
	network_configuration
	initramfs
	root_password
	boot_loader
}

main "$@"
