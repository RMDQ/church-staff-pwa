import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

class AppVersionInfo {
  const AppVersionInfo({required this.generatedAt, this.release, this.channel});

  final DateTime generatedAt;

  /// release.json 的版本号，例如 2026.9.1。只有安装精灵 build 的网站才有。
  final String? release;

  /// 'installer'：这个网站是安装精灵装的，只能靠精灵更新，不会跟著 Git 自动
  /// 部署。管理员才需要被告知有新版本（见 ReleaseCheckService）。
  final String? channel;

  bool get isInstallerSite => channel == 'installer';
}

class AppVersionService {
  const AppVersionService();

  /// 个人页「更新于」要回答的是「我手上这个 App 是哪一版」，不是「伺服器现在
  /// 是哪一版」——后者对使用者没有意义，而且会在「旧 bundle ＋ 新伺服器」时
  /// 显示成已更新。
  ///
  /// 所以这里刻意不加 `?t=` 也不送 `cache-control: no-cache`：`version.json`
  /// 跟著 bundle 一起进 service worker 那个以 build SHA 为名的快取
  /// （`web/cache_sw.js` 走 cache-first），拿到的就是正在跑的那一版。加了
  /// cache-bust 等于绕过快取去问伺服器，那行字就又变回伺服器的版本。
  Future<AppVersionInfo?> fetchVersionInfo() async {
    final candidates = [
      Uri.base.resolve('version.json'),
      Uri.base.resolve('/version.json'),
    ];

    for (final uri in candidates) {
      try {
        final response = await http.get(uri);
        if (response.statusCode != 200) {
          continue;
        }

        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final generatedAtRaw = data['generated_at'];
        DateTime? generatedAt;
        if (generatedAtRaw is String && generatedAtRaw.isNotEmpty) {
          generatedAt = DateTime.tryParse(generatedAtRaw);
        }

        generatedAt ??= _parseLastModified(response);
        if (generatedAt == null) continue;

        return AppVersionInfo(
          generatedAt: generatedAt.toLocal(),
          release: data['release'] is String ? data['release'] as String : null,
          channel: data['channel'] is String ? data['channel'] as String : null,
        );
      } catch (_) {
        continue;
      }
    }

    return null;
  }

  DateTime? _parseLastModified(http.Response response) {
    final value = response.headers['last-modified'];
    if (value == null || value.isEmpty) return null;
    try {
      return DateFormat(
        "EEE, dd MMM yyyy HH:mm:ss 'GMT'",
        'en_US',
      ).parseUtc(value);
    } catch (_) {
      return null;
    }
  }
}
