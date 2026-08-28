#!/bin/bash
# Test fixture, installed as /root/bin/reboot and put first on PATH for the
# installer run only. install.sh ends with `reboot`, so the harness's
# `echo HARNESS_RC=$?` races systemd's shutdown of the serial console: it won
# once and lost once, leaving the harness waiting for a sentinel that could
# never appear.
#
# This shim makes completion deterministic and, as a bonus, preserves the
# installer log by copying it onto the target filesystem (still mounted at /mnt
# when install.sh calls reboot), so phase 2 can read it after the reboot.
cp /root/inst.log /mnt/root/inst.log 2>/dev/null
sync
echo "INSTALLER_REACHED_""REBOOT" >/dev/console
sleep 5
exec /usr/bin/reboot
