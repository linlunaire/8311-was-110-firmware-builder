#!/bin/bash
set -e -o pipefail

if { [ "$1" -lt 0 ] || [ "$1" -ge 0 ]; } 2>/dev/null; then
	TIMESTAMP="$1"
else
	TIMESTAMP=$(date '+%s')
fi
TIMESTAMP=$((TIMESTAMP & 0xffffffff))

check_size() {
	[ -f "$1" ] && [ -s "$1" ] && [ "$(stat -c %s "$1")" -le "$2" ] || {
		printf "Missing, empty or oversized image component: %s\n" "$1" >&2
		exit 1
	}
}

check_size whole_image/uboot-azores-1.0.24.bin $((0x00100000))
check_size whole_image/ubootenv-azores.img $((0x00040000))
for IMAGE in kernel.bin bootcore.bin rootfs.img; do
	check_size "out/$IMAGE" $((0x06600000))
done
command -v ubinize >/dev/null
command -v perl >/dev/null
[ -f system_sw.ini ] && [ -x tools/endianess_swap.sh ]
WORK=$(mktemp -d out/whole-image.build.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
trap 'exit 1' HUP INT TERM

ubinize -o "$WORK/system_sw.img" -p 128KiB -m 2048 -s 2048 -v system_sw.ini -Q "$TIMESTAMP"
check_size "$WORK/system_sw.img" $((0x06600000))

OUTIMG="$WORK/whole-image.img"
FLSIMG="$WORK/whole-image-endian.img"
# Append checked bytes and explicit erased padding; never truncate an oversized
# component or let a failed producer turn into a successful padded image.
append_data() {
	local size="$1" file="${2-}" length=0
	if [ -n "$file" ]; then
		check_size "$file" "$size"
		cat "$file" >> "$OUTIMG"
		length=$(stat -c %s "$file")
	fi
	head -c "$((size - length))" /dev/zero | LC_ALL=C tr '\000' '\377' >> "$OUTIMG"
}

append_data $((0x00100000)) whole_image/uboot-azores-1.0.24.bin
append_data $((0x00040000)) whole_image/ubootenv-azores.img
append_data $((0x00040000)) whole_image/ubootenv-azores.img
append_data $((0x00040000)) # gphyfirmware
append_data $((0x00100000)) # calibration
append_data $((0x01000000)) # bootcore
cat "$WORK/system_sw.img" >> "$OUTIMG"
tools/endianess_swap.sh "$OUTIMG" "$FLSIMG"
[ "$(stat -c %s "$OUTIMG")" = "$(stat -c %s "$FLSIMG")" ]
touch -d "@$TIMESTAMP" "$OUTIMG" "$FLSIMG"
mv -f "$WORK/system_sw.img" whole_image/system_sw.img
mv -f "$OUTIMG" out/whole-image.img
mv -f "$FLSIMG" out/whole-image-endian.img

echo "Whole flash images created successfully."
