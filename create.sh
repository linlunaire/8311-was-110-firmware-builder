#!/bin/bash
_help() {
	printf -- 'Tool for creating new WAS-110 local upgrade images\n\n'
	printf -- 'Usage: %s [options]\n\n' "$0"
	printf -- 'Options:\n'
	printf -- '-i --image <filename>\t\t\tSpecify local upgrade (img or tar) file to create (required).\n'
	printf -- '-w --basic\t\t\t\tBuild a basic local upgrade tar file.\n'
	printf -- '-W --bfw\t\t\t\tBuild a bfw local upgrade image file.\n'
	printf -- '-H --header <filename>\t\t\tSpecify filename of image header to base image off of (default: header.bin).\n'
	printf -- '-b --bootcore <filename>\t\tSpecify filename of bootcore image to place in created (bfw) image (default: bootcore.bin).\n'
	printf -- '-k --kernel <filename>\t\t\tSpecify filename of kernel image to place in created image (default: kernel.bin).\n'
	printf -- '-r --rootfs <filename>\t\t\tSpecify filename of rootfs image to place in created image (default: rootfs.img).\n'
	printf -- '-F --version-file <filename>\t\tSpecify 8311 version file of basic firmeware image.\n'
	printf -- '-V --image-version <version>\t\tSpecify version string to set on created image (15 characters max).\n'
	printf -- '-L --image-long-version <version>\tSpecify detailed version string to set on created bfw image (31 characters max).\n'
	printf -- '-D --date <date>\t\tSpecify date to use on all files. Helps with reproducability.\n'
	printf -- '-h --help\t\t\t\tThis help text\n'
}

OUT=
HEADER="header.bin"
BOOTCORE="bootcore.bin"
KERNEL="kernel.bin"
ROOTFS="rootfs.img"
UPGRADE_SCRIPT="files/common/usr/sbin/8311-firmware-upgrade.sh"
VERSION=
LONGVERSION=
VARIANT="bfw"
VERSION_FILE=
DATE="@$(date '+%s')"

while [ $# -gt 0 ]; do
	case "$1" in
		-i|--image|-H|--header|-b|--bootcore|-k|--kernel|-r|--rootfs|-F|--version-file|-V|--image-version|-L|--image-long-version|-D|--date)
			[ $# -ge 2 ] && [ -n "$2" ] || { printf "Option '%s' requires a value.\n" "$1" >&2; exit 1; }
		;;
	esac
	case "$1" in
		-i|--image)
			OUT="$2"
			shift
		;;
		-w|--basic)
			VARIANT="basic"
		;;
		-W|--bfw)
			VARIANT="bfw"
		;;
		-H|--header)
			HEADER="$2"
			shift
		;;
		-b|--bootcore)
			BOOTCORE="$2"
			shift
		;;
		-k|--kernel)
			KERNEL="$2"
			shift
		;;
		-r|--rootfs)
			ROOTFS="$2"
			shift
		;;
		-F|--version-file)
			VERSION_FILE="$2"
			shift
		;;
		-V|--image-version)
			VERSION="$2"
			shift
		;;
		-L|--image-long-version)
			LONGVERSION="$2"
			shift
		;;
		-D|--date)
			DATE="$2"
			shift
		;;
		--help|-h)
			_help
			exit 0
		;;
		*)
			_help
			exit 1
		;;
	esac
	shift
done

_err() {
	echo "$1" >&2
	exit ${2:-1}
}

sha256() {
	sha256sum "$@" | awk '{print $1}'
}

file_size() {
	stat -c '%s' "$1"
}

bfw_add_image() {
	IMAGE="$1"
	FILE="${2:-$1}"

	NAME_OFFSET=$((FILE_OFFSET + NUM * 48))
	SIZE_OFFSET=$((NAME_OFFSET + 32))
	if [ ! -f "$FILE" ]; then
		echo "File '$FILE' for image '$IMAGE' does not exist" >&2
		exit 1
	fi

	FILES+=("$FILE")

	SIZE=$(stat -c "%s" "$FILE")

	echo "Adding image #$NUM ($IMAGE) from '$FILE' ($SIZE bytes)"
	{ echo -n "$IMAGE"; cat /dev/zero; } | dd of="$OUT" seek="$NAME_OFFSET" bs=1 count=32 conv=notrunc 2>/dev/null
	{ echo -n "$SIZE"; cat /dev/zero; } | dd of="$OUT" seek="$SIZE_OFFSET" bs=1 count=16 conv=notrunc 2>/dev/null

	cat "$FILE" >> "$OUT"

	DATA_OFFSET=$((DATA_OFFSET + SIZE))
	NUM=$((NUM + 1))
}

set -e

[ -n "$OUT" ] || _err "Error: Image file to create must be specified."
[ -n "$BOOTCORE" ] || _err "Error: bootcore file must be specified."
[ -f "$BOOTCORE" ] || _err "Error: bootcore file '$BOOTCORE' not found."
[ -n "$KERNEL" ] || _err "Error: kernel file must be specified."
[ -f "$KERNEL" ] || _err "Error: kernel file '$KERNEL' not found."
[ -n "$ROOTFS" ] || _err "Error: rootfs file must be specified."
[ -f "$ROOTFS" ] || _err "Error: rootfs file '$ROOTFS' not found."

