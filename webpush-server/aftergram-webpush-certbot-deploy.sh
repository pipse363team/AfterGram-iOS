#!/bin/sh
set -eu

if [ -n "${RENEWED_LINEAGE:-}" ]; then
    /usr/bin/systemctl restart aftergram-webpush.service
    if /usr/bin/systemctl is-active --quiet aftergram-ntfy.service; then
        /usr/bin/systemctl restart aftergram-ntfy.service
    fi
fi
