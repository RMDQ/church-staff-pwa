'use strict';

// Custom cache-first service worker for church_staff_pwa.
//
// Why this exists: Flutter 3.27+ ships a `flutter_service_worker.js` that
// unregisters itself on activate (the auto-generated one is intentionally
// destructive — Flutter expects apps to bring their own SW). Without a
// caching SW, every reload re-downloads main.dart.js (~3MB) and
// canvaskit.wasm (~7MB).
//
// Strategy:
//   - cache-first for hashed/static assets (.js, .wasm, fonts, images)
//   - network-first for navigation entry files so updates land fast
//     (index.html, manifest.json, version.json, flutter_bootstrap.js)
//   - never intercept Firestore / Firebase / Google Calendar / FCM —
//     those must always be live
//
// Cache invalidation: CI replaces __BUILD_VERSION__ with the deploy SHA so
// each release produces a unique cache name. The activate handler then
// deletes any cache whose key doesn't match the current version.
//
// Two caches, on purpose:
//   - app cache    keyed by build SHA. main.dart.js and friends change on
//                  every deploy, so they must be re-fetched every deploy.
//   - vendor cache keyed by the Flutter SDK version. canvaskit.wasm alone is
//                  ~7 MB (2.8 MB gzipped) and does NOT change when app code
//                  changes — only when the pinned Flutter version does.
//                  Sharing one build-keyed cache meant every deploy threw it
//                  away and the next visit re-downloaded the whole engine.
//                  CI injects the Flutter version pinned in
//                  .github/workflows/deploy-flutter-pwa.yml, so bumping
//                  Flutter is what invalidates the engine — nothing else.
//
// Local builds keep the literal '__BUILD_VERSION__'. That's intentionally
// fine: `flutter run -d chrome` bypasses SWs, and for hand-served
// `flutter build web` you'd clear DevTools storage between iterations
// anyway. The only place per-deploy invalidation actually matters is
// production, and the deploy workflow is fail-fast if the placeholder
// isn't substituted.

const CACHE_VERSION = '__BUILD_VERSION__';
const CACHE_NAME = `church-staff-pwa-${CACHE_VERSION}`;

const VENDOR_VERSION = '__VENDOR_VERSION__';
const VENDOR_CACHE_NAME = `church-staff-pwa-vendor-${VENDOR_VERSION}`;

// CanvasKit 内建字型不含中文字。遇到 bundle 里没有的字，engine 会在
// runtime 去 fonts.gstatic.com 抓 Noto Sans TC/SC 的 subset —— 也就是说
// 卷动到还没载过的姓名时，会临时发网路请求、解字型、重排版，直接表现成
// 一格一格的卡顿。iOS 加到桌面的 PWA 又特别容易把 HTTP cache 清掉，
// 所以每次冷启动都可能重来一次。
//
// 这个 cache 不绑任何版本：字型 URL 本身就是内容定址（改版会换 URL），
// 而且跟 App 或 Flutter 版本都无关，没有理由跟著失效。
const FONT_CACHE_NAME = 'church-staff-pwa-fonts-v1';
const FONT_HOSTNAMES = ['fonts.gstatic.com', 'fonts.googleapis.com'];

// 字型 subset 是「每遇到一个新的 Unicode 范围就多一个 URL」，没有上限的话
// 这个 cache 会一直长大。iOS 的每来源储存配额很小，一旦超过，Safari 会把
// 整个来源的 Cache Storage 清掉 —— 连 App 本体与引擎的快取一起赔进去。
// 超过上限就从最旧的开始删（Cache.keys() 依插入顺序回传）。
const FONT_CACHE_MAX_ENTRIES = 64;

