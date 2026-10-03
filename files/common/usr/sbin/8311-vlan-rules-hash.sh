#!/bin/sh
# Fingerprint rule structure, excluding counters and action lifetime metadata.
# Keep this separate from the topology hash: applying rules changes this hash.
umask 077
export LC_ALL=C
OUTPUT=$(mktemp /tmp/8311-rule-state.XXXXXX) || exit 1
trap 'rm -f "$OUTPUT"' 0
trap 'exit 1' HUP INT TERM
COUNT=0
for path in /sys/class/net/eth0_* /sys/class/net/pmapper*; do
	[ -d "$path" ] || continue
	COUNT=$((COUNT + 1))
	[ "$COUNT" -le 32 ] || exit 1
	device=${path##*/}
	for direction in ingress egress; do
		printf '%s %s\n' "$device" "$direction" >> "$OUTPUT"
		tc filter show dev "$device" "$direction" >> "$OUTPUT" 2>/dev/null || exit 1
		[ "$(wc -c < "$OUTPUT")" -le 1048576 ] || exit 1
	done
done
[ "$COUNT" -gt 0 ] || exit 1
sed '/^[[:space:]]*index /d; /^[[:space:]]*in_hw/d; /^[[:space:]]*not_in_hw/d; /^[[:space:]]*used_hw_stats /d' \
	"$OUTPUT" | sha256sum | awk '{print $1}'
