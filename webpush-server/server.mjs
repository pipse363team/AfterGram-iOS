import { createServer as createHttpServer } from 'node:http';
import { createServer as createHttpsServer } from 'node:https';
import { chmod, mkdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { randomBytes, timingSafeEqual } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import webpush from 'web-push';
import { createNtfyPublisher, validateNtfyConfiguration } from './ntfy-publisher.mjs';

const MAX_BODY_BYTES = 256 * 1024;
const MAX_NOTIFICATION_IMAGE_BYTES = 128 * 1024;
const MAX_NOTIFICATION_IMAGES = 128;
const MAX_NOTIFICATION_IMAGE_STORAGE_BYTES = 16 * 1024 * 1024;
const NOTIFICATION_IMAGE_TTL_MS = 2 * 60 * 60 * 1000;

function json(response, status, value) {
  response.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
  response.end(JSON.stringify(value));
}

function validSubscription(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  if (typeof value.endpoint !== 'string' || value.endpoint.length > 4096) return false;
  try {
    const endpoint = new URL(value.endpoint);
    if (endpoint.protocol !== 'https:' || endpoint.username || endpoint.password || !endpoint.hostname.includes('.')) return false;
  } catch {
    return false;
  }
  return typeof value.keys?.p256dh === 'string' && value.keys.p256dh.length > 0 &&
    typeof value.keys?.auth === 'string' && value.keys.auth.length > 0;
}

function authorized(request, expectedToken) {
  const supplied = request.headers.authorization?.match(/^Bearer (.+)$/)?.[1];
  if (!supplied || !expectedToken) return false;
  const left = Buffer.from(supplied);
  const right = Buffer.from(expectedToken);
  return left.length === right.length && timingSafeEqual(left, right);
}

async function readJson(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > MAX_BODY_BYTES) throw Object.assign(new Error('Request body too large'), { status: 413 });
    chunks.push(chunk);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    throw Object.assign(new Error('Invalid JSON'), { status: 400 });
  }
}

function decodeNotificationImage(value) {
  if (typeof value !== 'string' || value.length > Math.ceil(MAX_NOTIFICATION_IMAGE_BYTES * 4 / 3) + 4 ||
    !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) return undefined;
  const data = Buffer.from(value, 'base64');
  if (!data.length || data.length > MAX_NOTIFICATION_IMAGE_BYTES || data.toString('base64') !== value) return undefined;
  if (data.length >= 3 && data[0] === 0xff && data[1] === 0xd8 && data[2] === 0xff) return { data, contentType: 'image/jpeg' };
  if (data.length >= 8 && data.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) return { data, contentType: 'image/png' };
  return undefined;
}

async function readOrCreateKeys(dataDirectory, push) {
  const path = join(dataDirectory, 'vapid-keys.json');
  try {
    const keys = JSON.parse(await readFile(path, 'utf8'));
    await chmod(path, 0o600);
    return keys;
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }

  const keys = push.generateVAPIDKeys();
  await writeFile(path, `${JSON.stringify(keys, null, 2)}\n`, { mode: 0o600, flag: 'wx' });
  await chmod(path, 0o600);
  return keys;
}

async function readSubscriptions(dataDirectory) {
  try {
    const value = JSON.parse(await readFile(join(dataDirectory, 'subscriptions.json'), 'utf8'));
    return Array.isArray(value) ? value.filter(validSubscription) : [];
  } catch (error) {
    if (error.code === 'ENOENT') return [];
    throw error;
  }
}

