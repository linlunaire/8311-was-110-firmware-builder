#!/bin/sh
_err() {
	echo "$1" >&2
	exit ${2:-1}
}

_help() {
	printf -- 'Tool for validating and installing prx126-sfp-pon firmware upgrades.\n\n'
	printf -- 'Usage: %s [options] <firmware upgrade tar file>\n\n' "$0"
	printf -- 'Options:\n'
	printf -- '-v|--validate\t\tValidate images from the firmware upgrade tar file.\n'
	printf -- '-i|--install\t\tValidate and install images to the inactive firmware bank.\n'
	printf -- '-r|--reboot\t\tReboot after a successful firmware upgrade.\n'
	printf -- '--no-commit\t\tKeep the current default boot bank after installation.\n'
	printf -- '--trial\t\t\tSelect the installed bank for one boot; keep the current default.\n'
	printf -- '-y|--yes\t\tAnswer yes to any prompts.\n'
	printf -- '-h|--help\t\tThis help text.\n\n'
	printf -- '--\t\t\tDon'"'"'t process any further options, the next parameter is the firmware upgrade tar file.\n'
}

_yesno() {
	local DEFAULT=false
	[ "$1" = "y" ] && DEFAULT=true

	local yes
	read yes
	yes=$(echo "$yes" | tr 'YES' 'yes')

	if [ -n "$yes" ]; then
		[ "$yes" = "y" ] || [ "$yes" = "ye" ] || [ "$yes" = "yes" ]
	else
		$DEFAULT
	fi
}

VALIDATE=false
INSTALL=false
YES=false
REBOOT=false
NO_COMMIT=false
TRIAL=false
TAR=
while [ $# -gt 0 ]; do
	case "$1" in
		-h|--help)
			_help
			exit 0
		;;
		-v|--validate)
			VALIDATE=true
		;;
		
		-i|--install)
			INSTALL=true
		;;
		-y|--yes)
			YES=true
		;;
		-r|--reboot)
			REBOOT=true
		;;
		--no-commit) NO_COMMIT=true ;;
		--trial) TRIAL=true; NO_COMMIT=true ;;
		--)
			[ $# -eq 2 ] && [ -z "$TAR" ] || { _help; exit 1; }
			TAR="$2"
			break
		;;
		-*)
			_help
			exit 1
		;;
		*)
			if [ -n "$TAR" ]; then
				_help
				exit 1
			fi

			TAR="$1"
		;;
	esac
	shift
done

if $NO_COMMIT && $REBOOT && ! $TRIAL; then
	_err "Use --trial with --no-commit to reboot into the installed image."
fi

if ! $VALIDATE && ! $INSTALL; then
	VALIDATE=true
	INSTALL=true
fi

if [ -z "$TAR" ]; then
	_help
	exit 1
fi

if [ ! -r "$TAR" ]; then
	_err "Upgrade file '$TAR' not found."
fi

control_var() {
	[ -n "$1" ] || return 1
	echo "$CONTROL" | grep "^$1=" | cut -d= -f2-
}

sha256() {
	sha256sum "$@" | awk '{print $1}'
}

active_fwbank() {
	grep -E -o '\brootfsname=rootfs[AB]\b' /proc/cmdline | grep -E -o '[AB]$'
}

inactive_fwbank() {
	local active_bank=$(active_fwbank)
	if [ "$active_bank" = "A" ]; then
		echo "B"
	elif [ "$active_bank" = "B" ]; then
		echo "A"
	else
		return 1
	fi

	return 0
}

fwenv_set() {
	[ -n "$1" ] || return 1

	for i in 0 1; do
		fw_setenv "$1" "$2" || return $?
	done
	[ "$(fw_printenv -n "$1" 2>/dev/null)" = "$2" ]
}

ubi_default_order() {
	case "$1" in
		kernelA) echo "0"; ;;
		bootcoreA) echo "1"; ;;
		rootfsA) echo "2"; ;;
		kernelB) echo "3"; ;;
		bootcoreB) echo "4"; ;;
		rootfsB) echo "5"; ;;
		*) return 1; ;;
	esac
}

ubi_dev() {
	local NAME="$1"
	[ -n "$NAME" ] || _err "Must specify name for UBI volume name."
	VOL=$(ubinfo /dev/ubi0 -N "$NAME" 2>/dev/null | grep "Volume ID:" | awk '{print $3}')
	[ "$VOL" -ge 0 ] 2>/dev/null || return 1
	echo "/dev/ubi0_$VOL"
}

