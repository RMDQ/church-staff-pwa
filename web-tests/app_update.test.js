import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import { fakeRegistration, fakeWorker, loadAppUpdate } from './helpers.js';

/// vm 里建立的物件跟这里不同 realm，deepEqual 会因为 prototype 不同而失败，
/// 所以只比讯息型别。
const types = (worker) => worker.posted.map((message) => message.type);

describe('换到新版的交接', () => {
  // 这是「重整了还是旧版」的成因。新的 SW 在上一次造访就装好、停在 waiting，
  // 这一次载入时 update() 抓到的档案跟它一模一样，updatefound 不会再触发 ——
  // 旧的流程只在那个事件里送 SKIP_WAITING，于是没有人送，旧 SW 继续服务旧
  // bundle，重整几次都一样。
  test('上一次留下来停在 waiting 的 worker，这次载入就叫它让位', async () => {
    const waiting = fakeWorker('installed');
    const sw = loadAppUpdate({ registration: fakeRegistration({ waiting }) });

    await sw.load();

    assert.deepEqual(types(waiting), ['SKIP_WAITING']);
  });

  test('worker 在监听器挂上之前就 installed 也抓得到', async () => {
    // statechange 已经发生过就不会再来一次，只靠监听器会漏掉。
    const installing = fakeWorker('installed');
    const sw = loadAppUpdate({ registration: fakeRegistration({ installing }) });

    await sw.load();

    assert.deepEqual(types(installing), ['SKIP_WAITING']);
  });

  test('之后才装好的 worker，statechange 时让位', async () => {
    const registration = fakeRegistration();
    const sw = loadAppUpdate({ registration });
    await sw.load();

    const worker = fakeWorker('installing');
    registration.fireUpdateFound(worker);
    assert.deepEqual(types(worker), [], '还在装就先不要动');

    worker.advanceTo('installed');
    assert.deepEqual(types(worker), ['SKIP_WAITING']);
  });

  test('第一次安装不介入：没有东西要接手', async () => {
    const installing = fakeWorker('installed');
    const sw = loadAppUpdate({
      hasController: false,
      registration: fakeRegistration({ installing }),
    });

    await sw.load();

    assert.deepEqual(types(installing), []);
  });

  test('接手完成（controllerchange）才 reload，而且只 reload 一次', async () => {
    const sw = loadAppUpdate();
    await sw.load();

    await sw.controllerChange();
    await sw.controllerChange();

    assert.equal(sw.reloads.length, 1);
  });

  test('第一次安装的 controllerchange 不 reload', async () => {
    // 那会让第一次造访的人看到「载入中」两次。
    const sw = loadAppUpdate({ hasController: false });
    await sw.load();

    await sw.controllerChange();

    assert.equal(sw.reloads.length, 0);
  });
});

describe('切回前景时检查', () => {
  // 装成 App 的 PWA 从多工列切回来不算 navigation，浏览器不会自己检查有没有
  // 新版 —— 可以好几天都停在旧版。
  test('切回前景会检查一次', async () => {
    const registration = fakeRegistration();
    const sw = loadAppUpdate({ registration });
    await sw.load();
    const before = registration.updateCalls;

    await sw.visibilityChange('visible');

    assert.equal(registration.updateCalls, before + 1);
  });

  test('切到背景不检查', async () => {
    const registration = fakeRegistration();
    const sw = loadAppUpdate({ registration });
    await sw.load();
    const before = registration.updateCalls;

    await sw.visibilityChange('hidden');

    assert.equal(registration.updateCalls, before);
  });

  test('已经有 waiting 就直接让位，不必再问伺服器', async () => {
    const waiting = fakeWorker('installed');
    const registration = fakeRegistration();
    const sw = loadAppUpdate({ registration });
    await sw.load();
    registration.waiting = waiting;
    const before = registration.updateCalls;

    await sw.visibilityChange('visible');

    assert.deepEqual(types(waiting), ['SKIP_WAITING']);
    assert.equal(registration.updateCalls, before);
  });

  test('离线时的背景检查不会炸掉页面', async () => {
    const registration = fakeRegistration();
    registration.onUpdate = () => {
      throw new Error('offline');
    };
    const sw = loadAppUpdate({ registration });
    await sw.load();

    await sw.visibilityChange('visible');

    assert.equal(registration.updateCalls, 1);
  });
});

describe('个人页的「检查更新」', () => {
  test('没有新版就回 latest', async () => {
    const registration = fakeRegistration();
    const sw = loadAppUpdate({ registration });
    await sw.load();

    assert.equal(await sw.checkForUpdate(), 'latest');
    assert.ok(registration.updateCalls >= 1, '要真的去问过伺服器');
  });

  test('问到新版就换过去', async () => {
    const registration = fakeRegistration();
    const waiting = fakeWorker('installed');
    registration.onUpdate = (reg) => {
      reg.waiting = waiting;
    };
    const sw = loadAppUpdate({ registration });
    await sw.load();

    assert.equal(await sw.checkForUpdate(), 'updating');
    assert.deepEqual(types(waiting), ['SKIP_WAITING']);
  });

  test('还在装的时候按下去，也算正在更新', async () => {
    const registration = fakeRegistration();
    const installing = fakeWorker('installing');
    registration.onUpdate = (reg) => {
      reg.installing = installing;
    };
    const sw = loadAppUpdate({ registration });
    await sw.load();

    assert.equal(await sw.checkForUpdate(), 'updating');
    installing.advanceTo('installed');
    assert.deepEqual(types(installing), ['SKIP_WAITING'], '装好之后接著让位');
  });

  test('已经有 waiting 时直接换，不必等伺服器回答', async () => {
    const waiting = fakeWorker('installed');
    const registration = fakeRegistration();
    const sw = loadAppUpdate({ registration });
    await sw.load();
    registration.waiting = waiting;
    const before = registration.updateCalls;

    assert.equal(await sw.checkForUpdate(), 'updating');
    assert.equal(registration.updateCalls, before);
  });

  test('离线时往上丢，不能静静回「已是最新」', async () => {
    const registration = fakeRegistration();
    registration.onUpdate = () => {
      throw new Error('offline');
    };
    const sw = loadAppUpdate({ registration });
    await sw.load();

    await assert.rejects(() => sw.checkForUpdate(), /offline/);
  });

  test('注册失败会往上丢', async () => {
    const sw = loadAppUpdate({ registerError: new Error('SW blocked') });
    await sw.load();

    await assert.rejects(() => sw.checkForUpdate(), /SW blocked/);
  });
});

describe('注册', () => {
  test('load 时注册快取 SW 与推播 SW', async () => {
    const sw = loadAppUpdate();

    await sw.load();

    assert.deepEqual(
      sw.registerCalls.map((call) => call.url),
      ['cache_sw.js', 'firebase-messaging-sw.js'],
    );
    assert.equal(
      sw.registerCalls[1].options.scope,
      'firebase-cloud-messaging-push-scope',
    );
  });

  test('只注册一次，按几次检查更新都共用同一个 registration', async () => {
    const sw = loadAppUpdate();
    await sw.load();

    await sw.checkForUpdate();
    await sw.checkForUpdate();

    const cacheSwRegistrations = sw.registerCalls.filter(
      (call) => call.url === 'cache_sw.js',
    );
    assert.equal(cacheSwRegistrations.length, 1);
  });

  test('没有 serviceWorker 的浏览器不会挂上检查更新的入口', async () => {
    // 个人页靠这个函式在不在决定要不要显示按钮。
    const sw = loadAppUpdate({ noServiceWorker: true });

    assert.equal(sw.hasCheckForUpdate(), false);
  });
});
