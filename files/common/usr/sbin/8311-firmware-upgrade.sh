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

. /lib/8311-limits.sh || exit 1

sha256() {
	local output
	output=$(sha256sum "$@") || return 1
	local hash=${output%% *}
	[ "${#hash}" -eq 64 ] || return 1
	case "$hash" in *[!0-9a-f]*) return 1 ;; esac
	[ "$output" = "$hash  $1" ] || [ "$output" = "$hash *$1" ] || return 1
	printf '%s\n' "$hash"
}

# Check both producers without copying a complete image into RAM or pipefail.
stream_digest() {
	local algorithm="$1" output reader code=0
	shift
	mkfifo "$WORKDIR/stream" || return 1
	"$@" > "$WORKDIR/stream" &
	reader=$!
	output=$("$algorithm" < "$WORKDIR/stream") || code=1
	wait "$reader" || code=1
	rm -f "$WORKDIR/stream"
	[ "$code" -eq 0 ] || return 1
	printf '%s\n' "$output"
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
	local VALUE

	for i in 0 1; do
		fw_setenv "$1" "$2" || return $?
	done
	VALUE=$(fw_printenv -n "$1" 2>/dev/null) || return 1
	[ "$VALUE" = "$2" ]
}

prepare_volume() {
	local NAME="$1" SIZE="$2" INFO ID CAPACITY
	INFO=$(ubinfo /dev/ubi0 -N "$NAME" 2>/dev/null) || _err "Missing target volume: $NAME."
	ID=$(printf '%s\n' "$INFO" | awk '/^Volume ID:/ {print $3}')
	CAPACITY=$(printf '%s\n' "$INFO" | tr '(),' '   ' | awk '/^Size:/ {print $4}')
	case "$ID:$CAPACITY" in *[!0-9:]*|:*|*:) _err "Invalid target volume: $NAME." ;; esac
	[ "$ID" -le 127 ] && [ "$CAPACITY" -ge "$SIZE" ] || _err "Image does not fit existing $NAME volume."
	printf '/dev/ubi0_%s\n' "$ID"
}

validate_image() {
	local FILE="$1" NAME="$2" SIZE="$3" SHA256="$4" LIMIT="$5"
	local IMAGE="$WORKDIR/$FILE"

	[ "${#SHA256}" -eq 64 ] || _err "$NAME hash missing or invalid in control file."
	case "$SHA256" in *[!0-9a-fA-F]*) _err "$NAME hash invalid in control file." ;; esac
	case "$SIZE" in ''|*[!0-9]*) _err "$NAME size missing or invalid in control file." ;; esac
	[ "$SIZE" -gt 0 ] 2>/dev/null || _err "$NAME size must be greater than zero."
	[ "${#SIZE}" -le 8 ] && [ "$SIZE" -le "$LIMIT" ] || _err "$NAME exceeds the component size limit."
	SHA256=$(printf '%s' "$SHA256" | tr 'A-F' 'a-f') || _err "Unable to normalize $NAME hash."
	echo -n "Validating $NAME image..."
	# Stage only named members, never archive paths. Install the exact bytes checked here.
	capture "$IMAGE" "$LIMIT" 30 tar x -f "$TAR" -O -- "$FILE" || _err "Unable to extract $NAME image."
	[ "$(wc -c < "$IMAGE")" -eq "$SIZE" ] || _err "$NAME image size does not match control file."
	local ACTUAL_SHA256
	ACTUAL_SHA256=$(sha256 "$IMAGE") || _err "Unable to hash $NAME image."
	[ "$ACTUAL_SHA256" = "$SHA256" ] && echo " OK" || { echo " FAILED";  _err "Image $NAME hash '$ACTUAL_SHA256' does not match expected '$SHA256'."; }
	local HEADER="$WORKDIR/header"
	head -c 96 "$IMAGE" > "$HEADER" || _err "Unreadable $NAME header."
	if [ "$FILE" = rootfs.img ]; then
		[ "$SIZE" -ge 96 ] && [ "$(hex 0 4)" = 68737173 ] &&
			[ "$(hex 28 4)" = 04000000 ] && [ "$(hex 44 4)" = 00000000 ] || _err "Unsupported SquashFS image."
		case "$(hex 12 4)" in
			00100000|00200000|00400000|00800000|00000100|00000200|00000400|00000800|00001000) ;;
			*) _err "Invalid SquashFS block size." ;;
		esac
		local used=$(hex 40 4 | sed 's/^\(..\)\(..\)\(..\)\(..\)$/\4\3\2\1/')
		[ "$((0x$used))" -ge 96 ] && [ "$((0x$used))" -le "$SIZE" ] || _err "Invalid SquashFS size."
	else
		[ "$SIZE" -ge 64 ] && [ "$(hex 0 4)" = 27051956 ] &&
			[ "$(hex 28 3)" = 050502 ] || _err "Unsupported MIPS Linux uImage."
		local used
		used=$(hex 12 4) || _err "Unable to read uImage size."
		[ "$((0x$used + 64))" -eq "$SIZE" ] || _err "Invalid uImage payload size."
		head -c 64 "$HEADER" > "$WORKDIR/header.crc" || _err "Unable to check uImage header."
		printf '\000\000\000\000' | dd of="$WORKDIR/header.crc" bs=1 seek=4 conv=notrunc 2>/dev/null || _err "Unable to check uImage header."
		local header_crc
		header_crc=$(crc32 < "$WORKDIR/header.crc") || _err "Unable to check uImage header CRC."
		[ "$header_crc" = "$(hex 4 4)" ] || _err "Invalid uImage header CRC."
		local data_crc
		data_crc=$(stream_digest crc32 tail -c +65 "$IMAGE") || _err "Unable to check uImage payload."
		[ "$data_crc" = "$(hex 24 4)" ] || _err "Invalid uImage data CRC."
	fi
	# Validation-only runs do not need to retain all three images at once.
	$INSTALL || rm -f "$IMAGE"
}

