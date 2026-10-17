#!/usr/bin/env bash
set -euo pipefail
umask 077

if [[ ${EUID} -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

api_id=''
api_hash=''
if [[ -f /etc/aftergram-telegram.env ]]; then
    # shellcheck disable=SC1091
    source /etc/aftergram-telegram.env
    api_id=${TELEGRAM_API_ID:-}
    api_hash=${TELEGRAM_API_HASH:-}
fi

if [[ ! $api_id =~ ^[0-9]+$ ]]; then
    read -r -p 'Telegram API ID from my.telegram.org: ' api_id
fi
if [[ ! $api_hash =~ ^[A-Fa-f0-9]{32}$ ]]; then
    read -r -s -p 'Telegram API hash from my.telegram.org: ' api_hash
    printf '\n'
fi
if [[ ! $api_id =~ ^[0-9]+$ || ! $api_hash =~ ^[A-Fa-f0-9]{32}$ ]]; then
    printf 'Invalid API ID or API hash. No credentials were saved.\n' >&2
    exit 1
fi

credentials_file=$(mktemp /etc/aftergram-telegram.env.XXXXXX)
printf 'TELEGRAM_API_ID=%s\nTELEGRAM_API_HASH=%s\n' "$api_id" "$api_hash" > "$credentials_file"
chmod 0600 "$credentials_file"
mv -f "$credentials_file" /etc/aftergram-telegram.env
export TELEGRAM_API_ID=$api_id TELEGRAM_API_HASH=$api_hash
export TELEGRAM_SESSION_FILE=/var/lib/aftergram-telegram/telegram.session

install -d -o aftergram-webpush -g aftergram-webpush -m 0700 /var/lib/aftergram-telegram
runuser -u aftergram-webpush --preserve-environment -- /usr/bin/node /opt/aftergram-webpush/telegram-bridge.mjs --login
systemctl enable --now aftergram-telegram-bridge.service
