#!/bin/bash
# E2E harness: boot the Arch ISO in a Proxmox VM and run install-arch unattended.
#
# Drives the serial console via FIFO + socat (not expect: Tcl brace-quoting
# silently breaks $var and \escape patterns inside `expect {...}` blocks).
#
# IMPORTANT: the guest echoes every command we type, so a naive grep matches the
# command instead of its output. Every sentinel is therefore written split by a
# quote pair -- `echo FOO_""BAR` types FOO_""BAR but PRINTS FOO_BAR -- and we
# grep for the unquoted form only.
set -uo pipefail

VMID="${VMID:-990}"
LOG="/tmp/${VMID}-serial.log"
FIFO="/tmp/${VMID}.in"
INSTALLER_URL="${INSTALLER_URL:-https://raw.githubusercontent.com/gustaf-ag47/install-arch/master/install.sh}"
INSTALL_TIMEOUT="${INSTALL_TIMEOUT:-1500}"
# Base URL the installer itself uses to fetch chroot.sh / post_install_*.sh.
# Point this at a local HTTP server to test an unpushed working tree.
GUEST_URL="${GUEST_URL:-https://raw.githubusercontent.com/gustaf-ag47/install-arch/master}"

say() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
send() { printf '%s\r' "$1" >&3; sleep 0.4; }
strip() { sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' -e 's/\x1b\][0-9;]*[^\x07]*\x07//g' -e 's/\r//g'; }
wait_for() {
	local pat=$1 secs=$2 i
	for ((i = 0; i < secs; i++)); do
		strip <"$LOG" | grep -qa -- "$pat" && return 0
		sleep 1
	done
	return 1
}

cleanup() { exec 3>&- 2>/dev/null; kill "${SOCAT_PID:-0}" 2>/dev/null; rm -f "$FIFO"; }
trap cleanup EXIT

say "resetting VM $VMID"
qm stop "$VMID" >/dev/null 2>&1
sleep 4
rm -f "$LOG"
qm start "$VMID" || exit 1

rm -f "$FIFO"; mkfifo "$FIFO"
socat UNIX-CONNECT:/var/run/qemu-server/"$VMID".serial0 - <"$FIFO" >"$LOG" 2>&1 &
SOCAT_PID=$!
exec 3>"$FIFO"

say "waiting for archiso login"
send ""
wait_for "archiso login:" 180 || { echo "FAIL: no login prompt"; exit 1; }
send "root"; sleep 3
send "exec bash --norc --noprofile"; sleep 3
send 'echo HARNESS_""READY'
wait_for "HARNESS_READY" 60 || { echo "FAIL: no shell"; exit 1; }
echo "  shell ready"

say "network"
send 'timedatectl set-ntp true >/dev/null 2>&1; ping -c1 -W5 8.8.8.8 >/dev/null 2>&1 && echo NET_""UP || echo NET_""DOWN'
wait_for "NET_UP" 60 || { echo "FAIL: no network"; exit 1; }
echo "  network up"

say "fetching installer"
echo "  fetch: $INSTALLER_URL"
echo "  guest INSTALLER_URL: $GUEST_URL"
send "curl -fsSL -o /root/install.sh '$INSTALLER_URL' && echo FETCH_\"\"OK || echo FETCH_\"\"FAIL"
wait_for "FETCH_OK" 90 || { echo "FAIL: fetch failed"; exit 1; }
echo "  fetched"

say "RUNNING REAL INSTALLER (the actual USB-boot path)"
send "INSTALLER_URL='$GUEST_URL' bash /root/install.sh > /root/inst.log 2>&1; echo HARNESS_\"\"RC=\$? INSTALL_\"\"FINISHED"
if wait_for "INSTALL_FINISHED" "$INSTALL_TIMEOUT"; then
	say "INSTALLER RETURNED: $(strip <"$LOG" | grep -ao 'HARNESS_RC=[0-9]*' | tail -1)"
	send 'echo LOGTAIL_""MARK; tail -n 30 /root/inst.log; echo LOGEND_""MARK'
	wait_for "LOGEND_MARK" 60
	strip <"$LOG" | sed -n '/^LOGTAIL_MARK/,/^LOGEND_MARK/p' | grep -v '^\s*$'
elif ! qm status "$VMID" | grep -q running; then
	say "VM POWERED OFF — installer reached its reboot step"
else
	say "TIMEOUT after ${INSTALL_TIMEOUT}s"
	strip <"$LOG" | tail -30
fi
