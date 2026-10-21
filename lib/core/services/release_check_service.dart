import 'dart:convert';

import 'package:http/http.dart' as http;

/// 安装精灵装的网站不会跟著 GitHub 自动更新，要教会自己用精灵更新。这里读
/// 上游 repo 的 release.json，让管理员知道有新版本、以及更新了什么。
///
/// 只有维护者改了 release.json 的版本号才算新版本 —— 只改文件或小修正的
/// commit 不会去吵教会。
const upstreamReleaseUrl =
    'https://raw.githubusercontent.com/hansli112/church-staff-pwa/main/release.json';

class ReleaseInfo {
  const ReleaseInfo({
    required this.version,
    required this.notes,
    required this.guideUrl,
  });

  final String version;
  final List<String> notes;
  final String? guideUrl;
}

class ReleaseCheckService {
  const ReleaseCheckService({this.url = upstreamReleaseUrl, this.client});

  final String url;

  /// 测试注入；正式环境用 http 套件预设的 client。
  final http.Client? client;

  /// 读不到（离线、GitHub 挂了、格式不对）就回 null：这是提醒，不是功能，
  /// 失败不该打扰管理员。
  Future<ReleaseInfo?> fetchLatest() async {
    try {
      final uri = Uri.parse(url);
      final response = await (client?.get(uri) ?? http.get(uri)).timeout(
        const Duration(seconds: 10),
      );
      if (response.statusCode != 200) return null;
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      if (data is! Map<String, dynamic>) return null;
      final version = data['version'];
      if (version is! String || _parse(version) == null) return null;
      final notes = data['notes'];
      final guideUrl = data['guideUrl'];
      return ReleaseInfo(
        version: version,
        notes: notes is List ? notes.whereType<String>().toList() : const [],
        guideUrl: guideUrl is String && guideUrl.startsWith('https://')
            ? guideUrl
            : null,
      );
    } catch (_) {
      return null;
    }
  }
}

/// [latest] 比 [current] 新吗？版本号是「年.月.序号」，逐段比数字 ——
/// 字串比较会把 2026.10.1 排在 2026.9.1 前面。[current] 读不到时不算有新版：
/// 那是旧版精灵装的，或根本不是精灵装的网站。
bool isNewerRelease(String latest, String? current) {
  final a = _parse(latest);
  final b = current == null ? null : _parse(current);
  if (a == null || b == null) return false;
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i] > b[i];
  }
  return false;
}

List<int>? _parse(String version) {
  final match = RegExp(r'^(\d{4})\.(\d{1,2})\.(\d{1,3})$').firstMatch(version);
  if (match == null) return null;
  return [for (var i = 1; i <= 3; i++) int.parse(match.group(i)!)];
}
