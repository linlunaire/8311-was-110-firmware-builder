#!/bin/sh
set -e
umask 077
. /lib/8311-limits.sh || exit 1
RAW=false
DELETE=false
case "${1-}" in
	--raw) [ $# -eq 1 ] || exit 1; RAW=true ;;
	--delete) [ $# -eq 1 ] || exit 1; DELETE=true ;;
	-h|--help)
		echo "Usage: $0 [--raw|--delete]"
		echo "Default: redacted environment and VLAN tables; --raw includes credentials, logs and OMCI dumps."
		exit 0
	;;
	"") [ $# -eq 0 ] || exit 1 ;;
	*) echo "Unknown option: $1" >&2; exit 1 ;;
esac

exec 9>/tmp/8311-support.lock
flock -n 9 || { echo "Support archive generation already in progress." >&2; exit 1; }
OUT="/tmp/support.tar.gz"
if $DELETE; then rm -f "$OUT"; exit 0; fi
# Never expose a previous raw archive after any failed regeneration.
rm -f "$OUT"
require_tmp_space 16777216 || exit 1
echo "Generating support archive ..."
echo
TMPDIR=$(mktemp -d /tmp/8311-support.XXXXXX)
trap 'rm -rf "$TMPDIR"' 0
trap 'exit 1' HUP INT TERM
OUTDIR="$TMPDIR/support"

mkdir -p "$OUTDIR"
# Do not offer an older (possibly raw) archive after a failed generation.
rm -f "$OUT"

echo -n "Dumping FW ENVs ..."
# Check the reader before the pipeline so an error cannot become an empty success.
capture "$TMPDIR/fwenvs.txt" 1048576 5 fw_printenv
if $RAW; then
	capture "$OUTDIR/fwenvs.txt" 1048576 5 sort -V "$TMPDIR/fwenvs.txt"
else
	# Only numeric VLAN/daemon settings are kept. Unknown and future fields are
	# redacted too; a growing deny-list would miss new authentication settings.
	capture "$OUTDIR/fwenvs.txt" 1048576 5 awk -F= '
		/=/ {
			if ($1 ~ /^8311_(fix_vlans|internet_vlan|services_vlan|failsafe_delay|pingd|reverse_arp)$/ && $2 ~ /^[0-9]+$/)
				print $1 "=" $2
			else
				print $1 "=[REDACTED]"
		}' "$TMPDIR/fwenvs.txt"
	printf '%s\n' 'Minimal diagnostics: environment values are redacted except numeric VLAN/daemon settings.' \
		'Raw pontop, OMCI, TC and system logs are omitted. Use --raw only when these are required.' > "$OUTDIR/README.txt"
fi
rm -f "$TMPDIR/fwenvs.txt"
echo " done"

if $RAW; then
	echo -n "Dumping pontop pages ..."
	rm -f "/tmp/pontop.txt"
	code=0
	bounded_run 1048576 15 pontop -b >/dev/null 2>/dev/null || code=$?
	if [ "$code" -ne 0 ]; then
		if [ -f /tmp/pontop.txt ] && [ "$(wc -c < /tmp/pontop.txt)" -ge 1048576 ]; then
			echo 'Output limit exceeded: pontop.txt; incomplete output discarded.' >&2
		else
			case "$code" in 124|137|143) echo 'Query timed out or was terminated: pontop.txt.' >&2 ;; *) echo 'Query failed: pontop.txt.' >&2 ;; esac
		fi
		rm -f /tmp/pontop.txt
		exit 1
	fi
	[ "$(wc -c < /tmp/pontop.txt)" -le 1048576 ] || {
		echo 'Output limit exceeded: pontop.txt; incomplete output discarded.' >&2
		rm -f /tmp/pontop.txt; exit 3
	}
	mv "/tmp/pontop.txt" "$OUTDIR/"
	echo " done"

	echo -n "Dumping OMCI MEs ..."
	capture "$OUTDIR/omci_pipe_md.txt" 1048576 15 omci_pipe.sh md
	capture "$OUTDIR/omci_pipe_mda.txt" 1048576 15 omci_pipe.sh mda
	echo " done"
fi

echo -n "Dumping VLAN tables ..."
capture "$OUTDIR/extvlan-tables.txt" 1048576 5 8311-extvlan-decode.sh -t
capture "$TMPDIR/extra.txt" 1048576 5 8311-extvlan-decode.sh
[ "$(( $(wc -c < "$OUTDIR/extvlan-tables.txt") + $(wc -c < "$TMPDIR/extra.txt") + 2 ))" -le 1048576 ] || {
	echo 'Output limit exceeded: extvlan-tables.txt; incomplete output discarded.' >&2; exit 3;
}
printf '\n\n' >> "$OUTDIR/extvlan-tables.txt"
cat "$TMPDIR/extra.txt" >> "$OUTDIR/extvlan-tables.txt"
rm -f "$TMPDIR/extra.txt"
echo " done"

if $RAW; then
	echo -n "Dumping TC Filters ..."
	capture "$OUTDIR/tc_filters.txt" 1048576 10 8311-tc-filter-dump.sh
	echo " done"

	echo -n "Dumping System Log ..."
	capture "$OUTDIR/system_log.txt" 1048576 5 logread
	echo " done"
fi

echo
echo -n "Writing support archive '$OUT' ..."
TOTAL=0
for file in "$OUTDIR"/*; do
	SIZE=$(wc -c < "$file") || exit 1
	TOTAL=$((TOTAL + SIZE))
done
[ "$TOTAL" -le 8388608 ] || { echo 'Support data exceeds 8 MiB.' >&2; exit 3; }
capture "$TMPDIR/support.tar.gz" 8388608 30 tar -cz -C "$TMPDIR" -- support
mv "$TMPDIR/support.tar.gz" "$OUT"

echo " done"

echo
if $RAW; then
	echo "WARNING: Raw support archive contains credentials and identifiers. Do not share it publicly."
else
	echo "Minimal support archive generated. Review its contents before sharing."
fi
