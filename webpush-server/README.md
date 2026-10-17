# AfterGram Web Push sender

This is a small, separate Web Push sender for a personal server. On its first start it creates a VAPID key pair in `data/vapid-keys.json`; the directory is private (`0700`), the key file is created as `0600`, and `data/` is git-ignored. The private key never goes to the PWA. The public key is available from `GET /v1/vapid-public-key` and must be passed to `pushManager.subscribe()` as `applicationServerKey`.

VAPID key generation happens once. Sending is one HTTPS request per installed PWA subscription; CPU and storage needs are tiny for a personal account. The browser's `p256dh` and `auth` values are separate per-subscription encryption material and are stored in `data/subscriptions.json`.

## Start

Use Node.js 20 or later. Set these environment variables in the server's service manager, not in Git:

```sh
WEBPUSH_API_TOKEN=<random secret of at least 32 characters>
WEBPUSH_SUBJECT=mailto:<real contact address>
WEBPUSH_ALLOWED_ORIGIN=https://pipse363team.github.io
WEBPUSH_DATA_DIR=/var/lib/aftergram-webpush
HOST=127.0.0.1
PORT=8788
```

Install and start behind an HTTPS reverse proxy. The process binds to `127.0.0.1`; expose only the proxy's HTTPS port. Keep the data directory readable only by the service account and back up `vapid-keys.json` securely. If the key is lost, existing subscriptions must be recreated with the new public key.

```sh
npm ci
npm start
```

For a direct TLS listener, set `WEBPUSH_TLS_CERT` and `WEBPUSH_TLS_KEY` to readable certificate files and bind the selected public HTTPS port with `HOST=0.0.0.0`. The repository includes `aftergram-webpush.service` as the current VPS systemd example; it reads its bearer token from `/etc/aftergram-webpush.env` and uses systemd credentials for the TLS private key.

The configured VPS endpoint is `https://144.31.165.8:9443`, using the server's short-lived Let's Encrypt IP certificate. Certbot renews the certificate automatically; install `aftergram-webpush-certbot-deploy.sh` as a deploy hook so the service reloads the renewed certificate. The API token is stored root-only in `/etc/aftergram-webpush.env`; retrieve it on the server with `sudo grep '^WEBPUSH_API_TOKEN=' /etc/aftergram-webpush.env` and enter it in the PWA setup page. Do not put that token in the repository or share it publicly.

## API

- `GET /healthz` — health check.
- `GET /v1/vapid-public-key` — public VAPID key; safe to expose.
- `POST /v1/subscriptions` — save a browser subscription. Requires `Authorization: Bearer $WEBPUSH_API_TOKEN`.
- `POST /v1/unsubscribe` — remove a subscription by `{ "endpoint": "..." }`. Requires the same bearer token.
- `POST /v1/send` — send `{ "title": "...", "description": "..." }` to saved subscriptions. Requires the same bearer token. Expired endpoints are removed automatically.

The API token must be entered only on the owner's device and must not be embedded in GitHub Pages JavaScript. A production setup needs a private pairing step or a reverse proxy that authenticates the owner before allowing subscription writes and sends.

## Telegram integration status

This service can send a test Web Push to a stored PWA subscription. It does not yet receive Telegram message events. The current native app registers the subscription with Telegram as token type 10; Telegram's own push infrastructure cannot use this server's private VAPID key unless Telegram's sender is configured with that key. To use this service for Telegram notifications, an event source must feed it. A bot only sees updates available to that bot; receiving a personal account's messages requires a separate, explicitly configured Telegram client/session. Do not put a Telegram login session in this repository.
