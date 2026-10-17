import { createServer as createHttpServer } from 'node:http';
import { createServer as createHttpsServer } from 'node:https';
import { chmod, mkdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { timingSafeEqual } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import webpush from 'web-push';

const MAX_BODY_BYTES = 16 * 1024;

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

export async function createWebPushServer({ dataDirectory, apiToken, allowedOrigin, subject, tlsOptions, push = webpush }) {
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
    if (!authorized(request, apiToken)) return json(response, 401, { error: 'Unauthorized' });

    try {
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
        const body = JSON.stringify({ title: payload.title.slice(0, 120), description: payload.description.slice(0, 500) });
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
  });
  server.listen(port, host, () => process.stdout.write(`Web Push sender listening on ${host}:${port}${tlsOptions ? ' (HTTPS)' : ''}\n`));
}
