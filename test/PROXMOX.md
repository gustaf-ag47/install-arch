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

## Run it (single shot, blank disk -> dotfiles installed)

`test/proxmox-full-e2e.sh` does the whole thing in one uninterrupted pass:
wipes the disk, installs, reboots, runs the post-install chain, asserts, and
takes a VGA screendump. Serve both working trees first so unpushed code is what
actually gets tested:

```bash
# on skrubben
rsync -a --exclude .git ./ root@$PVE:/root/install-arch-test/
git clone --bare ../dotfiles /tmp/dotfiles.git
(cd /tmp/dotfiles.git && git update-server-info)   # dumb-HTTP clone needs this
rsync -a /tmp/dotfiles.git root@$PVE:/root/install-arch-test/
scp test/proxmox-full-e2e.sh root@$PVE:/root/full-e2e.sh
ssh root@$PVE 'systemd-run --unit=arch-e2e-http \
  --property=WorkingDirectory=/root/install-arch-test \
  /usr/bin/python3 -m http.server 8099 --bind 0.0.0.0'
ssh root@$PVE 'nohup bash /root/full-e2e.sh > /root/full-run.log 2>&1 &'
```

A full pass is ~25 min on pve (~35 min for the UEFI xps14 run below, which adds
a post-install reboot).

### Testing a machine profile (e.g. the Dell XPS 14), UEFI

`pve` (192.168.1.122) sits on LAN B; from the laptop, reach it through skrubben
(`ssh -J gud1@skrubben root@192.168.1.122`; see rissne's network notes). Serve
the dotfiles **profiles** too, and pin the dotfiles branch under test:

```bash
J="ssh -J gud1@skrubben"; P=root@192.168.1.122

rm -rf /tmp/dotfiles.git && git clone -q --bare ../dotfiles /tmp/dotfiles.git
git -C /tmp/dotfiles.git update-server-info
rsync -a --delete --exclude .git --exclude dotfiles.git --exclude profiles -e "$J" ./ $P:/root/install-arch-test/
rsync -a --delete -e "$J" /tmp/dotfiles.git/ $P:/root/install-arch-test/dotfiles.git/
rsync -a --delete -e "$J" ../dotfiles/profiles/ $P:/root/install-arch-test/profiles/
scp -J gud1@skrubben test/proxmox-full-e2e.sh $P:/root/full-e2e.sh
$J $P 'nohup env PVE_IP=192.168.1.122 PROFILE=xps14 GUEST_HOST=xps14 \
  FIRMWARE=uefi DISK_GB=32 SWAP_GIB=2 DOTFILES_REF=<branch> \
  bash /root/full-e2e.sh > /root/full-run.log 2>&1 &'
```

On top of the base assertions this runs `test/system-assertions.sh` in the
guest (overlays, `install-system.sh --check`, GPU packages by `PROFILE_GPU`,
host-layer packages/units), then reboots the post-installed system and checks
the new kernel parameters and units live. The full serial history is kept in
`/tmp/990-serial.log.all`.

First green run (2026-10-06, xps14, OVMF, kernel 7.2.8): 58 OK / 0 FAIL;
`intel-cvs-late` ran its no-SoundWire timeout path; no failed units. What a VM
cannot show: the CS35L57/intel_cvs race itself, the IPU7 camera, the panel,
s2idle residency, the BE211 radio. Two fixtures are applied to the guest, neither of
which changes the installer's own code path:

- `/etc/sudoers.d/e2e_env` — `sudo`'s `env_reset` would otherwise drop
  `DOTFILES_REPO` before `post_install_user.sh` runs under `sudo -u $USER`, and
  the guest would silently clone GitHub master instead of the tree under test.
- `test/fixtures/reboot-shim.sh` — see gotcha 5.

## Run just the install phase

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
4. **Strip `\e[?2004h`/`\e[?2004l` too.** Bracketed-paste sequences contain a
   `?`, so the obvious `s/\x1b\[[0-9;]*[a-zA-Z]//g` leaves them attached to the
   front of the line and every `^SENTINEL`-anchored `sed` range silently
   produces nothing.
5. **`install.sh` ends with `reboot`, which races the harness's
   `echo HARNESS_RC=$?`.** The echo won one run and lost the next, leaving the
   harness blocked on a sentinel that could never appear. `reboot-shim.sh` is
   put first on `PATH` for the installer run only: it copies `inst.log` onto the
   target filesystem (still mounted at `/mnt`) and prints a deterministic
   sentinel before handing off to the real `/usr/bin/reboot`.
6. **OVMF does not see an IDE CD-ROM.** The live kernel's `ata_piix` finds the
   IDE channels but never the drive ("ARCH_xxxx device did not show up after
   30 seconds"). `FIRMWARE=uefi` attaches the ISO as `scsi1` instead.
7. **History expansion in the guest shell.** Interactive bash expands `!` even
   inside double quotes, so a check like `"^root:[^!*]"` became the previous
   command's arguments and phase 2's assertions printed nothing. Every shell
   gets `set +H` right after `exec bash`.
8. **Never `qm disk unlink --force` a CD-ROM slot**: on an ISO volume it would
   delete the ISO itself. CD-ROM slots are removed with plain `qm set --delete`.
