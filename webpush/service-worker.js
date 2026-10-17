self.addEventListener('install', (event) => event.waitUntil(self.skipWaiting()));
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));
self.addEventListener('push', (event) => {
  let data;
  try { data = event.data.json(); } catch { return; }
  if (!data || data.mute === '1') return;
  const title = data.title || 'Telegram';
  const options = {
    body: data.description || '',
    icon: './icon-192.png',
    badge: './icon-192.png',
    data: { url: './', chatId: data.custom && (data.custom.chat_id || data.custom.channel_id || data.custom.from_id) },
    tag: data.custom && (data.custom.chat_id || data.custom.channel_id || data.custom.from_id) || 'telegram',
  };
  event.waitUntil(self.registration.showNotification(title, options));
});
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil((async () => {
    try {
      const app = await self.clients.openWindow('tgretention://');
      if (app) return app;
    } catch {}
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    if (windows.length) return windows[0].focus();
    return self.clients.openWindow('./');
  })());
});
