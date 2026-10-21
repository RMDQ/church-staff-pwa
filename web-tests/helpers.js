// Runs the real web/cache_sw.js inside a vm with the Service Worker globals
// stubbed, so the tests exercise the file that actually ships instead of a
// re-implementation of its rules.
//
// Everything a service worker touches is faked here — `self`, `caches`,
// `fetch`, `clients` — because Node has none of them. The stubs are the
// smallest thing the file will run against: caches are plain Maps keyed by
// URL, and every response carries a `source` tag so a test can tell whether
// the bytes came from the network or from a specific cache.

import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

export const ORIGIN = 'https://app.example.test';

// CI substitutes these placeholders (see the deploy workflow); the checked-in
// file keeps them literal, so that is what the cache names look like here.
export const BUILD_CACHE = 'church-staff-pwa-__BUILD_VERSION__';
export const VENDOR_CACHE = 'church-staff-pwa-vendor-__VENDOR_VERSION__';
export const FONT_CACHE = 'church-staff-pwa-fonts-v1';

/// A response the fetch handler can return. `source` is the assertion target:
/// 'network', or `cache:<name>` for one that was seeded into a cache.
function stubResponse(source, url, { ok = true } = {}) {
  return {
    ok,
    url,
    source,
    // Real Response bodies can only be read once, so the SW clones before
    // caching. Returning `this` is enough for tests that only read the tag.
    clone() {
      return this;
    },
  };
}

/// Loads web/cache_sw.js and returns handles to drive it.
///
/// [hasActiveWorker] mirrors `self.registration.active`: false is a first
/// install (nothing is controlling the page yet), true is an upgrade.
export function loadServiceWorker({ hasActiveWorker = true } = {}) {
  const source = readFileSync(path.join(ROOT, 'web', 'cache_sw.js'), 'utf8');

  const listeners = {};
  const stores = new Map(); // cache name -> Map(url -> response)
  const skipWaitingCalls = [];
  const claimCalls = [];

  function store(name) {
    if (!stores.has(name)) stores.set(name, new Map());
    return stores.get(name);
  }

  function openCache(name) {
    const entries = store(name);
    return {
      match: async (request) => entries.get(request.url),
      put: async (request, response) => void entries.set(request.url, response),
      // Insertion order, like the real Cache — trimFontCache relies on it to
      // evict the oldest entries first.
      keys: async () => [...entries.keys()].map((url) => ({ url })),
      delete: async (request) => entries.delete(request.url),
    };
  }

  // Swappable so a test can make the network fail (offline) or count calls.
  let fetchImpl = async (request) => stubResponse('network', request.url);

  const context = {
    self: {
      addEventListener: (type, handler) => void (listeners[type] = handler),
      location: { origin: ORIGIN },
      registration: { active: hasActiveWorker ? {} : null },
      skipWaiting: () => void skipWaitingCalls.push(true),
      clients: { claim: async () => void claimCalls.push(true) },
    },
    caches: {
      open: async (name) => openCache(name),
      keys: async () => [...stores.keys()],
      delete: async (name) => stores.delete(name),
    },
    fetch: (request) => fetchImpl(request),
    URL,
    Set,
    Promise,
    console,
  };

  vm.createContext(context);
  vm.runInContext(source, context);

  /// Fires the fetch handler and resolves to the response's `source` tag, or
  /// 'passthrough' when the handler declined to call respondWith (the request
  /// goes to the network unmanaged).
  ///
  /// Also awaits every waitUntil promise, so cache writes have landed by the
  /// time the caller inspects a cache.
  async function request(url, { method = 'GET' } = {}) {
    const pending = [];
    let responded;
    listeners.fetch({
      request: { method, url },
      respondWith: (promise) => void (responded = promise),
      waitUntil: (promise) => void pending.push(promise),
    });
    if (responded === undefined) {
      await Promise.all(pending);
      return 'passthrough';
    }
    try {
      const response = await responded;
      return response.source;
    } finally {
      await Promise.all(pending);
    }
  }

  return {
    listeners,
    request,
    /// Puts a response into a cache as if an earlier visit had cached it.
    seed(cacheName, url, { ok = true } = {}) {
      store(cacheName).set(url, stubResponse(`cache:${cacheName}`, url, { ok }));
    },
    cacheNames: () => [...stores.keys()],
    cachedUrls: (cacheName) => [...store(cacheName).keys()],
    setFetch(impl) {
      fetchImpl = impl;
    },
    skipWaitingCalls,
    claimCalls,
    async install() {
      const pending = [];
      listeners.install({ waitUntil: (promise) => void pending.push(promise) });
      await Promise.all(pending);
    },
    async activate() {
      const pending = [];
      listeners.activate({ waitUntil: (promise) => void pending.push(promise) });
      await Promise.all(pending);
    },
    message(data) {
      listeners.message({ data });
    },
  };
}

