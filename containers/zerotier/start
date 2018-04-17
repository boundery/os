#!/bin/sh

if [ -z "$ZEROTIER_TOKEN" ]; then
    echo "ZEROTIER_TOKEN not set!" >&2
    exit 10
fi

/usr/sbin/zerotier-one &

python3 /zerotier_allow.py private

wait
