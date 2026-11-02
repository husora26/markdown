// HUSORA · Service Worker nur für Push-Benachrichtigungen (Phase 9).
// Bewusst ohne Offline-Cache: die App lädt immer die aktuelle Version.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));
self.addEventListener('push', (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch (error) { data = { title: 'Husora', body: event.data ? event.data.text() : '' }; }
  const title = String(data.title || 'Husora').slice(0, 120);
  event.waitUntil(self.registration.showNotification(title, {
    body: String(data.body || '').slice(0, 200),
    tag: data.tag || 'husora',
    icon: 'assets/icon-192.png',
    badge: 'assets/icon-192.png',
    data: { url: data.url || './' }
  }));
});
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const url = event.notification.data?.url || './';
  event.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((list) => {
    const open = list.find((c) => c.url.startsWith(self.registration.scope));
    return open ? open.focus() : self.clients.openWindow(url);
  }));
});
