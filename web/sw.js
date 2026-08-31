// Пути относительные: приложение живёт не в корне домена, а в /u-coff2/.
const CACHE_NAME = 'u-coffee-v2';
const ASSETS_TO_CACHE = [
  './',
  './index.html',
  './flutter_bootstrap.js',
  './main.dart.js',
  './manifest.json',
  './icons/icon-192.png',
  './icons/icon-512.png',
];

// Install — cache core assets
self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => {
      return cache.addAll(ASSETS_TO_CACHE).catch(() => {
        // Не блокируем установку если часть ресурсов недоступна
      });
    })
  );
  self.skipWaiting();
});

// Activate — clean old caches
self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((names) => {
      return Promise.all(
        names.filter((name) => name !== CACHE_NAME).map((name) => caches.delete(name))
      );
    })
  );
  self.clients.claim();
});

// Fetch — network first, fallback to cache
self.addEventListener('fetch', (event) => {
  // Кэшируем только статику самого приложения. Запросы к Supabase и другим
  // доменам должны идти напрямую, иначе в кэш попадают ответы API.
  const sameOrigin = new URL(event.request.url).origin === self.location.origin;
  if (event.request.method !== 'GET' || !sameOrigin) return;

  event.respondWith(
    fetch(event.request)
      .then((response) => {
        if (response.status === 200) {
          const clone = response.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(event.request, clone));
        }
        return response;
      })
      .catch(() => caches.match(event.request))
  );
});
