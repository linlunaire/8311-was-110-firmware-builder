#!/bin/sh /etc/rc.common

_lib_8311 2>/dev/null || . /lib/8311.sh

START=17

boot() {
	FWENV_BACK="/ptconf/8311/fwenvs_backup.env"
	if [ ! -f "$FWENV_BACK" ]; then
		umask 077
		mkdir -p /ptconf/8311 || return 1
		local work=$(mktemp -d /tmp/8311-reset.XXXXXX)
		[ -n "$work" ] || return 1
		# A failed reader must never create the marker or authorize a partial reset.
		if ! timeout -k 1 5 fw_printenv > "$work/environment"; then
			rm -rf "$work"
			return 1
		fi
		echo "Backing up existing 8311 fwenvs before resetting them..." | to_console
		if ! awk '/^8311_[^=]+=/ { print }' "$work/environment" > "$work/backup" ||
			! cp "$work/backup" "$FWENV_BACK.incoming" || ! mv "$FWENV_BACK.incoming" "$FWENV_BACK"; then
			rm -f "$FWENV_BACK.incoming"
			rm -rf "$work"
			return 1
		fi

		rm -rf "$work"
		while IFS='=' read -r FWENV VALUE; do
			echo "Clearing fwenv '$FWENV'..." | to_console
			fwenv_set -- "$FWENV" || return 1
		done < "$FWENV_BACK"

		echo "Rebooting" | to_console
		reboot
		return 1
	fi
}
