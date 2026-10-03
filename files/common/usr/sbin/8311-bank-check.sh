#!/bin/sh
# Read-only checks for WAS-110 legacy uImages and its SquashFS root filesystem.
# A successful check is a prerequisite for a trial boot, not a boot guarantee.
set -e
QUICK=false
if [ "${1-}" = --quick ]; then QUICK=true; shift; fi
case "${1-}" in A|B) [ "$#" -eq 1 ] || exit 2; BANK=$1 ;; *) exit 2 ;; esac
umask 077
WORK=$(mktemp -d /tmp/8311-bank-check.XXXXXX) || exit 1
MOUNTED=false
cleanup() {
	if $MOUNTED; then umount "$WORK/root" 2>/dev/null || return; fi
	rm -rf "$WORK"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM
fail() { printf '%s\n' "$1" >&2; exit 1; }
hex() { hexdump -v -s "$1" -n "$2" -e '1/1 "%02x"' "$WORK/header"; }

# A failed installer deliberately leaves this false even if old headers remain.
if [ "$(fw_printenv -n "img_valid$BANK" 2>/dev/null)" = false ]; then fail incomplete-bank; fi

for part in kernel bootcore rootfs; do
	INFO=$(ubinfo /dev/ubi0 -N "$part$BANK" 2>/dev/null) || fail "missing-$part"
	ID=$(printf '%s\n' "$INFO" | awk '/^Volume ID:/ {print $3}')
	CAPACITY=$(printf '%s\n' "$INFO" | tr '(),' '   ' | awk '/^Size:/ {print $4}')
	case "$ID:$CAPACITY" in *[!0-9:]*|:*|*:) fail "invalid-$part-volume" ;; esac
	[ "$CAPACITY" -ge 96 ] && [ "$CAPACITY" -le 134217728 ] || fail "invalid-$part-capacity"
	VOLUME="/dev/ubi0_$ID"
	if [ "$part" = rootfs ]; then
		head -c 96 "$VOLUME" > "$WORK/header" || fail unreadable-rootfs
		[ "$(wc -c < "$WORK/header")" -eq 96 ] || fail short-rootfs
		[ "$(hex 0 4)" = 68737173 ] && [ "$(hex 28 4)" = 04000000 ] || fail unrecognized-rootfs
		[ "$(hex 44 4)" = 00000000 ] || fail oversized-rootfs
		LITTLE=$(hex 40 4 | sed 's/^\(..\)\(..\)\(..\)\(..\)$/\4\3\2\1/')
		SIZE=$((0x$LITTLE))
		[ "$SIZE" -ge 96 ] && [ "$SIZE" -le "$CAPACITY" ] || fail invalid-rootfs-size
		$QUICK && continue
		MTD=$(awk -v name="\"rootfs$BANK\"" '$4 == name {sub(/^mtd/, "", $1); sub(/:$/, "", $1); print $1}' /proc/mtd)
		case "$MTD" in ''|*[!0-9]*) fail missing-rootfs-block ;; esac
		mkdir "$WORK/root"
		mount -t squashfs -o ro "/dev/mtdblock$MTD" "$WORK/root" 2>/dev/null || fail unreadable-rootfs
		MOUNTED=true
		[ -r "$WORK/root/etc/inittab" ] && [ -r "$WORK/root/etc/preinit" ] &&
			[ -s "$WORK/root/bin/busybox" ] || fail incomplete-rootfs
	else
		head -c 64 "$VOLUME" > "$WORK/header" || fail "unreadable-$part"
		[ "$(wc -c < "$WORK/header")" -eq 64 ] || fail "short-$part"
		[ "$(hex 0 4)" = 27051956 ] && [ "$(hex 28 3)" = 050502 ] || fail "unrecognized-$part"
		SIZE_HEX=$(hex 12 4)
		SIZE=$((0x$SIZE_HEX))
		[ "$SIZE" -gt 0 ] && [ "$SIZE" -le "$((CAPACITY - 64))" ] || fail "invalid-$part-size"
		HEADER_CRC=$({ head -c 4 "$WORK/header"; printf '\000\000\000\000'; tail -c +9 "$WORK/header"; } | crc32)
		[ "$HEADER_CRC" = "$(hex 4 4)" ] || fail "corrupt-$part-header"
		$QUICK && continue
		tail -c +65 "$VOLUME" | head -c "$SIZE" > "$WORK/data"
		[ "$(wc -c < "$WORK/data")" -eq "$SIZE" ] || fail "incomplete-$part"
		[ "$(crc32 "$WORK/data" | awk '{print $1}')" = "$(hex 24 4)" ] || fail "corrupt-$part"
	fi
done
printf 'ready\n'
