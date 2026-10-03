#!/bin/sh
set -e
umask 077
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
timeout -k 1 5 fw_printenv > "$TMPDIR/fwenvs.txt"
if $RAW; then
	sort -V "$TMPDIR/fwenvs.txt" > "$OUTDIR/fwenvs.txt"
else
	# Only numeric VLAN/daemon settings are kept. Unknown and future fields are
	# redacted too; a growing deny-list would miss new authentication settings.
	awk -F= '
		/=/ {
			if ($1 ~ /^8311_(fix_vlans|internet_vlan|services_vlan|failsafe_delay|pingd|reverse_arp)$/ && $2 ~ /^[0-9]+$/)
				print $1 "=" $2
			else
				print $1 "=[REDACTED]"
		}' "$TMPDIR/fwenvs.txt" > "$OUTDIR/fwenvs.txt"
	printf '%s\n' 'Minimal diagnostics: environment values are redacted except numeric VLAN/daemon settings.' \
		'Raw pontop, OMCI, TC and system logs are omitted. Use --raw only when these are required.' > "$OUTDIR/README.txt"
fi
rm -f "$TMPDIR/fwenvs.txt"
echo " done"

if $RAW; then
	echo -n "Dumping pontop pages ..."
	rm -f "/tmp/pontop.txt"
	timeout -k 1 15 pontop -b > /dev/null
	mv "/tmp/pontop.txt" "$OUTDIR/"
	echo " done"

	echo -n "Dumping OMCI MEs ..."
	timeout -k 1 15 omci_pipe.sh md > "$OUTDIR/omci_pipe_md.txt"
	timeout -k 1 15 omci_pipe.sh mda > "$OUTDIR/omci_pipe_mda.txt"
	echo " done"
fi

echo -n "Dumping VLAN tables ..."
timeout -k 1 5 8311-extvlan-decode.sh -t > "$OUTDIR/extvlan-tables.txt"
{
	printf "\n\n"
	timeout -k 1 5 8311-extvlan-decode.sh
} >> "$OUTDIR/extvlan-tables.txt"
echo " done"

if $RAW; then
	echo -n "Dumping TC Filters ..."
	timeout -k 1 10 8311-tc-filter-dump.sh > "$OUTDIR/tc_filters.txt"
	echo " done"

	echo -n "Dumping System Log ..."
	timeout -k 1 5 logread > "$OUTDIR/system_log.txt"
	echo " done"
fi

echo
echo -n "Writing support archive '$OUT' ..."
tar -cz -f "$TMPDIR/support.tar.gz" -C "$TMPDIR" -- support
mv "$TMPDIR/support.tar.gz" "$OUT"

echo " done"

echo
if $RAW; then
	echo "WARNING: Raw support archive contains credentials and identifiers. Do not share it publicly."
else
	echo "Minimal support archive generated. Review its contents before sharing."
fi
