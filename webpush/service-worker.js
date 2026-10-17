self.addEventListener('install', (event) => event.waitUntil(self.skipWaiting()));
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));
self.addEventListener('push', (event) => {
  let data;
  try { data = event.data.json(); } catch { return; }
  if (!data || data.mute === '1') return;
  const title = data.title || 'Telegram';
  const custom = data.custom && typeof data.custom === 'object' ? data.custom : undefined;
  const options = {
    body: data.description || '',
    icon: './icon-192.png',
    badge: './icon-192.png',
    data: { url: './', custom },
    tag: custom && custom.peer_id || 'telegram',
  };
  event.waitUntil(self.registration.showNotification(title, options));
});
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil((async () => {
    try {
      const custom = event.notification.data && event.notification.data.custom;
      if (custom && custom.peer_type && custom.peer_id) {
        const target = new URL('open-chat.html', self.registration.scope);
        target.search = new URLSearchParams({
          peer_type: custom.peer_type,
          peer_id: custom.peer_id,
          message_id: custom.message_id || '0',
        }).toString();
        const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
        const appWindow = windows.find(client => client.url.startsWith(self.registration.scope));
        if (appWindow) {
          try {
            const navigated = await appWindow.navigate(target.href);
            if (navigated) {
              await navigated.focus();
              return;
            }
          } catch {}
        }
        await self.clients.openWindow(target.href);
        return;
      }
      const app = await self.clients.openWindow('tgretention://');
      if (app) return app;
    } catch {}
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    if (windows.length) return windows[0].focus();
    return self.clients.openWindow('./');
  })());
});
