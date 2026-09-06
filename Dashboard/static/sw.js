/* ---------------------------------------------------------------------------
   aniGamerPlus+ service worker
   Just enough to make the app launchable from the iOS home screen: the shell
   is cached so a cold standalone start paints instantly, while everything
   that is actually live data goes straight to the network.
   --------------------------------------------------------------------------- */
'use strict';

var CACHE = 'agp-shell-v7';

/* Bare paths on purpose: the ?v= tokens in the templates move whenever an asset
   changes, and a list that pinned them would drift out of step unnoticed. These
   copies are the offline fallback; the runtime cache holds the versioned ones. */
var SHELL = [
    './',
    './static/css/agp.css',
    './static/css/home.css',
    './static/css/catalog.css',
    './static/css/watch.css',
    './static/js/agp-shell.js',
    './static/js/home.js',
    './static/js/catalog.js',
    './static/js/userapi.js',
    './static/img/aniGamerPlus.ico',
    './static/img/pwa/icon-192.png',
    './static/img/pwa/apple-touch-icon.png',
    './manifest.webmanifest'
];

self.addEventListener('install', function (event) {
    event.waitUntil(
        caches.open(CACHE).then(function (cache) {
            /* One missing entry must not fail the whole install, so each asset
               is added on its own and allowed to lose. */
            return Promise.all(SHELL.map(function (url) {
                return cache.add(new Request(url, { cache: 'reload' })).catch(function () { });
            }));
        }).then(function () { return self.skipWaiting(); })
    );
});

self.addEventListener('activate', function (event) {
    event.waitUntil(
        caches.keys().then(function (keys) {
            return Promise.all(keys.map(function (key) {
                return key === CACHE ? null : caches.delete(key);
            }));
        }).then(function () { return self.clients.claim(); })
    );
});

/* Anything below is per-user, live, or range-requested. Serving a stale or
   whole-file response for these would break resume positions and iOS video
   seeking outright. Posters join them: the server answers those with an ETag
   and a Cache-Control lifetime, and CacheStorage would ignore both. */
var BYPASS = [
    '/get_video.mp4',
    '/get_danmu.ass',
    '/thumbnail.jpg',
    '/video_list.json',
    '/watch/time',
    '/login',
    '/logout',
    '/register',
    '/user',
    '/config',
    '/sn_list',
    '/catalog',
    '/msg'
];

/* Only a versioned asset may be answered from CacheStorage: its ?v= token
   changes with the file, so a stale body cannot outlive its URL. CacheStorage
   ignores HTTP freshness headers, so anything else kept here would be pinned to
   its first response for the life of the cache. */
function isVersionedAsset(url) {
    return url.pathname.indexOf('/static/') === 0 && /[?&]v=/.test(url.search);
}

function shouldBypass(url, request) {
    if (request.headers.has('range')) { return true; }
    /* Every token above names a root-level route, but the scan below is a plain
       substring test: without this line '/user' also fires on userapi.js, which
       would leave a precached asset permanently unreachable. */
    if (url.pathname.indexOf('/static/') === 0) { return false; }
    for (var i = 0; i < BYPASS.length; i++) {
        if (url.pathname.indexOf(BYPASS[i]) !== -1) { return true; }
    }
    return false;
}

self.addEventListener('fetch', function (event) {
    var request = event.request;
    if (request.method !== 'GET') { return; }

    var url;
    try {
        url = new URL(request.url);
    } catch (error) {
        return;
    }
    if (url.origin !== self.location.origin) { return; }
    if (shouldBypass(url, request)) { return; }

    /* Navigations stay network-first: the dashboard renders per-session state
       into the page, so a cached copy is only ever the offline fallback. */
    if (request.mode === 'navigate') {
        event.respondWith(
            fetch(request).catch(function () {
                return caches.match(request).then(function (hit) {
                    return hit || caches.match('./');
                });
            })
        );
        return;
    }

    if (isVersionedAsset(url)) {
        event.respondWith(
            caches.match(request).then(function (hit) {
                if (hit) { return hit; }
                return fetch(request).then(function (response) {
                    if (response && response.ok && response.type === 'basic') {
                        var copy = response.clone();
                        caches.open(CACHE).then(function (cache) { cache.put(request, copy); });
                    }
                    return response;
                }).catch(function () {
                    /* Offline holding a token this cache has never seen: the
                       shell copy stored under the bare path is the same file,
                       and a possibly-older script beats no script at all. */
                    return caches.match(request, { ignoreSearch: true }).then(function (fallback) {
                        return fallback || Response.error();
                    });
                });
            })
        );
        return;
    }

    /* Unversioned assets and every live endpoint go to the network. The vendored
       libraries under /static/ are copied in on the way past so a cold offline
       start still has them; nothing else is stored, because CacheStorage ignores
       freshness and would pin a live response for the life of the cache. */
    event.respondWith(
        fetch(request).then(function (response) {
            if (response && response.ok && response.type === 'basic' &&
                url.pathname.indexOf('/static/') === 0) {
                /* The copy has to be taken before the page starts reading the
                   body, so it is taken first and dropped again when the library
                   is already stored -- otherwise every navigation rewrites it. */
                var copy = response.clone();
                caches.open(CACHE).then(function (cache) {
                    return cache.match(request).then(function (stored) {
                        if (!stored) { cache.put(request, copy); }
                    });
                });
            }
            return response;
        }).catch(function () {
            return caches.match(request).then(function (hit) {
                return hit || Response.error();
            });
        })
    );
});
