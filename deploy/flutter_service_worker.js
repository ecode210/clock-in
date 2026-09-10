// Replaces Flutter's offline-first worker. Phones that already installed
// that worker keep intercepting every request, so a new deploy never reaches
// them. This file is fetched from the same URL on the next visit, then
// clears caches, unregisters, and reloads the tab onto the live bundle.
self.addEventListener('install', (event) => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      const keys = await caches.keys();
      await Promise.all(keys.map((key) => caches.delete(key)));
      await self.clients.claim();
      await self.registration.unregister();
      const clients = await self.clients.matchAll({ type: 'window' });
      for (const client of clients) {
        client.navigate(client.url);
      }
    })(),
  );
});
