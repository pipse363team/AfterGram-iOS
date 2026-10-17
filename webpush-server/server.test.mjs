import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import webpush from 'web-push';
import { createWebPushServer } from './server.mjs';

const token = 'test-api-token-which-is-at-least-thirty-two-characters';
const subscription = {
  endpoint: 'https://push.example.net/send/abc',
  keys: { p256dh: 'browser-public-key', auth: 'browser-auth-secret' },
};

async function withServer(run) {
  const dataDirectory = await mkdtemp(join(tmpdir(), 'aftergram-webpush-'));
  const sends = [];
  const fakePush = {
    generateVAPIDKeys: () => ({ publicKey: 'public-vapid', privateKey: 'private-vapid' }),
    setVapidDetails: (...args) => { fakePush.vapidDetails = args; },
    sendNotification: async (...args) => { sends.push(args); },
  };
  const server = await createWebPushServer({
    dataDirectory,
    apiToken: token,
    allowedOrigin: 'https://pipse363team.github.io',
    subject: 'mailto:push@example.net',
    push: fakePush,
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const baseUrl = `http://127.0.0.1:${server.address().port}`;
  try {
    await run({ baseUrl, dataDirectory, sends, fakePush });
  } finally {
    await new Promise(resolve => server.close(resolve));
    await rm(dataDirectory, { recursive: true, force: true });
  }
}

test('serves only the public VAPID key and persists the generated private key locally', async () => {
  await withServer(async ({ baseUrl, dataDirectory, fakePush }) => {
    const response = await fetch(`${baseUrl}/v1/vapid-public-key`);
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { publicKey: 'public-vapid' });
    assert.deepEqual(fakePush.vapidDetails, ['mailto:push@example.net', 'public-vapid', 'private-vapid']);
    assert.deepEqual(JSON.parse(await readFile(join(dataDirectory, 'vapid-keys.json'), 'utf8')), {
      publicKey: 'public-vapid', privateKey: 'private-vapid',
    });
  });
});

test('requires the bearer token to save a subscription and send a push', async () => {
  await withServer(async ({ baseUrl, sends }) => {
    const rejected = await fetch(`${baseUrl}/v1/subscriptions`, {
      method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(subscription),
    });
    assert.equal(rejected.status, 401);

    const headers = { authorization: `Bearer ${token}`, 'content-type': 'application/json' };
    const saved = await fetch(`${baseUrl}/v1/subscriptions`, {
      method: 'POST', headers, body: JSON.stringify(subscription),
    });
    assert.equal(saved.status, 201);

    const sent = await fetch(`${baseUrl}/v1/send`, {
      method: 'POST', headers, body: JSON.stringify({ title: 'Telegram', description: 'New message' }),
    });
    assert.equal(sent.status, 200);
    assert.deepEqual(await sent.json(), { sent: 1, failed: 0, removedExpired: 0 });
    assert.equal(sends.length, 1);
    assert.equal(sends[0][0].endpoint, subscription.endpoint);
    assert.deepEqual(JSON.parse(sends[0][1]), { title: 'Telegram', description: 'New message' });

    const removed = await fetch(`${baseUrl}/v1/unsubscribe`, {
      method: 'POST', headers, body: JSON.stringify({ endpoint: subscription.endpoint }),
    });
    assert.equal(removed.status, 200);
    assert.deepEqual(await removed.json(), { removed: 1 });
  });
});

test('rejects non-HTTPS subscriptions and disallowed origins', async () => {
  await withServer(async ({ baseUrl }) => {
    const headers = { authorization: `Bearer ${token}`, 'content-type': 'application/json' };
    const invalid = await fetch(`${baseUrl}/v1/subscriptions`, {
      method: 'POST', headers, body: JSON.stringify({ ...subscription, endpoint: 'http://127.0.0.1/private' }),
    });
    assert.equal(invalid.status, 400);

    const disallowed = await fetch(`${baseUrl}/v1/vapid-public-key`, { headers: { origin: 'https://attacker.invalid' } });
    assert.equal(disallowed.status, 403);
  });
});

test('creates a stable real VAPID pair without returning the private key', async () => {
  const dataDirectory = await mkdtemp(join(tmpdir(), 'aftergram-vapid-'));
  const options = {
    dataDirectory,
    apiToken: token,
    allowedOrigin: 'https://pipse363team.github.io',
    subject: 'mailto:push@example.net',
  };
  const first = await createWebPushServer(options);
  await new Promise(resolve => first.listen(0, '127.0.0.1', resolve));
  const firstResponse = await fetch(`http://127.0.0.1:${first.address().port}/v1/vapid-public-key`);
  const firstBody = await firstResponse.json();
  const storedKeys = JSON.parse(await readFile(join(dataDirectory, 'vapid-keys.json'), 'utf8'));
    assert.equal((await stat(dataDirectory)).mode & 0o777, 0o700);
    assert.equal((await stat(join(dataDirectory, 'vapid-keys.json'))).mode & 0o777, 0o600);
  assert.equal(firstBody.publicKey, storedKeys.publicKey);
  assert.equal(Object.hasOwn(firstBody, 'privateKey'), false);
  assert.equal(storedKeys.privateKey.length, 43);
  assert.equal(storedKeys.publicKey.length, 87);
  await new Promise(resolve => first.close(resolve));

  const second = await createWebPushServer(options);
  await new Promise(resolve => second.listen(0, '127.0.0.1', resolve));
  const secondResponse = await fetch(`http://127.0.0.1:${second.address().port}/v1/vapid-public-key`);
  assert.deepEqual(await secondResponse.json(), firstBody);
  await new Promise(resolve => second.close(resolve));
  await rm(dataDirectory, { recursive: true, force: true });
});
