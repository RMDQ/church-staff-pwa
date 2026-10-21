import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { describe, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const SOURCE = readFileSync(path.join(ROOT, 'web', 'install_hint.js'), 'utf8');

const UA = {
  lineIos: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Safari Line/14.10.0',
  lineAndroid: 'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0 Mobile Safari/537.36 Line/14.10.0',
  facebookIos: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 [FBAN/FBIOS;FBAV/480.0]',
  safari: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1',
  chromeAndroid: 'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0 Mobile Safari/537.36',
  ipadDesktopMode: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15',
};

/// 一个只够 install_hint.js 用的 DOM：记下被加到 body 的元素，
/// querySelector 依 innerHTML 里有没有那个 data-action 回传假元素。
function fakeElement(tag) {
  const listeners = {};
  const children = {};
  return {
    tag, id: '', innerHTML: '', textContent: '', href: '', attributes: {}, removed: false, listeners,
    setAttribute(name, value) { this.attributes[name] = value; },
    addEventListener(type, handler) { listeners[type] = handler; },
    remove() { this.removed = true; },
    querySelector(selector) {
      const action = selector.match(/data-action="([a-z]+)"/)?.[1];
      if (action && !this.innerHTML.includes(`data-action="${action}"`)) return null;
      children[selector] ??= fakeElement('child');
      return children[selector];
    },
  };
}

function load({ ua, href = 'https://staff.example.test/', standalone = false, maxTouchPoints = 0, dismissed = false } = {}) {
  const windowListeners = {};
  const appended = [];
  const replaced = [];
  const storage = new Map(dismissed ? [['church-in-app-browser-dismissed', '1']] : []);
  const document = {
    head: { appendChild: () => {} },
    body: { appendChild: (element) => appended.push(element) },
    createElement: fakeElement,
    addEventListener: () => {},
  };
  const window = {
    location: { href, replace: (next) => replaced.push(next) },
    navigator: { standalone },
    matchMedia: () => ({ matches: standalone }),
    addEventListener: (type, handler) => { windowListeners[type] = handler; },
    prompt: () => {},
  };
  const context = {
    window, document, URL, Promise,
    navigator: { userAgent: ua, maxTouchPoints, clipboard: { writeText: async () => {} } },
    sessionStorage: { getItem: (key) => storage.get(key) ?? null, setItem: (key, value) => storage.set(key, value) },
  };
  vm.createContext(context);
  vm.runInContext(SOURCE, context);
  return { hint: window.churchInstallHint, windowListeners, appended, replaced, storage };
}

describe('LINE 等 App 内建浏览器', () => {
  test('LINE 里没有带参数：补上 openExternalBrowser=1 重新开启，不显示说明', () => {
    const page = load({ ua: UA.lineIos, href: 'https://staff.example.test/?x=1' });
    assert.deepEqual(page.replaced, ['https://staff.example.test/?x=1&openExternalBrowser=1']);
    assert.equal(page.appended.length, 0);
  });

  test('带了参数还在 LINE 里：LINE 没照做，改显示说明，不再重导', () => {
    const page = load({ ua: UA.lineAndroid, href: 'https://staff.example.test/?openExternalBrowser=1' });
    assert.deepEqual(page.replaced, []);
    assert.equal(page.appended.length, 1);
    const overlay = page.appended[0];
    assert.equal(overlay.id, 'in-app-browser');
    assert.match(overlay.innerHTML, /请改用 Chrome 开启/);
    // 要给同工复制的是干净网址，不是带著 LINE 参数的那个。
    assert.equal(overlay.querySelector('code').textContent, 'https://staff.example.test/');
    assert.equal(overlay.querySelector('[data-action="chrome"]').href,
      'intent://staff.example.test/#Intent;scheme=https;package=com.android.chrome;end');
  });

  test('Facebook 在 iPhone：说明改用 Safari，没有 Android 的 Chrome 按钮', () => {
    const page = load({ ua: UA.facebookIos });
    assert.deepEqual(page.replaced, []);
    const overlay = page.appended[0];
    assert.match(overlay.innerHTML, /请改用 Safari 开启/);
    assert.match(overlay.innerHTML, /Facebook/);
    assert.equal(overlay.querySelector('[data-action="chrome"]'), null);
  });

  test('按「先在这里使用」后，这次工作阶段不再挡', () => {
    const page = load({ ua: UA.facebookIos });
    page.appended[0].querySelector('[data-action="stay"]').listeners.click();
    assert.equal(page.appended[0].removed, true);
    assert.equal(page.storage.get('church-in-app-browser-dismissed'), '1');
    assert.equal(load({ ua: UA.facebookIos, dismissed: true }).appended.length, 0);
  });

  test('一般的 Safari、Chrome 什么都不做', () => {
    for (const ua of [UA.safari, UA.chromeAndroid]) {
      const page = load({ ua });
      assert.deepEqual(page.replaced, []);
      assert.equal(page.appended.length, 0);
    }
  });
});

describe('加到主画面', () => {
  test('平台判断：iPadOS 自称 Macintosh 也算 iOS', () => {
    assert.equal(load({ ua: UA.safari }).hint.platform(), 'ios');
    assert.equal(load({ ua: UA.ipadDesktopMode, maxTouchPoints: 5 }).hint.platform(), 'ios');
    assert.equal(load({ ua: UA.ipadDesktopMode }).hint.platform(), 'other');
    assert.equal(load({ ua: UA.chromeAndroid }).hint.platform(), 'android');
  });

  test('iPhone 上分得出 Safari 和 Chrome', () => {
    assert.equal(load({ ua: UA.safari }).hint.browser(), 'safari');
    assert.equal(load({ ua: UA.safari.replace('Version/18.0', 'CriOS/129.0') }).hint.browser(), 'chrome');
  });

  test('已经从主画面开启：isStandalone 为真', () => {
    assert.equal(load({ ua: UA.safari, standalone: true }).hint.isStandalone(), true);
    assert.equal(load({ ua: UA.safari }).hint.isStandalone(), false);
  });

  test('先接住 beforeinstallprompt，按下安装时才跳，而且只能用一次', async () => {
    const page = load({ ua: UA.chromeAndroid });
    assert.equal(page.hint.canPrompt(), false);
    assert.equal(await page.hint.prompt(), 'unavailable');

    let prevented = false;
    let prompted = 0;
    page.windowListeners.beforeinstallprompt({
      preventDefault: () => { prevented = true; },
      prompt: async () => { prompted += 1; },
      userChoice: Promise.resolve({ outcome: 'accepted' }),
    });
    assert.equal(prevented, true, 'Chrome 自己的迷你横幅要挡掉');
    assert.equal(page.hint.canPrompt(), true);
    assert.equal(await page.hint.prompt(), 'accepted');
    assert.equal(prompted, 1);
    assert.equal(page.hint.canPrompt(), false);
  });

  test('装好之后（appinstalled）就不再提供安装', () => {
    const page = load({ ua: UA.chromeAndroid });
    page.windowListeners.beforeinstallprompt({ preventDefault() {}, prompt: async () => {}, userChoice: Promise.resolve({}) });
    page.windowListeners.appinstalled();
    assert.equal(page.hint.canPrompt(), false);
  });
});