ubi_size() {
	local NAME="$1"
	[ -n "$NAME" ] || _err "Must specify name for UBI volume name."
	SIZE=$(ubinfo /dev/ubi0 -N "$NAME" 2>/dev/null | grep "Size:" | tr '(),' '   ' | awk '{print $4}')
	[ -n "$SIZE" ] || return 1
	echo "$SIZE"
}

ubi_create() {
	local NAME="$1"
	local SIZE="$2"
	local VOL="$3"

	echo "Creating $NAME UBI volume..."
	ubimkvol /dev/ubi0 -n "$VOL" -N "$NAME" -s "$SIZE" || ubimkvol /dev/ubi0 -n "$VOL" -N "$NAME" || _err "Error creating $NAME UBI volume."
}

ubi_resize() {
	local NAME="$1"
	local SIZE="$2"
	[ "$SIZE" -gt 0 ] 2>/dev/null || _err "Size of partition to resize must be > 0."

	echo "Resizing $NAME UBI volume to $SIZE bytes..."
	ubirsvol /dev/ubi0 -N "$NAME" -s "$SIZE" || _err "Error resizing $NAME UBI volume."
}

validate_image() {
	local VAR="$1"
	local FILE="$2"
	local NAME="$3"
	local SHA256=$(control_var "SHA256_$VAR")
	local SIZE=$(control_var "SIZE_$VAR")
	local IMAGE="$WORKDIR/$FILE"

	[ "${#SHA256}" -eq 64 ] || _err "$NAME hash missing or invalid in control file."
	case "$SHA256" in *[!0-9a-fA-F]*) _err "$NAME hash invalid in control file." ;; esac
	case "$SIZE" in ''|*[!0-9]*) _err "$NAME size missing or invalid in control file." ;; esac
	[ "$SIZE" -gt 0 ] 2>/dev/null || _err "$NAME size must be greater than zero."
	SHA256=$(printf '%s' "$SHA256" | tr 'A-F' 'a-f')
	echo -n "Validating $NAME image..."
	# Stage only named members, never archive paths. Install the exact bytes checked here.
	tar x -f "$TAR" -O -- "$FILE" > "$IMAGE" 2>/dev/null || _err "Unable to extract $NAME image."
	[ "$(wc -c < "$IMAGE")" -eq "$SIZE" ] || _err "$NAME image size does not match control file."
	local ACTUAL_SHA256=$(sha256 "$IMAGE")
	[ "$ACTUAL_SHA256" = "$SHA256" ] && echo " OK" || { echo " FAILED";  _err "Image $NAME hash '$ACTUAL_SHA256' does not match expected '$SHA256'."; }
	# Validation-only runs do not need to retain all three images at once.
	$INSTALL || rm -f "$IMAGE"
}

install_image() {
	local VAR="$1"
	local FILE="$2"
	local NAME="$3"
	local UBI_VOLNAME="$4"
	
	local SHA256=$(control_var "SHA256_$VAR" | tr 'A-F' 'a-f')
	local SIZE=$(control_var "SIZE_$VAR")

	[ -z "$SHA256" ] && _err "$NAME hash not found in control file."
	[ -z "$SIZE" ] && _err "$NAME file size not found in control file."

	local UBI=$(ubi_dev "$UBI_VOLNAME")
	local UBI_VOL=$(ubi_default_order "$UBI_VOLNAME")
	[ "$UBI_VOL" -ge 0 ] 2>/dev/null || _err "Invalid UBI volume '$UBI_VOLNAME'."
	if [ -z "$UBI" ]; then
		ubi_create "$UBI_VOLNAME" "$SIZE" "$UBI_VOL"
		UBI=$(ubi_dev "$UBI_VOLNAME")
		[ -n "$UBI" ] || _err "Error finding UBI volume '$UBI_VOLNAME' after create."
	else
		UBI_SIZE=$(ubi_size "$UBI_VOLNAME")
		[ -n "$UBI_SIZE" ] || _err "Invalid UBI volume '$UBI_VOLNAME' while resizing."
		if [ "$UBI_SIZE" -lt "$SIZE" ]; then
			ubi_resize "$UBI_VOLNAME" "$SIZE"
		fi
	fi
	

	echo "Installing $NAME image to $UBI_VOLNAME ($UBI)..."
	ubiupdatevol -s "$SIZE" "$UBI" - < "$WORKDIR/$FILE" || _err "Error installing $NAME to '$UBI'."
	echo -n "Validating installed $NAME image..."
	ACTUAL_SHA256=$(head -c "$SIZE" "$UBI" | sha256)
	[ "$ACTUAL_SHA256" = "$SHA256" ] && echo " OK" || { echo " FAILED";  _err "Installed image $NAME hash '$ACTUAL_SHA256' does not match expected '$SHA256'."; }
}

