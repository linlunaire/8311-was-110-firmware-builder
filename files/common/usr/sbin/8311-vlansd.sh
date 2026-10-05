#!/bin/sh

_lib_8311 2>/dev/null || . /lib/8311.sh

# Repeated init calls must not start competing monitors.
exec 9>/tmp/8311-vlansd.lock
flock -n 9 || exit 0

HOOK="/ptconf/8311/vlan_fixes_hook.sh"
RELOAD="/tmp/8311-vlans.reload"
OUTPUT=$(mktemp /tmp/8311-vlans.XXXXXX) || exit 1
STATUS="/tmp/8311-vlans.status"
STATUS_TMP="$OUTPUT.status"
umask 077
trap 'rm -f "$OUTPUT" "$STATUS_TMP"' 0
trap 'exit 0' HUP INT TERM

FIX_ENABLED=$(fwenv_get_8311 "fix_vlans" "1")
LAST_HASH=""
LAST_RULE_HASH=""
RULE_CHECK_CYCLES=0
REDETECT=false
RETRY_DELAY=5
LAST_APPLIED=0
LAST_STATUS=""

publish_status() {
	local key="$1:$2:$3:$FIX_ENABLED:$LAST_APPLIED"
	[ "$key" != "$LAST_STATUS" ] || return 0
	local mode="$FIX_ENABLED"
	case "$mode" in 0|1|2) ;; *) mode=unknown ;; esac
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$$" "$(date +%s)" "$LAST_APPLIED" \
		"$mode" "$1" "$2" "$3" > "$STATUS_TMP" &&
		mv -f "$STATUS_TMP" "$STATUS" || return 1
	LAST_STATUS="$key"
}

read_fingerprint() {
	local value
	value=$(cat "$OUTPUT") || return 1
	[ "${#value}" -eq 64 ] || return 1
	case "$value" in *[!0-9a-fA-F]*) return 1 ;; esac
	printf '%s\n' "$value"
}

publish_status starting none 0

echo "8311 VLANs daemon: start monitoring" | to_console
while true; do
	DELAY=5
	FAILED=false
	FAIL_STAGE=none
	# Consume the notification before applying so a concurrent save is not lost.
	if [ -f "$RELOAD" ]; then
		rm -f "$RELOAD"
		FIX_ENABLED=$(fwenv_get_8311 "fix_vlans" "1")
		LAST_HASH=""
		LAST_RULE_HASH=""
		RULE_CHECK_CYCLES=0
		REDETECT=true
		RETRY_DELAY=5
		publish_status scheduled none 0
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
			HASH=$(read_fingerprint); then
			HOOK_HASH="absent"
			if [ -f "$HOOK" ]; then
				HOOK_HASH=$(sha256sum "$HOOK") || { FAILED=true; FAIL_STAGE=hook; }
			fi
			HASH="$HASH:$HOOK_HASH"
			# Every six healthy cycles, check rules even if the topology did not
			# change. Driver/OLT updates can remove filters from existing links.
			if ! $FAILED && [ -n "$LAST_HASH" ] && [ "$RULE_CHECK_CYCLES" -le 0 ]; then
				if timeout -k 1 10 /usr/sbin/8311-vlan-rules-hash.sh > "$OUTPUT" 2>&1 &&
					RULE_HASH=$(read_fingerprint); then
					RULE_CHECK_CYCLES=6
					if [ "$RULE_HASH" != "$LAST_RULE_HASH" ]; then
						LAST_HASH=""
						REDETECT=true
					fi
				else
					FAILED=true
					FAIL_STAGE=rules
				fi
			fi
			if ! $FAILED && [ "$HASH" != "$LAST_HASH" ]; then
				# Cached detection also contains the old local VLAN settings.
				$REDETECT && CMD="rm -f /tmp/8311-config.sh && $CMD"
				publish_status applying none 0
				if timeout -k 5 30 flock -n /tmp/8311-fix-vlans.lock -c "$CMD" > "$OUTPUT" 2>&1; then
					tail -c 8192 "$OUTPUT" | to_console
					if timeout -k 1 10 /usr/sbin/8311-vlan-rules-hash.sh > "$OUTPUT" 2>&1 &&
						LAST_RULE_HASH=$(read_fingerprint); then
						RULE_CHECK_CYCLES=6
						LAST_HASH="$HASH"
						REDETECT=false
						RETRY_DELAY=5
						LAST_APPLIED=$(date +%s)
						publish_status applied none 0
						echo "8311 VLANs daemon: configuration applied" | to_console
					else
						FAILED=true
						FAIL_STAGE=rules
					fi
				else
					FAILED=true
					FAIL_STAGE=apply
				fi
			elif ! $FAILED; then
				RETRY_DELAY=5
				publish_status applied none 0
			fi
		else
			FAILED=true
			FAIL_STAGE=detect
		fi
	else
		# A recreated PON interface needs rules even if its final topology is
		# identical to the previous snapshot.
		LAST_HASH=""
		LAST_RULE_HASH=""
		RULE_CHECK_CYCLES=0
		REDETECT=true
		case "$FIX_ENABLED" in
			0) publish_status disabled none 0 ;;
			2) if [ -z "$CMD" ]; then publish_status waiting hook 0; else publish_status waiting pon 0; fi ;;
			1) publish_status waiting pon 0 ;;
			*) publish_status error configuration 0 ;;
		esac
	fi

	if $FAILED; then
		DELAY=$RETRY_DELAY
		publish_status error "$FAIL_STAGE" "$DELAY"
		echo "8311 VLANs daemon: detection or apply failed; retry in $DELAY seconds" | to_console
		RETRY_DELAY=$((RETRY_DELAY * 2))
		[ "$RETRY_DELAY" -le 60 ] || RETRY_DELAY=60
	fi
	# Keep the healthy-state recovery interval. Only failed work backs off.
	sleep "$DELAY"
	[ "$RULE_CHECK_CYCLES" -le 0 ] || RULE_CHECK_CYCLES=$((RULE_CHECK_CYCLES - 1))
done
