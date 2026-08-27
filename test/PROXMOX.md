# L3 full-metal E2E on Proxmox (`pve`)

Set `PVE` to your Proxmox host (e.g. `export PVE=10.0.0.5`) before running anything below.

`skrubben` cannot run this: its i9-9900K has **VT-x disabled in UEFI**
(`grep -c vmx /proc/cpuinfo` → 0, `modprobe kvm_intel` → *Operation not
supported*). Rather than reboot the workstation, run L3 on **pve**, which has
`/dev/kvm`, 12 cores and free RAM.

## What it proves

The only layer that exercises **partitioning, LUKS, GRUB, mkinitcpio and
systemd as PID 1**. Verified 2026-08-27:

| Stage | Result |
|-------|--------|
| Installer exit code | `HARNESS_RC=0` |
| GRUB → initramfs | boots, `encrypt` hook prompts `Enter passphrase for /dev/sda3` |
| LUKS unlock | succeeds with the configured passphrase |
| Boot to userspace | `Arch Linux 7.1.9-arch1-2 (tty1)` / `arch login:` |
| Root login | `[root@arch ~]#` |

## Run it

```bash
# on skrubben
rsync -a --exclude .git ./ root@$PVE:/root/install-arch-test/
scp test/proxmox-e2e.sh root@$PVE:/root/arch-e2e.sh

# serve the working tree so the guest tests UNPUSHED code, not GitHub master
ssh root@$PVE 'systemd-run --unit=arch-e2e-http \
  --property=WorkingDirectory=/root/install-arch-test \
  /usr/bin/python3 -m http.server 8099 --bind 0.0.0.0'

# drive the install
ssh root@$PVE "INSTALLER_URL=http://$PVE:8099/install.sh \
  GUEST_URL=http://$PVE:8099 bash /root/arch-e2e.sh"
```

Test against GitHub `master` instead by omitting both env vars.

## VM 990

Created outside the rissne IaC scope on purpose (rissne owns 100–108; the
`ralph` fleet 110–113/120 is off-limits). Safe to destroy: `qm destroy 990`.

```bash
qm create 990 --name arch-e2e --memory 4096 --cores 2 \
  --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-pci --scsi0 local-lvm:20 \
  --ide2 local:iso/archlinux-x86_64.iso,media=cdrom \
  --boot order=scsi0 --serial0 socket --vga serial0 --ostype l26
```

**Install phase** uses direct kernel boot so the ISO comes up on the serial
console with no boot-menu keystrokes:

```bash
qm set 990 --args "-kernel /var/lib/vz/template/iso/archboot/vmlinuz-linux \
  -initrd /var/lib/vz/template/iso/archboot/initramfs-linux.img \
  -append \"archisobasedir=arch archisolabel=ARCH_202608 console=ttyS0,115200 rw\""
```
(`vmlinuz-linux` + `initramfs-linux.img` are copied out of the ISO; the label
must match `blkid -o value -s LABEL <iso>`.)

**Verify phase** — drop the direct-kernel args and the CD, switch to VGA, and
screenshot, because the installed system has no `console=ttyS0` in its
`GRUB_CMDLINE_LINUX`, so nothing appears on serial after reboot:

```bash
qm set 990 --delete args --delete ide2
qm set 990 --vga std --boot order=scsi0
qm start 990
echo "screendump /tmp/shot.ppm" | qm monitor 990
for k in p a s s ret; do echo "sendkey $k" | qm monitor 990; sleep 0.3; done
```

## Harness gotchas (each cost a debugging round)

1. **Don't use `expect`.** Tcl does not substitute `$var` or `\r` escapes inside
   a braced `expect { ... }` block, so variable sentinels silently match a
   literal `IAM_READY_$i` and every wait times out with the data plainly visible
   in the log. The harness uses `socat` + a FIFO instead.
2. **The guest echoes every command you type**, so grepping the console for
   `FOO` matches the command, not its output — every wait becomes an instant
   false positive. Sentinels are written split by a quote pair (`echo FOO_""BAR`
   types `FOO_""BAR` but prints `FOO_BAR`) and only the unquoted form is matched.
3. **archiso's root shell is grml-zsh**, which rewrites `PS1` from a `precmd`
   hook — setting `PS1` does nothing. The harness `exec bash --norc --noprofile`
   first, and must send that *alone*: anything sent in the same burst is
   consumed by the `exec`.