# Keep the lock inode in place; unlinking it permits a second upgrader to lock a
# different inode. The subshell's exit status must reach CLI and LuCI callers.
umask 077
LOCK="/tmp/8311-firmware-upgrade.lock"
(
	flock -n 9 || _err "Firmware upgrade already in progress."
	WORKDIR=$(mktemp -d /tmp/8311-upgrade.XXXXXX) || _err "Cannot create upgrade staging directory."
	trap 'rm -rf "$WORKDIR"' 0
	trap 'exit 1' HUP INT TERM

	CONTROL=$(tar x -f "$TAR" -O -- control 2>/dev/null) || _err "Invalid firmware upgrade tar, cannot read control file."
	[ -n "$CONTROL" ] || _err "Invalid firmware upgrade tar, control file not found."
	FW_VERSION=$(control_var FW_VERSION)
	FW_REVISION=$(control_var FW_REVISION)
	FW_VARIANT=$(control_var FW_VARIANT)
	{ [ -n "$FW_VERSION" ] && [ -n "$FW_REVISION" ] && [ -n "$FW_VARIANT" ]; } || _err "Missing firmware version information."

	echo "New Firmware:"
	echo "Version: $FW_VERSION"
	echo "Revision: $FW_REVISION"
	echo "Variant: $FW_VARIANT"
	echo

	# --install always validates every image before any UBI or boot-env write.
	validate_image "KERNEL" "kernel.bin" "Kernel"
	validate_image "BOOTCORE" "bootcore.bin" "Bootcore"
	validate_image "ROOTFS" "rootfs.img" "RootFS"
	echo
	$INSTALL || exit 0

	INSTALL_BANK=$(inactive_fwbank) || _err "Cannot determine the active firmware bank."
	case "$INSTALL_BANK" in A|B) ;; *) _err "Invalid inactive firmware bank." ;; esac
	[ "$(fw_printenv -n commit_bank 2>/dev/null)" = "$(active_fwbank)" ] ||
		_err "Confirm or leave the current trial before installing another firmware."
	echo "Active firmware bank is $(active_fwbank), will install to bank $INSTALL_BANK."

		echo
		if ! $YES; then
			echo -n "Are you sure you want to install this firmware to bank $INSTALL_BANK? (y/N) "
			_yesno || exit 2
		fi

		fwenv_set "img_valid$INSTALL_BANK" false || _err "Cannot mark the target bank incomplete."
		rm -f /tmp/8311-alt-firmware
		install_image "KERNEL" "kernel.bin" "Kernel" "kernel$INSTALL_BANK"
		install_image "BOOTCORE" "bootcore.bin" "Bootcore" "bootcore$INSTALL_BANK"
		install_image "ROOTFS" "rootfs.img" "RootFS" "rootfs$INSTALL_BANK"
		fwenv_set "img_valid$INSTALL_BANK" true || _err "Cannot mark the installed bank complete."

		if $NO_COMMIT; then
			if $TRIAL; then
				fwenv_set img_activate "$INSTALL_BANK" || _err "Cannot select the installed bank for a trial boot."
				echo "Bank $INSTALL_BANK is ready for one trial boot; the default bank is unchanged."
			else
				echo "Firmware installed; the default boot bank is unchanged."
				exit 0
			fi
		else

		echo
		if ! $YES; then
			echo -n "Firmware successfully installed into bank $INSTALL_BANK. Update commit_bank to $INSTALL_BANK? (Y/n) "
			_yesno y || exit 0
		fi

		fwenv_set "commit_bank" "$INSTALL_BANK" && echo "Set commit_bank to $INSTALL_BANK, reboot to boot new firmware." || _err "Error setting commit_bank to $INSTALL_BANK."
		echo
		fi

		if ! $YES && ! $REBOOT; then
			echo -n "Would you like to reboot to the new firmware now? (y/N) "
			_yesno || exit 0
			REBOOT=true
		fi

		if $REBOOT; then
			echo "Rebooting..."
			( sleep 3 && reboot; ) >/dev/null 2>&1 &
		fi
) 9>"$LOCK"
exit $?