for INPUT in "$BOOTCORE" "$KERNEL" "$ROOTFS" "$HEADER" "$VERSION_FILE" "$UPGRADE_SCRIPT"; do
	[ -z "$INPUT" ] || [ "$(realpath -m -- "$OUT")" != "$(realpath -m -- "$INPUT")" ] || _err "Output must not replace an input file."
done
for INPUT in "$BOOTCORE" "$KERNEL" "$ROOTFS"; do
	[ -s "$INPUT" ] || _err "Image component '$INPUT' is empty."
done

DESTINATION="$OUT"
WORK=$(mktemp -d "${OUT}.build.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
trap 'exit 1' HUP INT TERM
OUT="$WORK/image"

if [ "$VARIANT" = "basic" ]; then
	[ -n "$VERSION_FILE" ] || _err "Error: version file must be specified."
	[ -f "$VERSION_FILE" ] || _err "Error: version file '$VERSION_FILE' not found."

	SHA256_KERNEL=$(sha256 "$KERNEL")
	SHA256_BOOTCORE=$(sha256 "$BOOTCORE")
	SHA256_ROOTFS=$(sha256 "$ROOTFS")

	SIZE_KERNEL=$(file_size "$KERNEL")
	SIZE_BOOTCORE=$(file_size "$BOOTCORE")
	SIZE_ROOTFS=$(file_size "$ROOTFS")

	VER_8311=$(cat "$VERSION_FILE")

	CONTROL="$WORK/control"
	cat > "$CONTROL" <<CONTROL
$VER_8311

SIZE_KERNEL=$SIZE_KERNEL
SIZE_BOOTCORE=$SIZE_BOOTCORE
SIZE_ROOTFS=$SIZE_ROOTFS

SHA256_KERNEL=$SHA256_KERNEL
SHA256_BOOTCORE=$SHA256_BOOTCORE
SHA256_ROOTFS=$SHA256_ROOTFS
CONTROL

	echo "Creating local upgrade tar file"
	cp -- "$UPGRADE_SCRIPT" "$WORK/upgrade.sh"
	cp -- "$KERNEL" "$WORK/kernel.bin"
	cp -- "$BOOTCORE" "$WORK/bootcore.bin"
	cp -- "$ROOTFS" "$WORK/rootfs.img"
	tar -c --sparse --mtime="$DATE" -f "$OUT" -C "$WORK" -- upgrade.sh control kernel.bin bootcore.bin rootfs.img
	touch -d "$DATE" "$OUT"
	mv -f -- "$OUT" "$DESTINATION"
	echo "Local upgrade tar file '$DESTINATION' created successfully."
else
	[ -n "$HEADER" ] || _err "Error: header file must be specified."
	[ -f "$HEADER" ] || _err "Error: header file '$HEADER' not found."
	[ "$(file_size "$HEADER")" -ge $((0xD00)) ] || _err "Image header is truncated."

	NUM=0
	FILE_OFFSET=$((0x100))
	LEN_HDR=$((0xD00))
	DATA_OFFSET=$LEN_HDR
	HW_OFFSET=$((0x10))
	VERSION_OFFSET=$((0x30))
	LONGVERSION_OFFSET=$((0x46))

	FILES=()

	echo "Creating local upgrade image file from header file '$HEADER'"
	head -c "$LEN_HDR" "$HEADER" > "$OUT"

	if [ -n "$VERSION" ]; then
		echo "Setting image version string to '$VERSION'"
		{ echo -n "$VERSION" | head -c 15; cat /dev/zero; } | dd of="$OUT" seek="$VERSION_OFFSET" bs=1 count=16 conv=notrunc 2>/dev/null
	fi

	if [ -n "$LONGVERSION" ]; then
		echo "Setting long image version string to '$LONGVERSION'"
		{ echo -n "$LONGVERSION" | head -c 31; cat /dev/zero; } | dd of="$OUT" seek="$LONGVERSION_OFFSET" bs=1 count=32 conv=notrunc 2>/dev/null
	fi

	bfw_add_image "bootcore.bin" "$BOOTCORE"
	bfw_add_image "kernel.bin" "$KERNEL"
	bfw_add_image "rootfs.img" "$ROOTFS"

	CONTENT_CRC_OFFSET=$((0x66))
	HEADER_CRC_OFFSET=$((0x6A))

	echo "Updating CRCs"
	(set -o pipefail; cat "${FILES[@]}" | tools/bfw-crc.pl > "$WORK/content-crc")
	{ cat "$WORK/content-crc"; printf '\000\000\000\000'; } | dd of="$OUT" seek="$CONTENT_CRC_OFFSET" bs=1 count=8 conv=notrunc 2>/dev/null
	(set -o pipefail; head -c "$LEN_HDR" "$OUT" | tools/bfw-crc.pl > "$WORK/header-crc")
	dd if="$WORK/header-crc" of="$OUT" seek="$HEADER_CRC_OFFSET" bs=1 count=4 conv=notrunc 2>/dev/null

	touch -d "$DATE" "$OUT"
	mv -f -- "$OUT" "$DESTINATION"
	echo "Local upgrade image file '$DESTINATION' created successfully."
fi
