import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const serviceWorkerSource = await readFile(new URL('../webpush/service-worker.js', import.meta.url), 'utf8');

async function shownNotification(custom, supportsNavigate) {
  const listeners = new Map();
  let shown;
  class MockNotification {}
  if (supportsNavigate) Object.defineProperty(MockNotification.prototype, 'navigate', { value: '', configurable: true });
  const context = {
    Notification: MockNotification,
    URL,
    URLSearchParams,
    self: {
      addEventListener: (name, listener) => listeners.set(name, listener),
      registration: { showNotification: async (title, options) => { shown = { title, options }; } },
      clients: {},
    },
  };
  vm.runInNewContext(serviceWorkerSource, context);
  let pending;
  listeners.get('push')({
    data: { json: () => ({ title: 'Telegram', custom }) },
    waitUntil: (promise) => { pending = promise; },
  });
  await pending;
  return shown;
}

test('sets a native chat URL on notification activation when declarative navigation is supported', async () => {
  const notification = await shownNotification({ peer_type: 'group', peer_id: '12345', message_id: '67' }, true);
  assert.equal(notification.options.navigate, 'tgretention://open?peer_type=group&peer_id=12345&message_id=67');
});

test('keeps the in-app handoff fallback when notification navigation is unsupported', async () => {
  const notification = await shownNotification({ peer_type: 'user', peer_id: '12345', message_id: '67' }, false);
  assert.equal('navigate' in notification.options, false);
});
