#!/bin/sh
# Bound query/extraction output without hiding the command's exit status.
# BusyBox ash and dash use 512-byte blocks; bash uses 1024-byte blocks.
bounded_exec() {
	local bytes="$1" unit=512
	shift
	[ -z "${BASH_VERSION:-}" ] || unit=1024
	( ulimit -c 0 || exit 126
	  ulimit -f "$(( (bytes + unit - 1) / unit ))" || exit 126
	  exec "$@" )
}

bounded_run() {
	local bytes="$1" seconds="$2"
	shift 2
	bounded_exec "$bytes" timeout -k 1 "$seconds" "$@"
}

capture_result() {
	local file="$1" bytes="$2" code="$3"
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

capture() {
	local file="$1" bytes="$2" seconds="$3" code=0
	shift 3
	bounded_run "$bytes" "$seconds" "$@" > "$file" 2>/dev/null || code=$?
	capture_result "$file" "$bytes" "$code"
}

# The caller supplies timeout and its grace period. Both output streams and
# regular files written by descendants inherit the same per-file size limit.
capture_combined() {
	local file="$1" bytes="$2" code=0
	shift 2
	bounded_exec "$bytes" "$@" > "$file" 2>&1 || code=$?
	capture_result "$file" "$bytes" "$code"
}

# Hash and count the same byte stream. Keep every producer/consumer status;
# only tiny result files are staged, never a complete component payload.
stream_digest() (
	local directory="$1" algorithm="$2" expected="$3" work code=0
	local reader= hasher= counter= copier= size
	shift 3
	work=$(mktemp -d "$directory/digest.XXXXXX") || exit 1
	cleanup_stream() {
		local child
		# These private read-only workers may still be blocked opening a FIFO.
		for child in "$copier" "$reader" "$hasher" "$counter"; do
			[ -z "$child" ] || kill -KILL "$child" 2>/dev/null || true
		done
		wait 2>/dev/null || true
		rm -rf "$work"
	}
	trap cleanup_stream 0
	trap 'exit 1' HUP INT TERM
	mkfifo "$work/input" "$work/hash" "$work/count" || exit 1
	"$algorithm" < "$work/hash" > "$work/value" &
	hasher=$!
	wc -c < "$work/count" > "$work/size" &
	counter=$!
	"$@" > "$work/input" &
	reader=$!
	tee "$work/hash" < "$work/input" > "$work/count" &
	copier=$!
	# wait is interruptible by our traps; a failed copier may not have opened
	# every FIFO, so cancel its peers before waiting for their completion.
	wait "$copier" || { copier=; exit 1; }; copier=
	wait "$reader" || code=1; reader=
	wait "$hasher" || code=1; hasher=
	wait "$counter" || code=1; counter=
	[ "$code" -eq 0 ] || exit 1
	IFS= read -r size < "$work/size" || exit 1
	[ "$size" -eq "$expected" ] || exit 1
	cat "$work/value"
)

# /tmp on the target reports zero filesystem blocks: also budget available RAM.
require_tmp_space() {
	case "${1-}" in ''|*[!0-9]*) return 2 ;; esac
	case "$1" in 0?*) return 2 ;; esac
	[ "$#" -eq 1 ] && [ "${#1}" -le 9 ] || return 2
	local MEM DISK TOTAL
	MEM=$(awk '
		/^MemAvailable:/ { available=$2; found=1 }
		/^MemFree:/ { free=$2 }
		/^Buffers:/ { buffers=$2 }
		/^Cached:/ { cached=$2 }
		/^Shmem:/ { shared=$2 }
		END { print int(found ? available : free+buffers+cached-shared) }
	' /proc/meminfo) || return 1
	DISK=$(df -Pk /tmp/ 2>/dev/null) || return 1
	DISK=$(printf '%s\n' "$DISK" | awk 'NR==2 {print $2 ":" $4}') || return 1
	case "$MEM:$DISK" in *[!0-9:]*|:*|*:|*::*|*:*:*:*) return 1 ;; esac
	TOTAL=${DISK%:*}
	DISK=${DISK#*:}
	[ "$DISK" -le "$TOTAL" ] || return 1
	# Only zero total capacity means unavailable accounting; zero free can mean full.
	[ "$TOTAL" -eq 0 ] || [ "$MEM" -le "$DISK" ] || MEM=$DISK
	# Leave 8 MiB for management/driver processes. Writes still check ENOSPC.
	[ "$MEM" -ge "$(( ($1 + 1023) / 1024 + 8192 ))" ] || {
		echo 'Insufficient temporary space or available memory.' >&2
		return 1
	}
}
