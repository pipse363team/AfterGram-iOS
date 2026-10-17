#!/bin/sh
set -eu

if [ "${RENEWED_LINEAGE:-}" = "/etc/letsencrypt/live/csqtt-ip-144-31-165-8" ]; then
    /usr/bin/systemctl restart aftergram-webpush.service
fi
