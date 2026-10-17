import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const serviceWorkerSource = await readFile(new URL('../webpush/service-worker.js', import.meta.url), 'utf8');

function createWorker(supportsNavigate = false) {
  const listeners = new Map();
  let shown;
  let openedUrl;
  class MockNotification {}
  if (supportsNavigate) Object.defineProperty(MockNotification.prototype, 'navigate', { value: '', configurable: true });
  const context = {
    Notification: MockNotification,
    URL,
    URLSearchParams,
    indexedDB: { open() { throw new Error('IndexedDB unavailable in this test'); } },
    self: {
      addEventListener: (name, listener) => listeners.set(name, listener),
      registration: {
        scope: 'https://pipse363team.github.io/AfterGram-iOS/webpush/',
        showNotification: async (title, options) => { shown = { title, options }; },
      },
      clients: {
        matchAll: async () => [],
        openWindow: async (url) => { openedUrl = url; return null; },
      },
    },
  };
  vm.runInNewContext(serviceWorkerSource, context);
  return { listeners, get shown() { return shown; }, get openedUrl() { return openedUrl; } };
}

async function dispatchPush(worker, custom) {
  let pending;
  worker.listeners.get('push')({
    data: { json: () => ({ title: 'Telegram', custom }) },
    waitUntil: (promise) => { pending = promise; },
  });
  await pending;
}

test('keeps notification taps on the handoff flow even when declarative navigation exists', async () => {
  const worker = createWorker(true);
  const custom = { peer_type: 'group', peer_id: '12345', message_id: '67' };
  await dispatchPush(worker, custom);

  assert.equal('navigate' in worker.shown.options, false);

  let pending;
  worker.listeners.get('notificationclick')({
    notification: { data: { custom }, close() {} },
    waitUntil: (promise) => { pending = promise; },
  });
  await pending;
  assert.equal(worker.openedUrl, 'https://pipse363team.github.io/AfterGram-iOS/webpush/open-chat.html?peer_type=group&peer_id=12345&message_id=67');
});
