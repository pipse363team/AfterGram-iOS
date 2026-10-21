#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root: sudo bash setup-ntfy-server.sh" >&2
  exit 1
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
ENV_FILE=/etc/aftergram-ntfy.env
SERVER_URL=${NTFY_SERVER_URL:-}
ATTACHMENT_BASE_URL=${NTFY_ATTACHMENT_BASE_URL:-}
TLS_CERT=${NTFY_TLS_CERT:-}
TLS_KEY=${NTFY_TLS_KEY:-}

read_saved_setting() {
  sed -n "s/^$1=//p" "$ENV_FILE" | head -n 1
}

if [[ -f "$ENV_FILE" ]]; then
  [[ -n "$SERVER_URL" ]] || SERVER_URL=$(read_saved_setting NTFY_SERVER_URL)
  [[ -n "$ATTACHMENT_BASE_URL" ]] || ATTACHMENT_BASE_URL=$(read_saved_setting NTFY_ATTACHMENT_BASE_URL)
  [[ -n "$TLS_CERT" ]] || TLS_CERT=$(read_saved_setting NTFY_TLS_CERT)
  [[ -n "$TLS_KEY" ]] || TLS_KEY=$(read_saved_setting NTFY_TLS_KEY)
fi

if [[ -z "$SERVER_URL" || -z "$ATTACHMENT_BASE_URL" || -z "$TLS_CERT" || -z "$TLS_KEY" ]]; then
  echo "Set NTFY_SERVER_URL, NTFY_ATTACHMENT_BASE_URL, NTFY_TLS_CERT, and NTFY_TLS_KEY before running this installer." >&2
  exit 1
fi
if [[ ! -r "$TLS_CERT" || ! -r "$TLS_KEY" ]]; then
  echo "The configured TLS certificate or key is not readable." >&2
  exit 1
fi
if [[ "$SERVER_URL" != https://* || "$SERVER_URL" == */ ]]; then
  echo "NTFY_SERVER_URL must be an HTTPS URL without a trailing slash" >&2
  exit 1
fi
if [[ "$ATTACHMENT_BASE_URL" != https://* || "$ATTACHMENT_BASE_URL" == */ ]]; then
  echo "NTFY_ATTACHMENT_BASE_URL must be an HTTPS URL without a trailing slash" >&2
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
sed \
  -e "s|^ExecStart=@NTFY_BIN@ serve$|ExecStart=$NTFY_BIN serve|" \
  -e "s|^LoadCredential=ntfy-tls-cert:.*|LoadCredential=ntfy-tls-cert:$TLS_CERT|" \
  -e "s|^LoadCredential=ntfy-tls-key:.*|LoadCredential=ntfy-tls-key:$TLS_KEY|" \
  "$SCRIPT_DIR/aftergram-ntfy.service" > "$temporary_unit"
install -o root -g root -m 0644 "$temporary_unit" /etc/systemd/system/aftergram-ntfy.service
temporary_env=$(mktemp)
trap 'rm -f "$temporary_config" "$temporary_env" "$temporary_unit"' EXIT
printf 'NTFY_SERVER_URL=%s\nNTFY_TOPIC=%s\nNTFY_ATTACHMENT_BASE_URL=%s\nNTFY_TLS_CERT=%s\nNTFY_TLS_KEY=%s\n' "$SERVER_URL" "$topic" "$ATTACHMENT_BASE_URL" "$TLS_CERT" "$TLS_KEY" > "$temporary_env"
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
