#!/bin/sh
# Serialize all web boot-selection changes with the firmware installer.
set -e
umask 077
. /lib/8311-limits.sh || exit 1
fail() { printf '%s\n' "$1" >&2; exit 1; }
case "${1-}" in
	trial) [ "$#" -eq 2 ] || exit 2; case "$2" in A|B) TARGET=$2 ;; *) exit 2 ;; esac ;;
	commit|reboot) [ "$#" -eq 1 ] || exit 2 ;;
	*) exit 2 ;;
esac
exec 9>/tmp/8311-firmware-upgrade.lock
flock -n 9 || fail "Another firmware operation is in progress."
ACTIVE=$(grep -E -o '\brootfsname=rootfs[AB]\b' /proc/cmdline | grep -E -o '[AB]$')
case "$ACTIVE" in A|B) ;; *) fail "The active bank is unknown." ;; esac
ENVIRONMENT=$(mktemp /tmp/8311-boot-env.XXXXXX) || fail "Cannot stage the boot environment."
trap 'rm -f "$ENVIRONMENT"' 0
trap 'exit 1' HUP INT TERM
capture "$ENVIRONMENT" 1048576 3 fw_printenv || fail "Cannot read the boot environment."
DEFAULT=$(awk -F= '$1 == "commit_bank" {print substr($0, 13)}' "$ENVIRONMENT")
case "$DEFAULT" in A|B) ;; *) fail "The default bank is unknown." ;; esac
ACTIVATE=$(awk -F= '$1 == "img_activate" {print substr($0, 14)}' "$ENVIRONMENT")
case "$ACTIVATE" in ''|A|B) ;; *) fail "The next boot bank is unknown." ;; esac
set_env() {
	local VALUE
	fwenv_set -- "$1" "$2" && VALUE=$(fwenv_get "$1") && [ "$VALUE" = "$2" ] ||
		fail "Boot selection could not be saved."
}
check_bank() {
	timeout -k 2 25 /usr/sbin/8311-bank-check.sh "$1" >/dev/null || fail "The selected bank is empty, incomplete or unreadable."
}
case "$1" in
	trial)
		[ "$ACTIVE" = "$DEFAULT" ] && [ "$TARGET" != "$ACTIVE" ] || fail "Confirm or leave the current trial before starting another."
		check_bank "$TARGET"
		[ "$(fwenv_get "img_valid$TARGET" || true)" = true ] || set_env "img_valid$TARGET" true
		set_env img_activate "$TARGET"
		;;
	commit)
		[ -z "$ACTIVATE" ] || fail "Boot the selected trial before confirming it."
		check_bank "$ACTIVE"
		[ "$DEFAULT" = "$ACTIVE" ] || set_env commit_bank "$ACTIVE"
		printf 'Current firmware confirmed.\n'
		exit 0
		;;
	reboot)
		TARGET=${ACTIVATE:-$DEFAULT}
		case "$TARGET" in A|B) ;; *) fail "The next boot bank is unknown." ;; esac
		check_bank "$TARGET"
		;;
esac
printf 'Rebooting...\n'
# The child retains the lock until reboot; close output pipes so LuCI can reply.
( sleep 3; reboot ) >/dev/null 2>&1 &
