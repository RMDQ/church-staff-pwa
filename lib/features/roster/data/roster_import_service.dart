import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import 'package:church_staff_pwa/core/config/church_config.dart';
import 'package:church_staff_pwa/core/types/service_type.dart';
import 'roster_photo.dart';

/// 使用者看得懂的失败。讯息已经是中文（多半是 API 自己写的），呼叫端直接显示。
class RosterImportException implements Exception {
  final String message;
  const RosterImportException(this.message);

  @override
  String toString() => message;
}

typedef IdTokenProvider = Future<String?> Function();

/// 把服事表照片送去辨识，拿回可以贴进汇入框的 JSON。
///
/// 回传的是**字串**而不是解析好的物件，而且刻意填回原本那个文字框：辨识完
/// 的结果要让人看一眼再按汇入，而按下汇入之后走的还是
/// `parseRosterImportJson` —— 跟手动贴上完全同一条路。辨识只是省掉打字，
/// 不是另一条汇入流程。
class RosterImportService {
  /// 一张密密麻麻的服事表模型要跑一阵子，而免费版忙碌时 worker 还会重试。
  /// worker 最晚在第 75 秒开始最后一次、那一次最多给 100 秒（见
  /// worker/gemini.js），这里要留得比 175 秒宽，否则使用者会先看到「逾时」，
  /// 而那边其实正要成功。
  ///
  /// 公开是因为汇入画面要倒数「最多再等几秒」，那个数字得跟这里同一个。
  static const Duration timeout = Duration(seconds: 190);

  /// 一次顺利的辨识大约 50–70 秒（见 worker/gemini.js）。超过这个时间还没回来，
  /// 多半是 Gemini 回了忙碌、worker 在重试 —— 画面用它决定要不要改口说「比平常久」。
  static const Duration usualDuration = Duration(seconds: 75);

  final http.Client _client;
  final IdTokenProvider _idToken;
  final Uri _endpoint;

  RosterImportService({
    http.Client? client,
    IdTokenProvider? idToken,
    Uri? endpoint,
  }) : _client = client ?? http.Client(),
       _idToken = idToken ?? _firebaseIdToken,
       _endpoint = endpoint ?? Uri.base.resolve('/api/roster/import-image');

  static Future<String?> _firebaseIdToken() =>
      FirebaseAuth.instance.currentUser?.getIdToken() ?? Future.value(null);

  /// 送出照片，回传排版过的 JSON 字串。
  Future<String> convert({
    required ServiceType type,
    required List<RosterPhoto> photos,
  }) async {
    if (!ChurchConfig.current.features.photoImport) {
      throw const RosterImportException('照片辨识未启用，请贴上 JSON 汇入');
    }
    if (photos.isEmpty) {
      throw const RosterImportException('请先选一张服事表照片');
    }

    final token = await _idToken();
    if (token == null || token.isEmpty) {
      throw const RosterImportException('请先登入');
    }

    final request = http.Request('POST', _endpoint)
      ..headers['Authorization'] = 'Bearer $token'
      ..headers['content-type'] = 'application/json; charset=utf-8'
      ..body = jsonEncode({
        'type': type.name,
        'images': [for (final photo in photos) photo.toJson()],
      });

    final http.Response response;
    try {
      final streamed = await _client.send(request).timeout(timeout);
      response = await http.Response.fromStream(streamed).timeout(timeout);
    } on TimeoutException {
      throw const RosterImportException('辨识逾时了。请把照片裁到只剩表格，或裁成上下两半分两次辨识');
    } catch (_) {
      throw const RosterImportException('连线失败，请检查网路后再试一次');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw RosterImportException(_errorMessage(response));
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      throw const RosterImportException('辨识完成，但回应看不懂，请再试一次');
    }
    final entries = (decoded is Map<String, dynamic>)
        ? decoded['entries']
        : null;
    if (entries is! List) {
      throw const RosterImportException('辨识完成，但回应看不懂，请再试一次');
    }
    if (entries.isEmpty) {
      throw const RosterImportException('这张照片没有读出任何日期，请确认拍到整张表');
    }

    // 排版过再填回文字框。挤成一行的话，使用者想确认哪天排了谁得先自己读
    // 一段 JSON —— 而「看一眼再汇入」正是保留这个文字框的理由。
    return '${const JsonEncoder.withIndent('  ').convert(entries)}\n';
  }

  /// 优先用 API 自己写的讯息；没有才退回依状态码猜。
  ///
  /// 没有讯息通常代表回应不是这支函式产生的（Cloudflare 挡下、旧的 service
  /// worker 接走），那时状态码是唯一的线索 —— 所以猜的讯息后面一律带上状态
  /// 码。实际踩过：Cloudflare 因为 CPU 超时回的 503，跟 Gemini 忙碌时 worker
  /// 回的 503 显示成同一句话，查了很久才分出是哪一层。
  String _errorMessage(http.Response response) {
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) {
        final message = decoded['error'];
        if (message is String && message.trim().isNotEmpty) {
          return message.trim();
        }
      }
    } catch (_) {
      // 落到下面依状态码给讯息。
    }
    final status = response.statusCode;
    final guess = switch (status) {
      401 => '请重新登入后再试一次',
      403 => '没有编辑服事表的权限',
      413 => '照片太大了，请先缩小再试',
      429 => '辨识用量已达上限，请稍后再试',
      >= 500 => '伺服器没有处理完，请稍后再试',
      _ => '辨识失败，请稍后再试',
    };
    return '$guess（$status）';
  }
}
