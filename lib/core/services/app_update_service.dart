import 'app_update_service_stub.dart'
    if (dart.library.js_interop) 'app_update_service_web.dart'
    as impl;

/// 「检查更新」按下去之后发生了什么。
enum AppUpdateResult {
  /// 找到新版，正在换 —— 换完页面会自己重载，不必再提示什么。
  updating,

  /// 已经是最新的。
  latest,

  /// 这个环境没有 service worker（非 web，或浏览器不支援／被停用）。
  /// 按钮不该出现在这种环境。
  unsupported,
}

/// 手动触发「换到新版」。
///
/// 平常不需要它：`web/app_update.js` 会在载入与切回前景时自己检查。这个入口是
/// 给「我看起来还是旧版」的情况 —— 使用者想自己按一下，而不是被叫去把 App 从
/// 多工列滑掉。
///
/// 真正的交接流程在 `web/app_update.js`（那里有 SW 的 waiting／skipWaiting／
/// controllerchange 这些细节，也有测试）。这里只是把它接到 UI 上。
class AppUpdateService {
  const AppUpdateService();

  /// 这个环境有没有更新入口。没有就不要显示按钮。
  bool get isSupported => impl.isUpdateCheckSupported();

  /// 去问伺服器有没有新版；有就换过去（换完页面会重载）。
  ///
  /// 网路不通时往上丢例外 —— 静静回一句「已是最新版本」是骗人的，而这个按钮
  /// 存在的理由正是使用者已经不相信画面上的版本了。
  Future<AppUpdateResult> checkForUpdate() async {
    switch (await impl.checkForUpdate()) {
      case 'updating':
        return AppUpdateResult.updating;
      case 'latest':
        return AppUpdateResult.latest;
      default:
        return AppUpdateResult.unsupported;
    }
  }
}