// Same-origin path prefixes whose bytes are tied to the Flutter SDK version
// rather than to our app code, so they can outlive an app deploy.
//
// ONLY /canvaskit/ qualifies. Do NOT add /assets/fonts/ or the bundled icon
// fonts here: `uses-material-design: true` makes Flutter tree-shake
// MaterialIcons down to the glyphs this build actually references (12 KB, not
// the SDK's 1.6 MB) and ships it at an unhashed URL. Caching that across
// deploys means the first release that uses a new icon renders it as a tofu
// box forever, because the vendor cache still holds the older subset.
//
// This requires `flutter build web --no-web-resources-cdn`: with the default
// CDN mode the engine loads CanvasKit from www.gstatic.com and this prefix
// never matches anything.
const VENDOR_PATH_PREFIXES = ['/canvaskit/'];

// Same-origin paths that should be re-fetched from network when online so
// users see updates promptly. Cached copy is the offline fallback.
//
// `/version.json` deliberately does NOT belong here — it falls through to
// cacheFirst below. 个人页的「更新于」读的就是这份档案，而那行字要回答的是
// 「我手上这个 App 是哪一版」，不是「伺服器现在部署到哪一版」。CACHE_NAME 绑
// build SHA，所以 cache-first 拿到的必定是「正在跑的那一版」随 bundle 一起进
// 快取的那份 —— 这正是 477ad89 的意图（它把 version.json 的产生移到
// `flutter build` 之前，就是为了让它进得了这个快取）。
//
// 放进 network-first 会静默撤销那个修正：旧的 SW 还在服务旧的 main.dart.js，
// version.json 却是网路上最新的，画面显示「已更新」但跑的其实是旧 bundle ——
// 一个装置到底更新了没有，就再也看不出来。实际踩过一次：一位使用者截图显示
// 「更新于 10:51」，那正是伺服器部署完成的时间，跟他手机上跑的版本无关。
//
// 更新侦测不靠这个档案，靠的是 SW 自己的 updatefound / SKIP_WAITING
// （见 web/app_update.js），所以 cache-first 不会让任何人卡在旧版。
// `/app_update.js` 同理但反过来：它是「换到新版」那段交接程式码，被自己的旧
// 快取服务的话，卡住的装置就再也救不回来（修好的交接流程永远载不进去）。
const NETWORK_FIRST_PATHS = new Set([
  '/',
  '/index.html',
  '/app_update.js',
  '/manifest.json',
  '/flutter_bootstrap.js',
  '/flutter.js',
]);

// Service-worker scripts must always go directly to the network so the
// browser's update flow sees a fresh script and can install a new SW
// version. Caching SW bytes is dangerous because stale cached SW could
// break future updates.
const NEVER_INTERCEPT_PATHS = new Set([
  '/cache_sw.js',
  '/flutter_service_worker.js',
  '/firebase-messaging-sw.js',
]);

// Cross-origin hostnames whose responses must never be cached.
const NEVER_CACHE_HOSTNAME_SUFFIXES = [
  'firestore.googleapis.com',
  'firebaseinstallations.googleapis.com',
  'fcmregistrations.googleapis.com',
  'identitytoolkit.googleapis.com',
  'securetoken.googleapis.com',
  'fcm.googleapis.com',
  'googleapis.com', // Calendar API + general Firebase
  'firebaseio.com',
  'cloudfunctions.net',
  'gstatic.com', // Firebase JS SDK; let the browser's HTTP cache handle it
  'raw.githubusercontent.com', // daily verse JSON
];

self.addEventListener('install', () => {
  // Only auto-skipWaiting on first install (no previously active SW). On
  // upgrades we wait until the page explicitly posts SKIP_WAITING —
  // app_update.js owns that hand-off (it sends SKIP_WAITING once the new
  // worker is installed, then reloads on controllerchange).
  if (!self.registration.active) {
    self.skipWaiting();
  }
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    const keep = new Set([CACHE_NAME, VENDOR_CACHE_NAME, FONT_CACHE_NAME]);
    await Promise.all(
      keys
        .filter((k) => k.startsWith('church-staff-pwa-') && !keep.has(k))
        .map((k) => caches.delete(k)),
    );
    await self.clients.claim();
  })());
});