hex() {
	local value
	value=$(hexdump -v -s "$1" -n "$2" -e '1/1 "%02x"' "$WORKDIR/header") || return 1
	[ "${#value}" -eq "$((2 * $2))" ] || return 1
	case "$value" in *[!0-9a-f]*) return 1 ;; esac
	printf '%s' "$value"
}

install_image() {
	local FILE="$1" NAME="$2" UBI_VOLNAME="$3" SIZE="$4" SHA256="$5" UBI="$6"
	SHA256=$(printf '%s' "$SHA256" | tr 'A-F' 'a-f') || _err "Unable to normalize $NAME hash."

	[ -z "$SHA256" ] && _err "$NAME hash not found in control file."
	[ -z "$SIZE" ] && _err "$NAME file size not found in control file."

	echo "Installing $NAME image to $UBI_VOLNAME ($UBI)..."
	ubiupdatevol -s "$SIZE" "$UBI" - < "$WORKDIR/$FILE" || _err "Error installing $NAME to '$UBI'."
	echo -n "Validating installed $NAME image..."
	ACTUAL_SHA256=$(stream_digest sha256sum head -c "$SIZE" "$UBI") || _err "Unable to read back $NAME."
	[ "$ACTUAL_SHA256" = "${ACTUAL_SHA256%% *}  -" ] ||
		[ "$ACTUAL_SHA256" = "${ACTUAL_SHA256%% *} *-" ] || _err "Invalid $NAME readback checksum."
	ACTUAL_SHA256=${ACTUAL_SHA256%% *}
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

	[ "$(wc -c < "$TAR")" -le 134217728 ] || _err "Upgrade archive exceeds 128 MiB."
	require_tmp_space 8192 || _err "Insufficient control staging space."
	capture "$WORKDIR/control" 4096 10 tar x -f "$TAR" -O -- control || _err "Invalid or oversized firmware control file."
	FW_VERSION= FW_REVISION= FW_VARIANT= FW_TARGET=
	SIZE_KERNEL= SIZE_BOOTCORE= SIZE_ROOTFS= SHA256_KERNEL= SHA256_BOOTCORE= SHA256_ROOTFS=
	SEEN='|'
	while IFS= read -r LINE || [ -n "$LINE" ]; do
		[ -n "$LINE" ] || continue
		case "$LINE" in *=*) ;; *) _err "Invalid control field." ;; esac
		KEY=${LINE%%=*}; VALUE=${LINE#*=}
		case "$SEEN" in *"|$KEY|"*) _err "Duplicate control field: $KEY." ;; esac
		SEEN="$SEEN$KEY|"
		case "$KEY" in
			FW_VERSION) FW_VERSION=$VALUE ;; FW_REVISION) FW_REVISION=$VALUE ;;
			FW_VARIANT) FW_VARIANT=$VALUE ;; FW_TARGET) FW_TARGET=$VALUE ;;
			SIZE_KERNEL) SIZE_KERNEL=$VALUE ;; SIZE_BOOTCORE) SIZE_BOOTCORE=$VALUE ;; SIZE_ROOTFS) SIZE_ROOTFS=$VALUE ;;
			SHA256_KERNEL) SHA256_KERNEL=$VALUE ;; SHA256_BOOTCORE) SHA256_BOOTCORE=$VALUE ;; SHA256_ROOTFS) SHA256_ROOTFS=$VALUE ;;
		esac
	done < "$WORKDIR/control"
	{ [ -n "$FW_VERSION" ] && [ -n "$FW_REVISION" ] && [ -n "$FW_VARIANT" ]; } || _err "Missing firmware version information."
	case "$FW_VARIANT" in basic|bfw) ;; *) _err "Unsupported firmware variant." ;; esac
	case "$FW_TARGET" in ''|WAS-110) ;; *) _err "Firmware is for another target." ;; esac
	case "$FW_VERSION:$FW_REVISION" in *[!a-zA-Z0-9._+:~-]*) _err "Invalid firmware version information." ;; esac
	[ "${#FW_VERSION}" -le 64 ] && [ "${#FW_REVISION}" -le 64 ] || _err "Firmware version is too long."
	for SIZE in "$SIZE_KERNEL" "$SIZE_BOOTCORE" "$SIZE_ROOTFS"; do
		case "$SIZE" in ''|*[!0-9]*) _err "Invalid component size." ;; esac
		[ "${#SIZE}" -le 8 ] || _err "Component size is too large."
		case "$SIZE" in 0*) _err "Component sizes must be positive canonical decimals." ;; esac
	done
	[ "$SIZE_KERNEL" -le 8388608 ] && [ "$SIZE_BOOTCORE" -le 8388608 ] &&
		[ "$SIZE_ROOTFS" -le 33554432 ] || _err "Component exceeds the size limit."
	MAX_SIZE=$SIZE_KERNEL
	[ "$MAX_SIZE" -ge "$SIZE_BOOTCORE" ] || MAX_SIZE=$SIZE_BOOTCORE
	[ "$MAX_SIZE" -ge "$SIZE_ROOTFS" ] || MAX_SIZE=$SIZE_ROOTFS
	NEED=$MAX_SIZE
	$INSTALL && NEED=$((SIZE_KERNEL + SIZE_BOOTCORE + SIZE_ROOTFS))
	# Validation retains one image; installation retains all three. Readback streams.
	require_tmp_space "$NEED" || _err "Insufficient image staging space."

	echo "New Firmware:"
	echo "Version: $FW_VERSION"
	echo "Revision: $FW_REVISION"
	echo "Variant: $FW_VARIANT"
	echo

	# --install always validates every image before any UBI or boot-env write.
	validate_image "kernel.bin" "Kernel" "$SIZE_KERNEL" "$SHA256_KERNEL" 8388608
	validate_image "bootcore.bin" "Bootcore" "$SIZE_BOOTCORE" "$SHA256_BOOTCORE" 8388608
	validate_image "rootfs.img" "RootFS" "$SIZE_ROOTFS" "$SHA256_ROOTFS" 33554432
	echo
	$INSTALL || exit 0

	INSTALL_BANK=$(inactive_fwbank) || _err "Cannot determine the active firmware bank."
	case "$INSTALL_BANK" in A|B) ;; *) _err "Invalid inactive firmware bank." ;; esac
	DEFAULT_BANK=$(fw_printenv -n commit_bank 2>/dev/null) || _err "Cannot read the default firmware bank."
	[ "$DEFAULT_BANK" = "$(active_fwbank)" ] ||
		_err "Confirm or leave the current trial before installing another firmware."
	# Resolve every target once and reject missing/undersized volumes before writes.
	KERNEL_UBI=$(prepare_volume "kernel$INSTALL_BANK" "$SIZE_KERNEL") || exit 1
	BOOTCORE_UBI=$(prepare_volume "bootcore$INSTALL_BANK" "$SIZE_BOOTCORE") || exit 1
	ROOTFS_UBI=$(prepare_volume "rootfs$INSTALL_BANK" "$SIZE_ROOTFS") || exit 1
	echo "Active firmware bank is $(active_fwbank), will install to bank $INSTALL_BANK."

		echo
		if ! $YES; then
			echo -n "Are you sure you want to install this firmware to bank $INSTALL_BANK? (y/N) "
			_yesno || exit 2
		fi

		fwenv_set "img_valid$INSTALL_BANK" false || _err "Cannot mark the target bank incomplete."
		rm -f /tmp/8311-alt-firmware
		install_image "kernel.bin" "Kernel" "kernel$INSTALL_BANK" "$SIZE_KERNEL" "$SHA256_KERNEL" "$KERNEL_UBI"
		install_image "bootcore.bin" "Bootcore" "bootcore$INSTALL_BANK" "$SIZE_BOOTCORE" "$SHA256_BOOTCORE" "$BOOTCORE_UBI"
		install_image "rootfs.img" "RootFS" "rootfs$INSTALL_BANK" "$SIZE_ROOTFS" "$SHA256_ROOTFS" "$ROOTFS_UBI"
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
