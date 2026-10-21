import 'support/church_test_config.dart';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:church_staff_pwa/core/types/service_type.dart';
import 'package:church_staff_pwa/features/roster/data/roster_import_service.dart';
import 'package:church_staff_pwa/features/roster/data/roster_photo.dart';

const _photo = RosterPhoto(mimeType: 'image/jpeg', data: 'AAAA');

RosterImportService _service(MockClientHandler handler) => RosterImportService(
  client: MockClient(handler),
  idToken: () async => 'token',
  endpoint: Uri.parse('https://app.example/api/roster/import-image'),
);

Future<String> _errorFor(http.Response response) async {
  try {
    await _service(
      (_) async => response,
    ).convert(type: ServiceType.youth, photos: const [_photo]);
  } on RosterImportException catch (e) {
    return e.message;
  }
  fail('应该要丢 RosterImportException');
}

void main() {
  setUp(() => setTestChurchConfig(photoImport: true));
  group('RosterImportService 的错误讯息', () {
    test('API 自己写的讯息原样显示，不加状态码', () async {
      final message = await _errorFor(
        http.Response(
          jsonEncode({'error': 'Gemini 免费版现在太多人用，过几分钟再试一次'}),
          503,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      );
      expect(message, 'Gemini 免费版现在太多人用，过几分钟再试一次');
    });

    test('不是 API 产生的回应会带上状态码，跟上面那句分得出来', () async {
      // Cloudflare 因为 CPU 超时砍掉 worker 时回的就是这种：503、HTML。
      final message = await _errorFor(
        http.Response('<html>Worker exceeded resource limits</html>', 503),
      );
      expect(message, contains('（503）'));
      expect(message, isNot('Gemini 免费版现在太多人用，过几分钟再试一次'));
    });
  });

  test('成功时回排版过的 JSON，填得回汇入框', () async {
    final service = _service((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['type'], 'youth');
      expect(body['images'], hasLength(1));
      return http.Response(
        jsonEncode({
          'entries': [
            {'date': '2026-10-04'},
          ],
        }),
        200,
      );
    });
    final json = await service.convert(
      type: ServiceType.youth,
      photos: const [_photo],
    );
    expect(json, contains('\n  {'));
    expect(jsonDecode(json), [
      {'date': '2026-10-04'},
    ]);
  });
}