// ---------------------------------------------------------------------------
// web/app_update.js —— SW 注册与换版交接。
//
// 同样在 vm 里跑真正的档案，把 navigator.serviceWorker / window / document 换
// 成可以驱动的假物件：测试要能制造「有 worker 停在 waiting」「statechange 早
// 于监听器」这类时序，真的浏览器里等不出来。
// ---------------------------------------------------------------------------

/// 一个假的 ServiceWorker。`posted` 收到的就是 SKIP_WAITING 那类讯息。
export function fakeWorker(state = 'installing') {
  const listeners = [];
  return {
    state,
    posted: [],
    postMessage(message) {
      this.posted.push(message);
    },
    addEventListener(type, handler) {
      if (type === 'statechange') listeners.push(handler);
    },
    /// 推进状态并发出 statechange，跟浏览器一样。
    advanceTo(next) {
      this.state = next;
      for (const handler of [...listeners]) handler();
    },
  };
}

/// 一个假的 ServiceWorkerRegistration。
export function fakeRegistration({ waiting = null, installing = null } = {}) {
  const listeners = [];
  return {
    waiting,
    installing,
    updateCalls: 0,
    /// 让 update() 在被呼叫时做点事（例如放一颗 waiting 进来、或丢错）。
    onUpdate: null,
    addEventListener(type, handler) {
      if (type === 'updatefound') listeners.push(handler);
    },
    async update() {
      this.updateCalls += 1;
      if (this.onUpdate) await this.onUpdate(this);
    },
    /// 浏览器找到新版本时会做的事：摆上 installing 再发 updatefound。
    fireUpdateFound(worker) {
      this.installing = worker;
      for (const handler of [...listeners]) handler();
    },
  };
}

/// 载入 web/app_update.js。
///
/// [hasController] 对应 `navigator.serviceWorker.controller`：false 是第一次
/// 安装（不该介入，也不该 reload），true 是升级。
export function loadAppUpdate({
  hasController = true,
  registration = fakeRegistration(),
  registerError = null,
  noServiceWorker = false,
} = {}) {
  const source = readFileSync(path.join(ROOT, 'web', 'app_update.js'), 'utf8');

  const containerListeners = {};
  const windowListeners = {};
  const documentListeners = {};
  const registerCalls = [];
  const reloads = [];

  const document = {
    visibilityState: 'visible',
    addEventListener: (type, handler) => void (documentListeners[type] = handler),
  };

  const serviceWorker = {
    controller: hasController ? {} : null,
    addEventListener: (type, handler) => void (containerListeners[type] = handler),
    register: async (url, options) => {
      registerCalls.push({ url, options });
      if (url === 'cache_sw.js' && registerError) throw registerError;
      return registration;
    },
  };

  // 旧浏览器（或关掉 SW 的环境）：整段程式码要安静地什么都不做。
  const navigator = noServiceWorker ? {} : { serviceWorker };

  const context = {
    navigator,
    document,
    window: {
      addEventListener: (type, handler) => void (windowListeners[type] = handler),
      location: { reload: () => void reloads.push(true) },
    },
    console: { error: () => {} },
    Promise,
  };
  context.self = context;
  context.globalThis = context;

  vm.createContext(context);
  vm.runInContext(source, context);

  return {
    registration,
    registerCalls,
    reloads,
    /// 浏览器发出 load，也就是注册真正发生的时候。
    async load() {
      windowListeners.load?.();
      await flush();
    },
    async controllerChange() {
      containerListeners.controllerchange?.();
      await flush();
    },
    async visibilityChange(state = 'visible') {
      document.visibilityState = state;
      documentListeners.visibilitychange?.();
      await flush();
    },
    /// 个人页「检查更新」按钮呼叫的那个函式。
    checkForUpdate: () => context.window.churchAppCheckForUpdate(),
    hasCheckForUpdate: () => typeof context.window.churchAppCheckForUpdate === 'function',
  };
}

/// 让已经排进 queue 的 then/await 跑完。跑几轮是因为注册流程是好几层
/// promise 串起来的，只让一轮会停在半路。
export async function flush(rounds = 5) {
  for (let i = 0; i < rounds; i += 1) {
    await new Promise((resolve) => setImmediate(resolve));
  }
}
