import 'package:web/web.dart' as web;

const _key = 'church-app-reloaded-for';

/// 同一份清单在这个分页最多重载两次：一次是正常的换版，第二次留给「第一次
/// 重载后读到的还是旧资料」这种情况。再多就是出错了，宁可不重载。
const _maxReloadsPerReason = 2;

Future<bool> reloadAppOnce(String reason) async {
  try {
    final previous = web.window.sessionStorage.getItem(_key) ?? '';
    final separator = previous.indexOf('\n');
    final count = separator > 0 && previous.substring(separator + 1) == reason
        ? int.tryParse(previous.substring(0, separator)) ?? 0
        : 0;
    if (count >= _maxReloadsPerReason) return false;
    web.window.sessionStorage.setItem(_key, '${count + 1}\n$reason');
  } catch (_) {
    // 无痕模式读不到 sessionStorage：宁可不重载，下次开 App 就是新清单。
    return false;
  }
  web.window.location.reload();
  return true;
}
