import assert from 'node:assert/strict';
import test from 'node:test';
import { createNtfyPublisher, validateNtfyConfiguration } from './ntfy-publisher.mjs';

const config = { serverUrl: 'https://push.example.net:9444', topic: '0123456789abcdef'.repeat(4) };

test('accepts only HTTPS origins and cryptographically random topic names', () => {
  assert.deepEqual(validateNtfyConfiguration(config), config);
  assert.throws(() => validateNtfyConfiguration({ ...config, serverUrl: 'http://push.example.net' }), /HTTPS origin/);
  assert.throws(() => validateNtfyConfiguration({ ...config, serverUrl: 'https://push.example.net/ntfy' }), /HTTPS origin/);
  assert.throws(() => validateNtfyConfiguration({ ...config, topic: 'guessable-topic' }), /64-character lowercase hexadecimal secret/);
});

test('publishes a notification with an encoded native chat route', async () => {
  let request;
  const publisher = createNtfyPublisher(config, async (url, options) => {
    request = { url, options };
    return { ok: true, status: 200 };
  });
  const result = await publisher.send({
    title: 'Family chat', description: 'Привет 👋',
    custom: { peer_type: 'channel', peer_id: '987654321', message_id: '123' },
  });
  assert.deepEqual(result, { sent: 1, failed: 0 });
  assert.equal(request.url, config.serverUrl);
  assert.equal(request.options.method, 'POST');
  assert.equal(request.options.headers['content-type'], 'application/json; charset=utf-8');
  assert.equal(Object.hasOwn(request.options.headers, 'authorization'), false);
  assert.deepEqual(JSON.parse(request.options.body), {
    topic: config.topic,
    title: 'Family chat',
    message: 'Привет 👋',
    click: 'tgretention://open?peer_type=channel&peer_id=987654321&message_id=123',
  });
});

test('adds a validated avatar attachment for the iOS notification preview', async () => {
  let request;
  const avatarBaseUrl = 'https://push.example.net:9443';
  const publisher = createNtfyPublisher({ ...config, avatarBaseUrl }, async (url, options) => {
    request = { url, options };
    return { ok: true, status: 200 };
  });
  await publisher.send({
    title: 'Family chat', description: 'Sam: hello',
    avatarUrl: `${avatarBaseUrl}/v1/notification-images/${'a'.repeat(64)}`,
  });
  assert.equal(JSON.parse(request.options.body).attach, `${avatarBaseUrl}/v1/notification-images/${'a'.repeat(64)}`);
  await assert.rejects(publisher.send({
    title: 'Family chat', description: 'hello', avatarUrl: 'https://evil.example/image.jpg',
  }), /Invalid notification avatar URL/);
});

test('rejects invalid routes and failed ntfy requests', async () => {
  const publisher = createNtfyPublisher(config, async () => ({ ok: false, status: 403 }));
  await assert.rejects(publisher.send({
    title: 'Chat', description: 'Hello', custom: { peer_type: 'user', peer_id: 'not-an-id', message_id: '1' },
  }), /Invalid Telegram notification route/);
  await assert.rejects(publisher.send({ title: 'Chat', description: 'Hello' }), /ntfy returned HTTP 403/);
});

test('returns the private topic URL for the authenticated setup page', () => {
  const publisher = createNtfyPublisher(config);
  assert.deepEqual(publisher.getClientConfiguration(), {
    serverUrl: config.serverUrl,
    topic: config.topic,
    subscriptionUrl: `${config.serverUrl}/${config.topic}`,
  });
});
