import 'dart:js_interop';

/// `web/app_update.js` 挂在 window 上的入口。回传 'updating' 或 'latest'，
/// 网路不通时 reject。
///
/// 浏览器没有 service worker 时那支脚本会提早结束、不挂这个函式，所以这里是
/// nullable —— 读到 undefined 就是 null。
@JS('churchAppCheckForUpdate')
external JSFunction? get _checkForUpdate;

bool isUpdateCheckSupported() => _checkForUpdate != null;

Future<String> checkForUpdate() async {
  final entryPoint = _checkForUpdate;
  if (entryPoint == null) return 'unsupported';

  final promise = entryPoint.callAsFunction() as JSPromise<JSString>;
  return (await promise.toDart).toDart;
}
