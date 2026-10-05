#!/bin/sh
# Bound query/extraction output without hiding the command's exit status.
# BusyBox ash and dash use 512-byte blocks; bash uses 1024-byte blocks.
bounded_run() {
	local bytes="$1" seconds="$2" unit=512
	shift 2
	[ -z "${BASH_VERSION:-}" ] || unit=1024
	( ulimit -f "$(( (bytes + unit - 1) / unit ))" || exit 126
	  exec timeout -k 1 "$seconds" "$@" )
}

capture() {
	local file="$1" bytes="$2" seconds="$3" code=0
	shift 3
	bounded_run "$bytes" "$seconds" "$@" > "$file" 2>/dev/null || code=$?
	local size
	size=$(wc -c < "$file") || return 1
	if [ "$size" -gt "$bytes" ] || { [ "$code" -ne 0 ] && [ "$size" -ge "$bytes" ]; }; then
		echo "Output limit exceeded: ${file##*/}; incomplete output discarded." >&2
		rm -f "$file"; return 3
	fi
	case "$code" in
		0) return 0 ;;
		124|137|143) echo "Query timed out or was terminated: ${file##*/}; incomplete output discarded." >&2 ;;
		*) echo "Query failed ($code): ${file##*/}; incomplete output discarded." >&2 ;;
	esac
	rm -f "$file"
	return "$code"
}

# /tmp on the target reports zero filesystem blocks: also budget available RAM.
require_tmp_space() {
	case "${1-}" in ''|*[!0-9]*) return 2 ;; esac
	case "$1" in 0?*) return 2 ;; esac
	[ "$#" -eq 1 ] && [ "${#1}" -le 9 ] || return 2
	local MEM DISK
	MEM=$(awk '
		/^MemAvailable:/ { available=$2; found=1 }
		/^MemFree:/ { free=$2 }
		/^Buffers:/ { buffers=$2 }
		/^Cached:/ { cached=$2 }
		/^Shmem:/ { shared=$2 }
		END { print int(found ? available : free+buffers+cached-shared) }
	' /proc/meminfo) || return 1
	DISK=$(df -Pk /tmp/ 2>/dev/null) || return 1
	DISK=$(printf '%s\n' "$DISK" | awk 'NR==2 {print $4}')
	case "$MEM:$DISK" in *[!0-9:]*|:*|*:) return 1 ;; esac
	[ "$DISK" -eq 0 ] || [ "$MEM" -le "$DISK" ] || MEM=$DISK
	# Leave 8 MiB for management/driver processes. Writes still check ENOSPC.
	[ "$MEM" -ge "$(( ($1 + 1023) / 1024 + 8192 ))" ] || {
		echo 'Insufficient temporary space or available memory.' >&2
		return 1
	}
}
