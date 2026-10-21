import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import {
  BUILD_CACHE,
  FONT_CACHE,
  ORIGIN,
  VENDOR_CACHE,
  loadServiceWorker,
} from './helpers.js';

describe('版本资讯 version.json', () => {
  // This is the whole reason this test directory exists. `version.json` has
  // been network-first twice (once by construction, once when the custom SW
  // was written), and both times it silently broke the same thing: 个人页的
  // 「更新于」显示伺服器最新的部署时间，而不是这台装置正在跑的版本。 A device
  // still serving an old main.dart.js from an old cache showed the newest
  // deploy's timestamp and looked up to date — which is exactly the case the
  // line exists to reveal. Someone reported a bug that was already fixed,
  // and the screenshot "proving" they were on the new build proved nothing.
  test('从绑 build 的快取读，也就是「正在跑的那一版」', async () => {
    const sw = loadServiceWorker();
    sw.seed(BUILD_CACHE, `${ORIGIN}/version.json`);

    assert.equal(await sw.request(`${ORIGIN}/version.json`), `cache:${BUILD_CACHE}`);
  });

  test('快取没有时才去网路，并且存起来', async () => {
    const sw = loadServiceWorker();

    assert.equal(await sw.request(`${ORIGIN}/version.json`), 'network');
    assert.deepEqual(sw.cachedUrls(BUILD_CACHE), [`${ORIGIN}/version.json`]);
  });
});

describe('进入点走 network-first', () => {
  // These are the files that must be able to point at a newer build; caching
  // them first would pin the app to whatever it loaded on day one.
  for (const path of [
    '/',
    '/index.html',
    '/app_update.js',
    '/manifest.json',
    '/flutter_bootstrap.js',
    '/flutter.js',
  ]) {
    test(`${path} 有网路时一律拿网路那份`, async () => {
      const sw = loadServiceWorker();
      sw.seed(BUILD_CACHE, `${ORIGIN}${path}`);

      assert.equal(await sw.request(`${ORIGIN}${path}`), 'network');
    });
  }

  test('离线时退回快取', async () => {
    const sw = loadServiceWorker();
    sw.seed(BUILD_CACHE, `${ORIGIN}/index.html`);
    sw.setFetch(async () => {
      throw new Error('offline');
    });

    assert.equal(await sw.request(`${ORIGIN}/index.html`), `cache:${BUILD_CACHE}`);
  });

  test('离线又没有快取就照实抛错', async () => {
    const sw = loadServiceWorker();
    sw.setFetch(async () => {
      throw new Error('offline');
    });

    await assert.rejects(() => sw.request(`${ORIGIN}/index.html`), /offline/);
  });
});

describe('静态资产走 cache-first', () => {
  test('App bundle 放在绑 build SHA 的快取', async () => {
    const sw = loadServiceWorker();
    sw.seed(BUILD_CACHE, `${ORIGIN}/main.dart.js`);

    assert.equal(await sw.request(`${ORIGIN}/main.dart.js`), `cache:${BUILD_CACHE}`);
  });

  test('CanvasKit 放在绑 Flutter 版本的 vendor 快取，才能跨 deploy 存活', async () => {
    const sw = loadServiceWorker();
    sw.seed(VENDOR_CACHE, `${ORIGIN}/canvaskit/canvaskit.wasm`);

    assert.equal(
      await sw.request(`${ORIGIN}/canvaskit/canvaskit.wasm`),
      `cache:${VENDOR_CACHE}`,
    );
  });

  test('字型与图示不算 vendor：tree-shake 过的 MaterialIcons 必须跟著 build 换', async () => {
    // 这个子集是 build 产物（只含这一版用到的字符），放进 vendor 快取的话，
    // 新版第一次用到的图示会永远是空白方框。
    const sw = loadServiceWorker();

    assert.equal(await sw.request(`${ORIGIN}/assets/fonts/MaterialIcons-Regular.otf`), 'network');
    assert.deepEqual(sw.cachedUrls(VENDOR_CACHE), []);
    assert.deepEqual(sw.cachedUrls(BUILD_CACHE), [
      `${ORIGIN}/assets/fonts/MaterialIcons-Regular.otf`,
    ]);
  });
});

