#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

set -a
# shellcheck disable=SC1091
source /etc/aftergram-telegram.env
set +a
export TELEGRAM_SESSION_FILE=/var/lib/aftergram-telegram/telegram.session

install -d -o aftergram-webpush -g aftergram-webpush -m 0700 /var/lib/aftergram-telegram
exec runuser -u aftergram-webpush --preserve-environment -- /usr/bin/node /opt/aftergram-webpush/telegram-bridge.mjs --login
