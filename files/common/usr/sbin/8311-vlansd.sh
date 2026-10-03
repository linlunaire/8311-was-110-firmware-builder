#!/bin/sh

_lib_8311 2>/dev/null || . /lib/8311.sh

# Repeated init calls must not start competing monitors.
exec 9>/tmp/8311-vlansd.lock
flock -n 9 || exit 0

HOOK="/ptconf/8311/vlan_fixes_hook.sh"
RELOAD="/tmp/8311-vlans.reload"
OUTPUT=$(mktemp /tmp/8311-vlans.XXXXXX) || exit 1
trap 'rm -f "$OUTPUT"' 0
trap 'exit 0' HUP INT TERM

FIX_ENABLED=$(fwenv_get_8311 "fix_vlans" "1")
LAST_HASH=""
REDETECT=false
RETRY_DELAY=5

echo "8311 VLANs daemon: start monitoring" | to_console
while true; do
	DELAY=5
	FAILED=false
	# Consume the notification before applying so a concurrent save is not lost.
	if [ -f "$RELOAD" ]; then
		rm -f "$RELOAD"
		FIX_ENABLED=$(fwenv_get_8311 "fix_vlans" "1")
		LAST_HASH=""
		REDETECT=true
		RETRY_DELAY=5
	fi

	CMD=""
	case "$FIX_ENABLED" in
		1) CMD="/usr/sbin/8311-fix-vlans.sh" ;;
	esac
	if [ "$FIX_ENABLED" = "1" ] || [ "$FIX_ENABLED" = "2" ]; then
		if [ -f "$HOOK" ]; then
			[ -z "$CMD" ] || CMD="$CMD && "
			CMD="$CMD. /lib/8311-vlans-lib.sh && . $HOOK"
		fi
	fi

	if [ -n "$CMD" ] && [ -d "/sys/devices/virtual/net/gem-omci" ]; then
		# File output avoids holding a command-substitution pipe open if a timed
		# out hook leaves a descendant running. flock remains the overlap guard.
		if timeout -k 2 10 /usr/sbin/8311-detect-config.sh -H > "$OUTPUT" 2>&1 &&
			grep -Eq '^[0-9a-fA-F]{64}$' "$OUTPUT"; then
			HASH=$(cat "$OUTPUT")
			HOOK_HASH="absent"
			if [ -f "$HOOK" ]; then
				HOOK_HASH=$(sha256sum "$HOOK") || FAILED=true
			fi
			HASH="$HASH:$HOOK_HASH"
			if ! $FAILED && [ "$HASH" != "$LAST_HASH" ]; then
				# Cached detection also contains the old local VLAN settings.
				$REDETECT && CMD="rm -f /tmp/8311-config.sh && $CMD"
				if timeout -k 5 30 flock -n /tmp/8311-fix-vlans.lock -c "$CMD" > "$OUTPUT" 2>&1; then
					LAST_HASH="$HASH"
					REDETECT=false
					RETRY_DELAY=5
					echo "8311 VLANs daemon: configuration applied" | to_console
					tail -c 8192 "$OUTPUT" | to_console
				else
					FAILED=true
				fi
			fi
		else
			FAILED=true
		fi
	fi

	if $FAILED; then
		DELAY=$RETRY_DELAY
		echo "8311 VLANs daemon: detection or apply failed; retry in $DELAY seconds" | to_console
		RETRY_DELAY=$((RETRY_DELAY * 2))
		[ "$RETRY_DELAY" -le 60 ] || RETRY_DELAY=60
	fi
	# Keep the healthy-state recovery interval. Only failed work backs off.
	sleep "$DELAY"
done
