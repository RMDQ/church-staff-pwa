import 'dart:convert';

import 'package:church_staff_pwa/core/services/release_check_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

ReleaseCheckService _service(http.Response Function() respond) =>
    ReleaseCheckService(client: MockClient((_) async => respond()));

void main() {
  group('isNewerRelease', () {
    test('逐段比数字，10 月比 9 月新', () {
      expect(isNewerRelease('2026.10.1', '2026.9.1'), isTrue);
      expect(isNewerRelease('2026.9.2', '2026.9.1'), isTrue);
      expect(isNewerRelease('2027.1.1', '2026.12.9'), isTrue);
    });

    test('一样或比较旧都不算', () {
      expect(isNewerRelease('2026.9.1', '2026.9.1'), isFalse);
      expect(isNewerRelease('2026.9.1', '2026.10.1'), isFalse);
    });

    test('目前版本读不到（旧版精灵、不是精灵装的）不提醒', () {
      expect(isNewerRelease('2026.9.1', null), isFalse);
      expect(isNewerRelease('2026.9.1', 'installer-abc'), isFalse);
      expect(isNewerRelease('latest', '2026.9.1'), isFalse);
    });
  });

  group('fetchLatest', () {
    test('读出版本、说明和教学连结', () async {
      final release = await _service(
        () => http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'version': '2026.10.1',
              'notes': ['可以上传教会 Logo', 3],
              'guideUrl': 'https://example.org/update',
            }),
          ),
          200,
        ),
      ).fetchLatest();
      expect(release!.version, '2026.10.1');
      expect(release.notes, ['可以上传教会 Logo']);
      expect(release.guideUrl, 'https://example.org/update');
    });

    test('不是 https 的连结不给点', () async {
      final release = await _service(
        () => http.Response(
          jsonEncode({
            'version': '2026.10.1',
            'guideUrl': 'javascript:alert(1)',
          }),
          200,
        ),
      ).fetchLatest();
      expect(release!.guideUrl, isNull);
    });

    test('读不到或格式不对就安静地回 null', () async {
      expect(
        await _service(() => http.Response('', 404)).fetchLatest(),
        isNull,
      );
      expect(
        await _service(() => http.Response('not json', 200)).fetchLatest(),
        isNull,
      );
      expect(
        await _service(
          () => http.Response(jsonEncode({'version': 'v2'}), 200),
        ).fetchLatest(),
        isNull,
      );
    });
  });
}