self.addEventListener('message', (event) => {
  if (event.data && event.data.type === 'SKIP_WAITING') {
    self.skipWaiting();
  }
});

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') return;

  const url = new URL(request.url);

  // 字型要摆在 never-cache 检查之前：fonts.gstatic.com 也是 gstatic.com，
  // 会被下面那条规则扫到。
  if (FONT_HOSTNAMES.includes(url.hostname)) {
    event.respondWith(cacheFirst(event, FONT_CACHE_NAME, trimFontCache));
    return;
  }

  // Never intercept live API calls.
  if (NEVER_CACHE_HOSTNAME_SUFFIXES.some((h) => url.hostname.endsWith(h))) {
    return;
  }

  // Only handle same-origin assets here. Other cross-origin fetches go to
  // the network unmanaged.
  if (url.origin !== self.location.origin) return;

  // Service-worker scripts go to the network unmanaged so browser update
  // detection works correctly.
  if (NEVER_INTERCEPT_PATHS.has(url.pathname)) return;

  // The site's own Pages Functions answer live, per-request data (today's
  // devotional passage, for one); a cached copy would be served forever.
  if (url.pathname.startsWith('/api/')) return;

  if (NETWORK_FIRST_PATHS.has(url.pathname)) {
    event.respondWith(networkFirst(event));
  } else if (VENDOR_PATH_PREFIXES.some((p) => url.pathname.startsWith(p))) {
    // Engine bytes survive app deploys — see the VENDOR_CACHE_NAME note above.
    event.respondWith(cacheFirst(event, VENDOR_CACHE_NAME));
  } else {
    event.respondWith(cacheFirst(event));
  }
});

async function networkFirst(event) {
  const request = event.request;
  const cache = await caches.open(CACHE_NAME);
  try {
    const response = await fetch(request);
    if (response && response.ok) {
      // Clone before caching — Response bodies can only be consumed once.
      event.waitUntil(persist(cache, request, response.clone()));
    }
    return response;
  } catch (e) {
    const cached = await cache.match(request);
    if (cached) return cached;
    throw e;
  }
}

async function cacheFirst(event, cacheName = CACHE_NAME, afterPut) {
  const request = event.request;
  const cache = await caches.open(cacheName);
  const cached = await cache.match(request);
  if (cached) return cached;
  const response = await fetch(request);
  if (response && response.ok) {
    // 只回应、不 await 写入，让使用者不必等 cache.put 才拿到 bytes。
    event.waitUntil(persist(cache, request, response.clone(), afterPut));
  }
  return response;
}

// 写入一定要包在 event.waitUntil 里。respondWith 的 promise 一 resolve，
// 这个 fetch event 就算处理完了，浏览器随时可以把 service worker 收掉 ——
// 没被 waitUntil 追踪的 cache.put 会跟著 SW 一起被砍，表现成「快取时有时无」，
// 冷启动一次抓进去好几十个资产时特别容易中。
//
// put 失败（iOS 上最常见的是配额爆掉）之后仍然要跑 afterPut：字型 cache 正是
// 靠 trim 缩回上限内的，把 trim 绑在成功路径上等于「一超过配额就再也修不回来」，
// 刚好在最需要它的时候失效。
async function persist(cache, request, response, afterPut) {
  try {
    await cache.put(request, response);
  } catch (_) {
    // 写不进去就算了，下次请求会重新抓。
  }
  if (!afterPut) return;
  try {
    await afterPut(cache);
  } catch (_) {
    // trim 失败不影响已经回给页面的回应。
  }
}

// 保留最新的 FONT_CACHE_MAX_ENTRIES 笔，其余从最旧的开始删。
async function trimFontCache(cache) {
  const keys = await cache.keys();
  const excess = keys.length - FONT_CACHE_MAX_ENTRIES;
  if (excess <= 0) return;
  await Promise.all(keys.slice(0, excess).map((key) => cache.delete(key)));
}
