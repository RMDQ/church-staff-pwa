'use strict';

// Service worker 注册与「换到新版」的交接流程。
//
// 为什么不写在 index.html 里（原本是）：这段程式码决定「这台装置能不能换到新
// 版」，一旦自己被旧快取服务，卡住的装置就再也救不回来。独立成档之后可以列进
// cache_sw.js 的 NETWORK_FIRST_PATHS，永远拿得到最新的一份；顺便也才测得到
// （web-tests/app_update.test.js）。
//
// 交接流程本身：新的 SW 装好之后会停在 waiting，要有人送 SKIP_WAITING 才会
// activate；activate 会触发 controllerchange，那时整页 reload 一次，使用者就
// 换到新的 bundle 了。
//
// 踩过的坑，每一条都对应底下一段程式码：
//
//   1. 只在 updatefound 里送 SKIP_WAITING 是不够的。新的 SW 若在「上一次造访」
//      就已经装好、停在 waiting（页面在交接完成前被关掉），这一次载入时
//      update() 抓到的档案跟等待中那颗一模一样，updatefound 不会再触发 ——
//      没有人送 SKIP_WAITING，旧 SW 就永远继续服务旧 bundle，重整几次都一样。
//      所以注册后要先看 registration.waiting。
//
//   2. statechange 可能已经错过。监听器是在 updatefound 之后才挂上去的，worker
//      若在那之前就到达 installed，那个事件就再也不会来。挂的同时也要检查一次
//      当下的 state。
//
//   3. PWA 从背景切回来不算一次 navigation，浏览器不会自己去检查 SW 有没有更
//      新。装在桌面的 App 可以好几天不重新载入 —— visibilitychange 时补一次
//      update()。

(function () {
  if (!('serviceWorker' in navigator)) {
    // 个人页的「检查更新」按钮靠这个函式存在与否决定显不显示。
    return;
  }

  // 第一次装 SW 时 controller 会从 null 变成新 SW，那也会触发 controllerchange。
  // 无条件 reload 的话，使用者第一次造访会看到「载入中」两次。只有已经有
  // controller 的「升级」情境才 reload。
  var hadInitialController = !!navigator.serviceWorker.controller;
  var reloading = false;

  navigator.serviceWorker.addEventListener('controllerchange', function () {
    if (!hadInitialController) {
      hadInitialController = true;
      return;
    }
    // controllerchange 在某些浏览器上会连续来两次，reload 两次会让画面闪两下。
    if (reloading) return;
    reloading = true;
    window.location.reload();
  });

  /// 有 worker 停在 waiting 就叫它让位。回传有没有真的送出讯息。
  function activateWaiting(registration) {
    if (!registration || !registration.waiting) return false;
    // 首次安装不必介入（会自然 activate），这里一定是升级：有 waiting 就代表
    // 已经有另一个 SW 在控制页面。
    registration.waiting.postMessage({ type: 'SKIP_WAITING' });
    return true;
  }

  /// 盯著正在安装的 worker，装好就叫它让位。
  function activateWhenInstalled(worker) {
    if (!worker) return;

    function maybeSkip() {
      if (worker.state === 'installed' && navigator.serviceWorker.controller) {
        worker.postMessage({ type: 'SKIP_WAITING' });
      }
    }

    worker.addEventListener('statechange', maybeSkip);
    // 挂上监听器之前就可能已经 installed 了 —— 那个 statechange 不会再来。
    maybeSkip();
  }

  function watch(registration) {
    activateWaiting(registration);
    activateWhenInstalled(registration.installing);
    registration.addEventListener('updatefound', function () {
      activateWhenInstalled(registration.installing);
    });
  }

  // 注册只做一次，之后所有人（visibilitychange、检查更新按钮）共用同一个
  // registration。
  var registrationPromise = null;

  function ensureRegistration() {
    if (!registrationPromise) {
      registrationPromise = navigator.serviceWorker
        .register('cache_sw.js')
        .then(function (registration) {
          watch(registration);
          return registration;
        })
        .catch(function (error) {
          console.error('Cache SW registration failed:', error);
          // 失败不要记下来，下次（例如按了检查更新）可以重试。
          registrationPromise = null;
          throw error;
        });
    }
    return registrationPromise;
  }

  /// 检查有没有新版，有就换过去（换完会 reload）。
  ///
  /// 回传 'updating'（找到新版，正在换）或 'latest'（已经是最新）。网路不通时
  /// reject，呼叫端要把错误说出来 —— 静静地回「已是最新」是骗人的。
  ///
  /// 个人页的「检查更新」按钮呼叫这个（见 AppUpdateService）。
  window.churchAppCheckForUpdate = function () {
    return ensureRegistration()
      .then(function (registration) {
        // 上一次留下来的 waiting，按钮按下去就该把它换上。
        if (activateWaiting(registration)) return 'updating';
        return registration.update().then(function () {
          if (activateWaiting(registration)) return 'updating';
          if (registration.installing) {
            activateWhenInstalled(registration.installing);
            return 'updating';
          }
          return 'latest';
        });
      });
  };

  window.addEventListener('load', function () {
    ensureRegistration().catch(function () {
      // ensureRegistration 已经印过了。
    });

    // Firebase Cloud Messaging 推播 SW 走自己的 scope，跟更新流程无关。
    navigator.serviceWorker
      .register('firebase-messaging-sw.js', {
        scope: 'firebase-cloud-messaging-push-scope',
      })
      .catch(function (error) {
        console.error('Firebase messaging SW registration failed:', error);
      });
  });

  // 切回前景时检查一次。装成 App 的 PWA 从多工列切回来不算 navigation，
  // 浏览器不会自己检查，可以好几天都停在旧版。
  document.addEventListener('visibilitychange', function () {
    if (document.visibilityState !== 'visible') return;
    ensureRegistration()
      .then(function (registration) {
        if (activateWaiting(registration)) return;
        return registration.update();
      })
      .catch(function () {
        // 离线时 update() 会失败，这是背景检查，不吵使用者。
      });
  });
})();
