import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import '../domain/checkin_models.dart';

typedef IdTokenProvider = Future<String?> Function();

/// 把位置交给 functions/api/checkin.js，由服务器决定能不能打卡、是否准时。
class CheckinService {
  CheckinService({
    http.Client? client,
    IdTokenProvider? idToken,
    Uri? endpoint,
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client(),
       _idToken = idToken ?? _firebaseIdToken,
       _endpoint = endpoint ?? Uri.base.resolve('/api/checkin');

  final http.Client _client;
  final IdTokenProvider _idToken;
  final Uri _endpoint;
  final Duration timeout;

  static Future<String?> _firebaseIdToken() =>
      FirebaseAuth.instance.currentUser?.getIdToken() ?? Future.value(null);

  Future<CheckinResult> checkIn(CheckinPosition position) async {
    final token = await _idToken();
    if (token == null || token.isEmpty) {
      throw const CheckinException('请先登录');
    }

    final request = http.Request('POST', _endpoint)
      ..headers['Authorization'] = 'Bearer $token'
      ..headers['content-type'] = 'application/json; charset=utf-8'
      ..body = jsonEncode({
        'latitude': position.latitude,
        'longitude': position.longitude,
      });

    final http.Response response;
    try {
      final streamed = await _client.send(request).timeout(timeout);
      response = await http.Response.fromStream(streamed).timeout(timeout);
    } on TimeoutException {
      throw const CheckinException('连线逾时，请再试一次');
    } catch (_) {
      throw const CheckinException('连线失败，请检查网络后再试一次');
    }

    if (response.statusCode != 201) {
      throw CheckinException(_errorMessage(response));
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      throw const CheckinException('打卡完成，但回应看不懂，请重新打开页面查看');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const CheckinException('打卡完成，但回应看不懂，请重新打开页面查看');
    }
    try {
      return CheckinResult.fromJson(decoded);
    } on FormatException {
      throw const CheckinException('打卡完成，但回应看不懂，请重新打开页面查看');
    }
  }

  /// 服务器的错误都是 { "error": "..." }。读不到就给一句通用的话。
  static String _errorMessage(http.Response response) {
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic> && decoded['error'] is String) {
        return decoded['error'] as String;
      }
    } catch (_) {
      // 回应不是 JSON，落到下面的通用文字。
    }
    return '打卡失败，请稍后再试';
  }
}
