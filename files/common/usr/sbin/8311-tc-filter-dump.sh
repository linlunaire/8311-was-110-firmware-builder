#!/bin/sh
LINKS=$(ip -o li) || exit 1
INTERFACES=$(printf '%s\n' "$LINKS" | awk -F '[ @:]+' '
    $1 ~ /^[0-9]+$/ && $2 ~ /^(eth|gem|pmapper|tcont|sw)/ && $2 !~ /(-omci|lct)$/ {print $2}
') || exit 1
INTERFACES=$(printf '%s\n' "$INTERFACES" | sort -V) || exit 1
for DEV in $INTERFACES; do
    for DIR in ingress egress; do
        TC=$(tc filter show dev "$DEV" "$DIR") || exit 1
        if [ -n "$TC" ]; then
            echo "--------------- tc filter show dev $DEV $DIR ---------------"
            printf '%s\n' "$TC"
            echo
            echo
        fi
    done
done
