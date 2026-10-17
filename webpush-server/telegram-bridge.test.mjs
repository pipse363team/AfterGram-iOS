import test from 'node:test';
import assert from 'node:assert/strict';
import { formatTelegramNotification, sendTelegramNotification } from './telegram-bridge.mjs';

test('formats incoming private messages with an app chat and message route', async () => {
  const payload = await formatTelegramNotification({
    isPrivate: true,
    getChat: async () => ({ className: 'User', firstName: 'Alex' }),
    message: {
      id: 42,
      peerId: { className: 'PeerUser', userId: 123456789n },
      message: 'hello',
      getSender: async () => ({ firstName: 'Alex', lastName: 'Smith' }),
    },
  });
  assert.deepEqual(payload, {
    title: 'Alex Smith', description: 'hello',
    custom: { peer_type: 'user', peer_id: '123456789', message_id: '42' },
  });
});

test('formats incoming group media without text', async () => {
  const payload = await formatTelegramNotification({
    isPrivate: false,
    getChat: async () => ({ title: 'Friends' }),
    message: {
      id: 7,
      peerId: { className: 'PeerChannel', channelId: 987654321n },
      media: { className: 'MessageMediaPhoto' },
      getSender: async () => ({ firstName: 'Sam' }),
    },
  });
  assert.equal(payload.title, 'Friends');
  assert.equal(payload.description, 'Sam: Photo');
  assert.deepEqual(payload.custom, { peer_type: 'channel', peer_id: '987654321', message_id: '7' });
});

test('does not notify for outgoing or unsupported peer messages', async () => {
  assert.equal(await formatTelegramNotification({ message: { out: true, id: 1 } }), undefined);
  assert.equal(await formatTelegramNotification({ message: { id: 1, peerId: { className: 'PeerSecret' } } }), undefined);
});

test('sends route metadata to the authenticated sender endpoint', async () => {
  let request;
  const result = await sendTelegramNotification({
    isPrivate: true,
    getChat: async () => undefined,
    message: {
      id: 5,
      peerId: { className: 'PeerUser', userId: 11n },
      message: 'hi',
      getSender: async () => ({ firstName: 'Pat' }),
    },
  }, {
    endpoint: 'https://push.example:9443/',
    apiToken: 'secret',
    fetchImpl: async (url, options) => {
      request = { url, options };
      return { ok: true, json: async () => ({ sent: 1, failed: 0 }) };
    },
  });
  assert.equal(result, true);
  assert.equal(request.url, 'https://push.example:9443/v1/send');
  assert.equal(request.options.headers.authorization, 'Bearer secret');
  assert.equal(JSON.parse(request.options.body).custom.message_id, '5');
});

test('reports when the push sender has no saved subscriptions', async () => {
  await assert.rejects(sendTelegramNotification({
    isPrivate: true,
    message: {
      id: 5,
      peerId: { className: 'PeerUser', userId: 11n },
      message: 'hi',
      getSender: async () => ({ firstName: 'Pat' }),
    },
  }, {
    endpoint: 'https://push.example:9443',
    apiToken: 'secret',
    fetchImpl: async () => ({ ok: true, json: async () => ({ sent: 0, failed: 0 }) }),
  }), /no saved subscriptions/);
});
