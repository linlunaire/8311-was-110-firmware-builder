#!/bin/sh
# Serialize all web boot-selection changes with the firmware installer.
set -e
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
DEFAULT=$(fwenv_get commit_bank)
case "$DEFAULT" in A|B) ;; *) fail "The default bank is unknown." ;; esac
ACTIVATE=$(fwenv_get img_activate || true)
set_env() {
	fwenv_set -- "$1" "$2" && [ "$(fwenv_get "$1")" = "$2" ] || fail "Boot selection could not be saved."
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
