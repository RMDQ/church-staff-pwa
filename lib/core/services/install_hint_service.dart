import 'install_hint_service_stub.dart'
    if (dart.library.js_interop) 'install_hint_service_web.dart'
    as impl;

/// 这支手机要怎么把网站加到主画面。
enum InstallPlatform { ios, android, other }

/// iPhone 上分享钮在哪里要看浏览器：Safari 在下方，Chrome 在网址列右边。
enum InstallBrowser { safari, chrome, other }

/// 首页「加到手机主画面」卡片需要知道的事，读自 `web/install_hint.js`。
class InstallHint {
  const InstallHint({
    required this.platform,
    required this.isStandalone,
    required this.canPrompt,
    this.browser = InstallBrowser.other,
  });

  final InstallPlatform platform;

  final InstallBrowser browser;

  /// 已经是从主画面开的（不是在浏览器分页里）。
  final bool isStandalone;

  /// Android Chrome 给了 beforeinstallprompt，可以直接跳出安装视窗。
  final bool canPrompt;

  /// 手机、还在浏览器里开：值得提醒一下。桌机不提醒，那里没有主画面。
  bool get shouldSuggest => platform != InstallPlatform.other && !isStandalone;
}

class InstallHintService {
  const InstallHintService();

  InstallHint read() => impl.readInstallHint();

  /// 跳出 Chrome 的安装视窗。回传 true 代表使用者按了安装。
  Future<bool> prompt() async => await impl.promptInstall() == 'accepted';
}
