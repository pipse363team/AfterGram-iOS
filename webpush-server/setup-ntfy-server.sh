#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root: sudo bash setup-ntfy-server.sh" >&2
  exit 1
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
SERVER_URL=${NTFY_SERVER_URL:-https://144.31.165.8:9444}
TLS_CERT=/etc/letsencrypt/live/csqtt-ip-144-31-165-8/fullchain.pem
TLS_KEY=/etc/letsencrypt/live/csqtt-ip-144-31-165-8/privkey.pem
ENV_FILE=/etc/aftergram-ntfy.env

if [[ ! -r "$TLS_CERT" || ! -r "$TLS_KEY" ]]; then
  echo "The existing Let's Encrypt IP certificate was not found at $TLS_CERT" >&2
  exit 1
fi
if [[ -z ${NTFY_SERVER_URL:-} && -f "$ENV_FILE" ]]; then
  saved_server_url=$(sed -n 's/^NTFY_SERVER_URL=//p' "$ENV_FILE" | head -n 1)
  if [[ "$saved_server_url" == https://* && "$saved_server_url" != */ ]]; then
    SERVER_URL=$saved_server_url
  fi
fi
if [[ "$SERVER_URL" != https://* || "$SERVER_URL" == */ ]]; then
  echo "NTFY_SERVER_URL must be an HTTPS URL without a trailing slash" >&2
  exit 1
fi

if ! command -v ntfy >/dev/null 2>&1; then
  if ! command -v apt-get >/dev/null 2>&1 || ! command -v dpkg >/dev/null 2>&1; then
    echo "This installer supports Debian/Ubuntu servers only." >&2
    exit 1
  fi
  arch=$(dpkg --print-architecture)
  case "$arch" in amd64|arm64|armhf) ;; *) echo "Unsupported Debian architecture: $arch" >&2; exit 1 ;; esac
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://archive.ntfy.sh/apt/keyring.gpg -o /etc/apt/keyrings/ntfy.gpg
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/ntfy.gpg] https://archive.ntfy.sh/apt stable main\n' "$arch" > /etc/apt/sources.list.d/ntfy.list
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y ntfy
fi
NTFY_BIN=$(command -v ntfy)
if ! getent passwd ntfy >/dev/null 2>&1; then
  useradd --system --home-dir /var/lib/ntfy --shell /usr/sbin/nologin --comment "AfterGram ntfy service" ntfy
fi
if ! getent group ntfy >/dev/null 2>&1; then
  groupadd --system ntfy
  usermod -g ntfy ntfy
fi

if [[ -f "$ENV_FILE" ]]; then
  topic=$(sed -n 's/^NTFY_TOPIC=//p' "$ENV_FILE" | head -n 1)
fi
if [[ -z ${topic:-} || ! "$topic" =~ ^[a-f0-9]{64}$ ]]; then
  topic=$(openssl rand -hex 32)
fi

install -d -o ntfy -g ntfy -m 0750 /etc/ntfy /var/lib/ntfy /var/cache/ntfy
temporary_config=$(mktemp)
trap 'rm -f "$temporary_config"' EXIT
cat > "$temporary_config" <<EOF
base-url: "$SERVER_URL"
listen-http: "127.0.0.1:2586"
listen-https: ":9444"
cert-file: "/run/credentials/aftergram-ntfy.service/ntfy-tls-cert"
key-file: "/run/credentials/aftergram-ntfy.service/ntfy-tls-key"
cache-file: "/var/cache/ntfy/cache.db"
cache-duration: "1h"
upstream-base-url: "https://ntfy.sh"
auth-file: "/var/lib/ntfy/user.db"
auth-default-access: "deny-all"
auth-access:
  - "*:$topic:read-write"
enable-signup: false
EOF
install -o root -g ntfy -m 0640 "$temporary_config" /etc/ntfy/server.yml
temporary_unit=$(mktemp)
sed "s|^ExecStart=@NTFY_BIN@ serve$|ExecStart=$NTFY_BIN serve|" "$SCRIPT_DIR/aftergram-ntfy.service" > "$temporary_unit"
install -o root -g root -m 0644 "$temporary_unit" /etc/systemd/system/aftergram-ntfy.service
temporary_env=$(mktemp)
trap 'rm -f "$temporary_config" "$temporary_env" "$temporary_unit"' EXIT
printf 'NTFY_SERVER_URL=%s\nNTFY_TOPIC=%s\n' "$SERVER_URL" "$topic" > "$temporary_env"
install -o root -g root -m 0600 "$temporary_env" "$ENV_FILE"

systemctl disable --now ntfy.service >/dev/null 2>&1 || true
systemctl daemon-reload
systemctl enable --now aftergram-ntfy.service
systemctl enable aftergram-webpush.service
systemctl restart aftergram-webpush.service

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  ufw allow 9444/tcp
fi

health_ready=false
for attempt in {1..10}; do
  if curl --fail --silent --max-time 3 "$SERVER_URL/v1/health" >/dev/null; then
    health_ready=true
    break
  fi
  sleep 1
done
if [[ "$health_ready" != true ]]; then
  echo "ntfy is running but its HTTPS health check failed; inspect: systemctl status aftergram-ntfy.service" >&2
  exit 1
fi

echo "ntfy is ready. Open the AfterGram setup page and use the existing owner API token to load the private topic."
echo "If the VPS provider has a network firewall, allow inbound TCP port 9444 there too."
