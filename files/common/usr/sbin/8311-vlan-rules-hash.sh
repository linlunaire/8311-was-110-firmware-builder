#!/bin/sh
# Fingerprint rule structure, excluding counters and action lifetime metadata.
# Keep this separate from the topology hash: applying rules changes this hash.
umask 077
export LC_ALL=C
OUTPUT=$(mktemp /tmp/8311-rule-state.XXXXXX) || exit 1
NORMALIZED=
trap 'rm -f "$OUTPUT"; [ -z "$NORMALIZED" ] || rm -f "$NORMALIZED"' 0
trap 'exit 1' HUP INT TERM
NORMALIZED=$(mktemp /tmp/8311-rule-normalized.XXXXXX) || exit 1
COUNT=0
for path in /sys/class/net/eth0_* /sys/class/net/pmapper*; do
	[ -d "$path" ] || continue
	COUNT=$((COUNT + 1))
	[ "$COUNT" -le 32 ] || exit 1
	device=${path##*/}
	for direction in ingress egress; do
		printf '%s %s\n' "$device" "$direction" >> "$OUTPUT" || exit 1
		tc filter show dev "$device" "$direction" >> "$OUTPUT" 2>/dev/null || exit 1
		[ "$(wc -c < "$OUTPUT")" -le 1048576 ] || exit 1
	done
done
[ "$COUNT" -gt 0 ] || exit 1
sed '/^[[:space:]]*index /d; /^[[:space:]]*in_hw/d; /^[[:space:]]*not_in_hw/d; /^[[:space:]]*used_hw_stats /d' \
	"$OUTPUT" > "$NORMALIZED" || exit 1
HASH=$(sha256sum < "$NORMALIZED") || exit 1
# Require precisely one stdin checksum; reject extra lines/diagnostics.
case "$HASH" in "${HASH%% *}  -"|"${HASH%% *} *-") ;; *) exit 1 ;; esac
HASH=${HASH%% *}
[ "${#HASH}" -eq 64 ] || exit 1
case "$HASH" in *[!0-9a-f]*) exit 1 ;; esac
printf '%s\n' "$HASH"