describe('不能拦截的请求', () => {
  test('service worker 本身：拦了就毁掉浏览器的更新侦测', async () => {
    const sw = loadServiceWorker();
    for (const path of ['/cache_sw.js', '/flutter_service_worker.js', '/firebase-messaging-sw.js']) {
      sw.seed(BUILD_CACHE, `${ORIGIN}${path}`);
      assert.equal(await sw.request(`${ORIGIN}${path}`), 'passthrough', path);
    }
  });

  test('后端 API 一律直通，不进任何快取', async () => {
    const sw = loadServiceWorker();
    const live = [
      'https://firestore.googleapis.com/v1/projects/demo-church-staff/databases/(default)/documents/rosters',
      'https://identitytoolkit.googleapis.com/v1/accounts:lookup',
      'https://securetoken.googleapis.com/v1/token',
      'https://fcm.googleapis.com/fcm/send',
      'https://raw.githubusercontent.com/x/y/daily-verse.json',
      `${ORIGIN}/api/devotional/today`,
    ];
    for (const url of live) {
      assert.equal(await sw.request(url), 'passthrough', url);
    }
    assert.deepEqual(sw.cacheNames(), []);
  });

  test('非 GET 不处理', async () => {
    const sw = loadServiceWorker();
    sw.seed(BUILD_CACHE, `${ORIGIN}/main.dart.js`);

    assert.equal(await sw.request(`${ORIGIN}/main.dart.js`, { method: 'POST' }), 'passthrough');
  });
});

describe('中文字型快取', () => {
  test('fonts.gstatic.com 进自己的快取，不跟著 deploy 失效', async () => {
    const sw = loadServiceWorker();

    assert.equal(await sw.request('https://fonts.gstatic.com/s/notosanstc/subset-1.woff2'), 'network');
    assert.deepEqual(sw.cachedUrls(FONT_CACHE), [
      'https://fonts.gstatic.com/s/notosanstc/subset-1.woff2',
    ]);
    assert.deepEqual(sw.cachedUrls(BUILD_CACHE), []);
  });

  test('字型主机排在 never-cache 的 gstatic.com 之前', async () => {
    // fonts.gstatic.com 也以 gstatic.com 结尾；顺序写反的话字型就完全不会被快取。
    const sw = loadServiceWorker();
    sw.seed(FONT_CACHE, 'https://fonts.gstatic.com/s/notosanstc/subset-1.woff2');

    assert.equal(
      await sw.request('https://fonts.gstatic.com/s/notosanstc/subset-1.woff2'),
      `cache:${FONT_CACHE}`,
    );
  });

  test('超过上限就从最旧的开始删，避免 iOS 把整个来源的快取清掉', async () => {
    const sw = loadServiceWorker();
    for (let i = 0; i < 70; i += 1) {
      await sw.request(`https://fonts.gstatic.com/s/notosanstc/subset-${i}.woff2`);
    }

    const cached = sw.cachedUrls(FONT_CACHE);
    assert.equal(cached.length, 64);
    assert.equal(cached.at(0), 'https://fonts.gstatic.com/s/notosanstc/subset-6.woff2');
    assert.equal(cached.at(-1), 'https://fonts.gstatic.com/s/notosanstc/subset-69.woff2');
  });
});

describe('安装与升级', () => {
  test('第一次安装直接 skipWaiting', async () => {
    const sw = loadServiceWorker({ hasActiveWorker: false });
    await sw.install();

    assert.equal(sw.skipWaitingCalls.length, 1);
  });

  test('升级时等页面说了才 skipWaiting，不把 bundle 从使用者脚下抽走', async () => {
    const sw = loadServiceWorker({ hasActiveWorker: true });
    await sw.install();
    assert.equal(sw.skipWaitingCalls.length, 0);

    sw.message({ type: 'SKIP_WAITING' });
    assert.equal(sw.skipWaitingCalls.length, 1);
  });

  test('不认得的讯息不会触发 skipWaiting', async () => {
    const sw = loadServiceWorker();
    sw.message({ type: 'SOMETHING_ELSE' });
    sw.message(undefined);

    assert.equal(sw.skipWaitingCalls.length, 0);
  });

  test('activate 砍掉旧 build 的快取，留下现用的三个', async () => {
    const sw = loadServiceWorker();
    sw.seed(BUILD_CACHE, `${ORIGIN}/main.dart.js`);
    sw.seed(VENDOR_CACHE, `${ORIGIN}/canvaskit/canvaskit.wasm`);
    sw.seed(FONT_CACHE, 'https://fonts.gstatic.com/s/notosanstc/subset-1.woff2');
    sw.seed('church-staff-pwa-deadbeef-1', `${ORIGIN}/main.dart.js`);
    sw.seed('church-staff-pwa-vendor-flutter-3.35.0', `${ORIGIN}/canvaskit/canvaskit.wasm`);
    sw.seed('some-other-app-cache', `${ORIGIN}/whatever`);

    await sw.activate();

    assert.deepEqual(sw.cacheNames().sort(), [
      BUILD_CACHE,
      FONT_CACHE,
      VENDOR_CACHE,
      'some-other-app-cache', // 不是我们的前缀，不碰
    ].sort());
    assert.equal(sw.claimCalls.length, 1);
  });
});