export async function createWebPushServer({ dataDirectory, apiToken, allowedOrigin, subject, tlsOptions, push = webpush, ntfy: ntfyConfig, ntfyFetch = fetch, ntfyAttachmentBaseUrl }) {
  if (!apiToken || apiToken.length < 32) throw new Error('WEBPUSH_API_TOKEN must contain at least 32 characters');
  if (!allowedOrigin) throw new Error('WEBPUSH_ALLOWED_ORIGIN must be an https origin');
  const originUrl = new URL(allowedOrigin);
  if (originUrl.protocol !== 'https:' || originUrl.origin !== allowedOrigin) throw new Error('WEBPUSH_ALLOWED_ORIGIN must be an https origin');
  if (!subject || !/^https:\/\//.test(subject) && !/^mailto:[^@\s]+@[^@\s]+$/.test(subject)) {
    throw new Error('WEBPUSH_SUBJECT must be a public https URL or mailto address');
  }

  await mkdir(dataDirectory, { recursive: true, mode: 0o700 });
  await chmod(dataDirectory, 0o700);
  const keys = await readOrCreateKeys(dataDirectory, push);
  if (typeof keys.publicKey !== 'string' || typeof keys.privateKey !== 'string') throw new Error('Invalid VAPID key file');
  push.setVapidDetails(subject, keys.publicKey, keys.privateKey);
  const ntfyPublisher = ntfyConfig ? createNtfyPublisher(validateNtfyConfiguration({ ...ntfyConfig, avatarBaseUrl: ntfyAttachmentBaseUrl }), ntfyFetch) : undefined;
  const notificationImages = new Map();
  let notificationImageBytes = 0;
  const removeNotificationImage = imageId => {
    const image = notificationImages.get(imageId);
    if (!image) return;
    notificationImageBytes -= image.data.length;
    notificationImages.delete(imageId);
  };
  const storeNotificationImage = (imageId, image) => {
    for (const [id, item] of notificationImages) {
      if (item.expiresAt <= Date.now()) removeNotificationImage(id);
    }
    while (notificationImages.size >= MAX_NOTIFICATION_IMAGES ||
      notificationImageBytes + image.data.length > MAX_NOTIFICATION_IMAGE_STORAGE_BYTES) {
      removeNotificationImage(notificationImages.keys().next().value);
    }
    notificationImages.set(imageId, image);
    notificationImageBytes += image.data.length;
  };
  let subscriptions = await readSubscriptions(dataDirectory);
  const saveSubscriptions = async () => {
    const path = join(dataDirectory, 'subscriptions.json');
    await writeFile(path, `${JSON.stringify(subscriptions, null, 2)}\n`, { mode: 0o600 });
    await chmod(path, 0o600);
  };

  const handleRequest = async (request, response) => {
    const origin = request.headers.origin;
    if (origin && origin !== allowedOrigin) return json(response, 403, { error: 'Origin not allowed' });
    if (origin) {
      response.setHeader('access-control-allow-origin', origin);
      response.setHeader('vary', 'Origin');
      response.setHeader('access-control-allow-headers', 'Authorization, Content-Type');
      response.setHeader('access-control-allow-methods', 'GET, POST, OPTIONS');
    }
    if (request.method === 'OPTIONS') {
      response.writeHead(204);
      return response.end();
    }

    const path = new URL(request.url, 'http://localhost').pathname;
    if (request.method === 'GET' && path === '/healthz') return json(response, 200, { ok: true });
    if (request.method === 'GET' && path === '/v1/vapid-public-key') return json(response, 200, { publicKey: keys.publicKey });
    const imageMatch = request.method === 'GET' && path.match(/^\/v1\/notification-images\/([a-f0-9]{64})$/);
    if (imageMatch) {
      const imageId = imageMatch[1];
      const image = notificationImages.get(imageId);
      if (!image || image.expiresAt <= Date.now()) {
        removeNotificationImage(imageId);
        return json(response, 404, { error: 'Image not found' });
      }
      response.writeHead(200, {
        'content-type': image.contentType,
        'content-length': image.data.length,
        'cache-control': 'private, max-age=3600',
        'x-content-type-options': 'nosniff',
      });
      return response.end(image.data);
    }
    if (!authorized(request, apiToken)) return json(response, 401, { error: 'Unauthorized' });

    try {
      if (request.method === 'GET' && path === '/v1/ntfy-config') {
        if (!ntfyPublisher) return json(response, 404, { error: 'ntfy is not configured' });
        return json(response, 200, ntfyPublisher.getClientConfiguration());
      }

      if (request.method === 'POST' && path === '/v1/subscriptions') {
        const subscription = await readJson(request);
        if (!validSubscription(subscription)) return json(response, 400, { error: 'Invalid push subscription' });
        subscriptions = subscriptions.filter(item => item.endpoint !== subscription.endpoint);
        subscriptions.push(subscription);
        await saveSubscriptions();
        return json(response, 201, { saved: true });
      }

      if (request.method === 'POST' && path === '/v1/unsubscribe') {
        const body = await readJson(request);
        if (typeof body?.endpoint !== 'string') return json(response, 400, { error: 'Expected subscription endpoint' });
        const previousCount = subscriptions.length;
        subscriptions = subscriptions.filter(item => item.endpoint !== body.endpoint);
        await saveSubscriptions();
        return json(response, 200, { removed: previousCount - subscriptions.length });
      }

      if (request.method === 'POST' && path === '/v1/send') {
        const payload = await readJson(request);
        if (!payload || typeof payload.title !== 'string' || typeof payload.description !== 'string') {
          return json(response, 400, { error: 'Expected title and description strings' });
        }
        const custom = payload.custom;
        if (custom !== undefined && (!custom || typeof custom !== 'object' || Array.isArray(custom) ||
          !['user', 'group', 'channel'].includes(custom.peer_type) ||
          typeof custom.peer_id !== 'string' || !/^\d{1,20}$/.test(custom.peer_id) ||
          typeof custom.message_id !== 'string' || !/^\d{1,12}$/.test(custom.message_id))) {
          return json(response, 400, { error: 'Invalid Telegram notification route' });
        }
        let notificationImage;
        if (payload.avatar !== undefined) {
          notificationImage = decodeNotificationImage(payload.avatar);
          if (!notificationImage) return json(response, 400, { error: 'Invalid notification avatar image' });
        }
        const body = JSON.stringify({
          title: payload.title.slice(0, 120),
          description: payload.description.slice(0, 500),
          ...(custom ? { custom: {
            peer_type: custom.peer_type,
            peer_id: custom.peer_id,
            message_id: custom.message_id,
          } } : {}),
        });
        if (ntfyPublisher) {
          try {
            let avatarUrl;
            if (notificationImage && ntfyAttachmentBaseUrl) {
              const imageId = randomBytes(32).toString('hex');
              storeNotificationImage(imageId, { ...notificationImage, expiresAt: Date.now() + NOTIFICATION_IMAGE_TTL_MS });
              avatarUrl = `${ntfyAttachmentBaseUrl.replace(/\/+$/, '')}/v1/notification-images/${imageId}`;
            }
            await ntfyPublisher.send({
              title: payload.title.slice(0, 120),
              description: payload.description.slice(0, 500),
              ...(avatarUrl ? { avatarUrl } : {}),
              ...(custom ? { custom: {
                peer_type: custom.peer_type,
                peer_id: custom.peer_id,
                message_id: custom.message_id,
              } } : {}),
            });
          } catch {
            return json(response, 502, { error: 'ntfy delivery failed' });
          }
          return json(response, 200, { sent: 1, failed: 0, provider: 'ntfy' });
        }
        const results = await Promise.allSettled(subscriptions.map(subscription => push.sendNotification(subscription, body, { TTL: 60 })));
        const stale = new Set();
        let sent = 0;
        for (let index = 0; index < results.length; index++) {
          const result = results[index];
          if (result.status === 'fulfilled') sent++;
          else if (result.reason?.statusCode === 404 || result.reason?.statusCode === 410) stale.add(subscriptions[index].endpoint);
        }
        if (stale.size) {
          subscriptions = subscriptions.filter(item => !stale.has(item.endpoint));
          await saveSubscriptions();
        }
        return json(response, 200, { sent, failed: results.length - sent, removedExpired: stale.size });
      }

      return json(response, 404, { error: 'Not found' });
    } catch (error) {
      return json(response, error.status ?? 500, { error: error.status ? error.message : 'Request failed' });
    }
  };
  return tlsOptions ? createHttpsServer(tlsOptions, handleRequest) : createHttpServer(handleRequest);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const port = Number(process.env.PORT ?? 8788);
  const host = process.env.HOST ?? '127.0.0.1';
  const tlsCertPath = process.env.WEBPUSH_TLS_CERT;
  const tlsKeyPath = process.env.WEBPUSH_TLS_KEY;
  if (Boolean(tlsCertPath) !== Boolean(tlsKeyPath)) throw new Error('Set both WEBPUSH_TLS_CERT and WEBPUSH_TLS_KEY, or neither');
  const tlsOptions = tlsCertPath ? {
    cert: await readFile(tlsCertPath),
    key: await readFile(tlsKeyPath),
  } : undefined;
  const server = await createWebPushServer({
    dataDirectory: process.env.WEBPUSH_DATA_DIR ?? join(process.cwd(), 'data'),
    apiToken: process.env.WEBPUSH_API_TOKEN,
    allowedOrigin: process.env.WEBPUSH_ALLOWED_ORIGIN,
    subject: process.env.WEBPUSH_SUBJECT,
    tlsOptions,
    ntfy: process.env.NTFY_SERVER_URL || process.env.NTFY_TOPIC ? {
      serverUrl: process.env.NTFY_SERVER_URL,
      topic: process.env.NTFY_TOPIC,
    } : undefined,
    ntfyAttachmentBaseUrl: process.env.NTFY_ATTACHMENT_BASE_URL,
  });
  server.listen(port, host, () => process.stdout.write(`Web Push sender listening on ${host}:${port}${tlsOptions ? ' (HTTPS)' : ''}\n`));
}
