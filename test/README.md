# install-arch / dotfiles — local E2E tests

Layered end-to-end tests for the Arch installer + dotfiles, runnable on this PC.
Fast layers run in seconds; the container layer does a **real `make install` on a
fresh `archlinux:latest`** against the current working tree (not GitHub `master`,
which is stale — see "Drift" below).

## Run

```bash
install-arch/test/run.sh                # L0 lint + L1 rotation + L2 container
install-arch/test/run.sh --no-container # L0 + L1 only (no docker)
install-arch/test/e2e-container.sh      # just the container make-install + asserts
python3 install-arch/test/token-rotation-test.py   # just rotation logic
install-arch/test/qemu-vm.sh            # full-metal VM (needs /dev/kvm)
```

## Layers

| Layer | File | What it proves | Needs |
|-------|------|----------------|-------|
| L0 lint | `run.sh` | `bash -n` (+shellcheck) on installer & dotfiles scripts | nothing |
| L1 rotation | `token-rotation-test.py` | account rollover: lowest-weekly pick, forced-cooldown skip, failover exclude, invalid-token skip, 5h tiebreak | python3 |
| L2 container | `e2e-container.sh` → `in-container.sh` → `assertions.sh` | real `make install` on Arch: symlinks, `~/.local/bin`, zsh plugins, `$DOTFILES` + PATH resolve in a real zsh, token wiring | docker |
| L3 full-metal | `qemu-vm.sh` | partitioning, LUKS, GRUB, systemd-PID1, reboot | **/dev/kvm** |

## What the container layer canNOT test (needs L3 / real hardware)

Disk partitioning, LUKS, GRUB/boot, systemd as PID1, and everything in
`CLAUDE.md`'s "system-level files must be created manually" section (NVIDIA
suspend, logind, GRUB cmdline, `hyprland-sigstop`, `hid-annepro2` DKMS). None of
that is scripted yet — a fresh machine still needs those steps by hand.

## Bugs this harness found and fixed

1. **`make install` aborted on a fresh machine (exit 2).** `config/zsh/.zshenv`'s
   Obsidian-AppImage lookup returned non-zero when no AppImage exists, and
   `install.sh` sources `.zshenv` under `set -euo pipefail`. Existing machines
   only worked because they already had an AppImage. Fixed with `|| true`.
2. **`bin/cctoken-from-pass` was not executable** (`-rw-r--r--`), so its
   `~/.local/bin` symlink pointed at a non-exec file. Fixed with `chmod +x`.

## Drift (must fix for a VM test to be meaningful)

- `install-arch` clones dotfiles **`master`**, but the token/proxy/sync work is on
  branch `fix/arch-suspend-bluetooth-20260601`, **17 commits ahead of `origin/master`**.
  A VM install from `master` tests old code. Merge to `master` or make the
  installer clone a pinnable `$DOTFILES_REF`.
- `install-arch/post_install_user.sh` and `apps.csv` have **uncommitted** Dec-2025
  changes (dotfiles URL fix, `bootstrap_sync`, tokei/texlive) — a GitHub clone
  won't get them.

## Secrets

L2 uses `fixtures/cctoken.fake` (obviously-fake `sk-ant-oat…` strings) and never
touches real tokens, `pass`, or the network for auth. Never bake real tokens into
an image.
