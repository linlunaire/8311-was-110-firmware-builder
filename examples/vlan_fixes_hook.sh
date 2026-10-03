#!/bin/sh
# Copy to /ptconf/8311/vlan_fixes_hook.sh and select "Hook script only".
# Replace 0 with the confirmed service VLANs. IPTV stays disabled by default.
INTERNET_VLAN="${INTERNET_VLAN:-0}"
IPTV_VLAN="${IPTV_VLAN:-0}"
INTERNET_CONVERT="${INTERNET_CONVERT:-0}"
IPTV_ENABLED="${IPTV_ENABLED:-0}"

apply_local_vlan_hook() {
	case "$INTERNET_VLAN:$INTERNET_CONVERT:$IPTV_VLAN" in
		*[!0-9:]*|:*|*::*|*:) echo "Invalid VLAN value" >&2; return 1 ;;
	esac
	[ "$INTERNET_VLAN" -ge 1 ] && [ "$INTERNET_VLAN" -le 4094 ] &&
		[ "$INTERNET_CONVERT" -eq 0 ] || {
		echo "Internet VLAN must be 1-4094; this hook requires untagged Internet" >&2
		return 1
	}
	case "$IPTV_ENABLED" in
		0) ;;
		1)
			[ "$IPTV_VLAN" -ge 1 ] && [ "$IPTV_VLAN" -le 4094 ] || {
				echo "IPTV VLAN must be 1-4094" >&2; return 1
			}
			[ -d /sys/class/net/eth0_0_2 ] || { echo "IPTV interface is unavailable" >&2; return 1; }
			;;
		*) echo "IPTV_ENABLED must be 0 or 1" >&2; return 1 ;;
	esac
	[ -d /sys/class/net/eth0_0 ] || { echo "Internet interface is unavailable" >&2; return 1; }
	type tc_flower_replace >/dev/null 2>&1 || . /lib/8311-vlans-lib.sh || return 1

	# Replace only these exact selectors; retain driver and unrelated filters.
	tc_flower_replace dev eth0_0 egress handle 0x1 protocol 802.1Q pref 1 flower skip_sw \
		vlan_id "$INTERNET_VLAN" action vlan pop pass || return $?
	tc_flower_replace dev eth0_0 egress handle 0x2 protocol 802.1Q pref 2 flower skip_sw action pass || return $?
	tc_flower_replace dev eth0_0 ingress handle 0x1 protocol 802.1Q pref 1 flower skip_sw action pass || return $?
	tc_flower_replace dev eth0_0 ingress handle 0x2 protocol all pref 2 flower skip_sw \
		action vlan push id "$INTERNET_VLAN" protocol 802.1Q pass || return $?

	if [ "$IPTV_ENABLED" = 1 ]; then
		# These rules normalize one outer tag; they do not flatten QinQ.
		tc_flower_replace dev eth0_0_2 egress handle 0x1 protocol 802.1ad pref 1 flower skip_sw \
			action vlan modify id "$IPTV_VLAN" protocol 802.1Q pass || return $?
		tc_flower_replace dev eth0_0_2 egress handle 0x2 protocol 802.1Q pref 2 flower skip_sw \
			action vlan modify id "$IPTV_VLAN" protocol 802.1Q pass || return $?
		tc_flower_replace dev eth0_0_2 egress handle 0x3 protocol all pref 3 flower skip_sw \
			action vlan push id "$IPTV_VLAN" protocol 802.1Q pass || return $?
	fi
}

apply_local_vlan_hook
