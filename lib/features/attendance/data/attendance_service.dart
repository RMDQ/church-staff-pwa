import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import '../domain/attendance_models.dart';

typedef AttendanceIdTokenProvider = Future<String?> Function();

/// 读取某一天的出勤，由 functions/api/attendance.js 按身份过滤。
class AttendanceService {
  AttendanceService({
    http.Client? client,
    AttendanceIdTokenProvider? idToken,
    Uri? endpoint,
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client(),
       _idToken = idToken ?? _firebaseIdToken,
       _endpoint = endpoint ?? Uri.base.resolve('/api/attendance');

  final http.Client _client;
  final AttendanceIdTokenProvider _idToken;
  final Uri _endpoint;
  final Duration timeout;

  static Future<String?> _firebaseIdToken() =>
      FirebaseAuth.instance.currentUser?.getIdToken() ?? Future.value(null);

  /// [date] 为 YYYY-MM-DD；不传就由服务器用今天（教会时区）。
  Future<AttendanceDay> load({String? date}) async {
    final token = await _idToken();
    if (token == null || token.isEmpty) {
      throw const AttendanceException('请先登录');
    }

    final uri = date == null
        ? _endpoint
        : _endpoint.replace(queryParameters: {'date': date});
    final request = http.Request('GET', uri)
      ..headers['Authorization'] = 'Bearer $token';

    final http.Response response;
    try {
      final streamed = await _client.send(request).timeout(timeout);
      response = await http.Response.fromStream(streamed).timeout(timeout);
    } on TimeoutException {
      throw const AttendanceException('读取逾时，请再试一次');
    } catch (_) {
      throw const AttendanceException('连线失败，请检查网络后再试一次');
    }

    if (response.statusCode != 200) {
      throw AttendanceException(_errorMessage(response));
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      throw const AttendanceException('资料读到了，但格式看不懂，请稍后再试');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const AttendanceException('资料读到了，但格式看不懂，请稍后再试');
    }
    try {
      return AttendanceDay.fromJson(decoded);
    } on FormatException {
      throw const AttendanceException('资料读到了，但格式看不懂，请稍后再试');
    }
  }

  static String _errorMessage(http.Response response) {
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic> && decoded['error'] is String) {
        return decoded['error'] as String;
      }
    } catch (_) {
      // 不是 JSON，落到下面的通用文字。
    }
    return '读取出勤失败，请稍后再试';
  }
}
