'use strict';

// 让同工把网站「加到主画面」，以及把他们从 LINE 这类 App 内建浏览器带出去。
//
// 为什么在 Flutter 之前跑、而且是独立档案：
//
//   1. 台湾教会的网址多半贴在 LINE 群组。LINE、Facebook、Instagram 点开连结
//      用的是自己的 in-app browser：不能加到主画面、关掉就登出、收不到推播。
//      同工不会知道差别，只会觉得「这个 App 很难用」。这件事要在 Flutter 那
//      几 MB 载完之前就讲，不然他们已经在里面登入了。
//   2. `beforeinstallprompt` 只发一次，而且很早。等 Flutter 起来再挂监听器
//      就错过了，所以这里先接住、存起来，给首页那张「加到主画面」卡片用。
//
// Flutter 那侧读的是 window.churchInstallHint（见
// lib/core/services/install_hint_service_web.dart）。

(function () {
  var ua = navigator.userAgent || '';

  function detectInAppBrowser() {
    if (/ Line\//i.test(ua)) return 'LINE';
    if (/FBAN|FBAV|FB_IAB|FBIOS/i.test(ua)) return 'Facebook';
    if (/Instagram/i.test(ua)) return 'Instagram';
    if (/MicroMessenger/i.test(ua)) return '微信';
    return null;
  }

  function detectPlatform() {
    if (/iPhone|iPad|iPod/i.test(ua)) return 'ios';
    // iPadOS 13+ 的 Safari 预设自称 Macintosh；多点触控才分得出来。
    if (/Macintosh/i.test(ua) && navigator.maxTouchPoints > 1) return 'ios';
    if (/Android/i.test(ua)) return 'android';
    return 'other';
  }

  // iPhone 上每个浏览器的分享钮位置不同：Safari 在下方（或收在「⋯」里），
  // Chrome 在网址列右边。Android 一律照 Chrome 教。
  function detectBrowser() {
    if (/CriOS/i.test(ua)) return 'chrome';
    if (/FxiOS|EdgiOS|OPiOS/i.test(ua)) return 'other';
    if (/Safari/i.test(ua)) return 'safari';
    return 'other';
  }

  function isStandalone() {
    return (window.matchMedia && window.matchMedia('(display-mode: standalone)').matches) ||
      window.navigator.standalone === true;
  }

  var platform = detectPlatform();
  var browser = detectBrowser();
  var inAppBrowser = detectInAppBrowser();
  var deferredPrompt = null;

  window.addEventListener('beforeinstallprompt', function (event) {
    // 不让 Chrome 自己跳迷你横幅：时机由首页卡片的「安装」按钮决定。
    event.preventDefault();
    deferredPrompt = event;
  });
  window.addEventListener('appinstalled', function () {
    deferredPrompt = null;
  });

  window.churchInstallHint = {
    platform: function () { return platform; },
    browser: function () { return browser; },
    isStandalone: isStandalone,
    canPrompt: function () { return deferredPrompt !== null; },
    /// 回传 'accepted'、'dismissed' 或 'unavailable'。
    prompt: function () {
      var event = deferredPrompt;
      if (!event) return Promise.resolve('unavailable');
      deferredPrompt = null; // 一个事件只能 prompt() 一次。
      return event.prompt().then(function () { return event.userChoice; })
        .then(function (choice) { return choice && choice.outcome === 'accepted' ? 'accepted' : 'dismissed'; })
        .catch(function () { return 'unavailable'; });
    },
  };

  if (!inAppBrowser || isStandalone()) return;

  var url = new URL(window.location.href);

  // LINE 看到这个参数就会改用手机的预设浏览器开启。分享出去的连结多半已经
  // 带了；没带的话这里补一次。参数已经在、却还是在 LINE 里，代表 LINE 没有
  // 照做（旧版或设定关掉），就改成显示说明，不再重导，免得无限循环。
  if (inAppBrowser === 'LINE' && url.searchParams.get('openExternalBrowser') !== '1') {
    url.searchParams.set('openExternalBrowser', '1');
    window.location.replace(url.href);
    return;
  }

  var DISMISS_KEY = 'church-in-app-browser-dismissed';
  try {
    if (sessionStorage.getItem(DISMISS_KEY) === '1') return;
  } catch (_) { /* 无痕模式读不到就照常显示。 */ }

  url.searchParams.delete('openExternalBrowser');
  var cleanUrl = url.href;
  var target = platform === 'ios' ? 'Safari' : 'Chrome';

  function show() {
    var style = document.createElement('style');
    style.textContent =
      '#in-app-browser{position:fixed;inset:0;z-index:10000;background:#fff;color:#1f2937;display:flex;align-items:center;justify-content:center;padding:24px;' +
      'font-family:"Noto Sans TC","PingFang TC","Microsoft JhengHei",sans-serif;line-height:1.7}' +
      '#in-app-browser .card{max-width:420px;width:100%}' +
      '#in-app-browser h1{font-size:22px;margin:0 0 12px}' +
      '#in-app-browser p{margin:0 0 12px;font-size:16px}' +
      '#in-app-browser ol{margin:0 0 16px;padding-left:22px;font-size:16px}' +
      '#in-app-browser button,#in-app-browser a.button{display:block;width:100%;box-sizing:border-box;margin:10px 0 0;padding:12px;border-radius:10px;font:inherit;font-size:16px;' +
      'text-align:center;text-decoration:none;border:1px solid #2563eb;background:#2563eb;color:#fff;cursor:pointer}' +
      '#in-app-browser .secondary{background:#fff;color:#2563eb}' +
      '#in-app-browser .quiet{border-color:transparent;background:transparent;color:#6b7280}' +
      '#in-app-browser code{word-break:break-all;background:#f3f4f6;padding:2px 6px;border-radius:6px;font-size:14px}';
    document.head.appendChild(style);

    var overlay = document.createElement('div');
    overlay.id = 'in-app-browser';
    overlay.setAttribute('role', 'dialog');
    overlay.setAttribute('aria-modal', 'true');
    overlay.innerHTML =
      '<div class="card">' +
      '<h1>请改用 ' + target + ' 开启</h1>' +
      '<p>你现在是在 ' + inAppBrowser + ' 里面开启。在这里没办法加到手机主画面，关掉之后也常常要重新登入。</p>' +
      '<ol>' +
      (platform === 'ios'
        ? '<li>按右下角或右上角的「⋯」或分享图示</li><li>选「在 Safari 中开启」</li>'
        : '<li>按右上角的「⋮」</li><li>选「在浏览器中开启」或「用 Chrome 开启」</li>') +
      '</ol>' +
      '<p>找不到的话，复制下面的网址，贴到 ' + target + ' 的网址列：<br><code></code></p>' +
      (platform === 'android' ? '<a class="button" data-action="chrome">直接用 Chrome 开启</a>' : '') +
      '<button type="button" class="secondary" data-action="copy">复制网址</button>' +
      '<button type="button" class="quiet" data-action="stay">先在这里使用</button>' +
      '</div>';
    overlay.querySelector('code').textContent = cleanUrl;

    var chrome = overlay.querySelector('[data-action="chrome"]');
    if (chrome) {
      // Android 的 intent URL：大多数 App 内建浏览器会把它交给 Chrome。
      chrome.href = 'intent://' + cleanUrl.replace(/^https?:\/\//, '') +
        '#Intent;scheme=https;package=com.android.chrome;end';
    }
    overlay.querySelector('[data-action="copy"]').addEventListener('click', function (event) {
      var button = event.currentTarget;
      var done = function () { button.textContent = '已复制，请贴到 ' + target; };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(cleanUrl).then(done, function () { window.prompt('请复制这个网址', cleanUrl); });
      } else {
        window.prompt('请复制这个网址', cleanUrl);
      }
    });
    overlay.querySelector('[data-action="stay"]').addEventListener('click', function () {
      try { sessionStorage.setItem(DISMISS_KEY, '1'); } catch (_) { /* 只影响这次。 */ }
      overlay.remove();
    });
    document.body.appendChild(overlay);
  }

  if (document.body) show();
  else document.addEventListener('DOMContentLoaded', show);
})();
