import 'dart:convert';

import 'package:church_staff_pwa/features/checkin/data/checkin_service.dart';
import 'package:church_staff_pwa/features/checkin/domain/checkin_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _position = CheckinPosition(latitude: 41.8919, longitude: 12.4839);

CheckinService _serviceReturning(
  http.Response response, {
  List<http.Request>? sent,
}) {
  return CheckinService(
    client: MockClient((request) async {
      sent?.add(request);
      return response;
    }),
    idToken: () async => 'token-123',
    endpoint: Uri.parse('https://example.test/api/checkin'),
  );
}

http.Response _json(int status, Object body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  test(
    'sends the ID token and the position, then reads a 201 result',
    () async {
      final sent = <http.Request>[];
      final service = _serviceReturning(
        _json(201, {'status': 'onTime', 'time': '13:10', 'distanceMeters': 22}),
        sent: sent,
      );

      final result = await service.checkIn(_position);

      expect(result.onTime, isTrue);
      expect(result.time, '13:10');
      expect(result.distanceMeters, 22);
      expect(sent.single.headers['Authorization'], 'Bearer token-123');
      expect(jsonDecode(sent.single.body), {
        'latitude': 41.8919,
        'longitude': 12.4839,
      });
    },
  );

  test('reads a late result', () async {
    final service = _serviceReturning(
      _json(201, {'status': 'late', 'time': '13:45', 'distanceMeters': 30}),
    );
    final result = await service.checkIn(_position);
    expect(result.onTime, isFalse);
  });

  test('shows the server message for a refusal', () async {
    final service = _serviceReturning(_json(403, {'error': '打卡只在每周主日崇拜开放'}));
    expect(
      () => service.checkIn(_position),
      throwsA(
        isA<CheckinException>().having(
          (e) => e.message,
          'message',
          '打卡只在每周主日崇拜开放',
        ),
      ),
    );
  });

  test(
    'shows the duplicate message for a second check-in the same day',
    () async {
      final service = _serviceReturning(_json(409, {'error': '今天已经打过卡了'}));
      expect(
        () => service.checkIn(_position),
        throwsA(
          isA<CheckinException>().having(
            (e) => e.message,
            'message',
            '今天已经打过卡了',
          ),
        ),
      );
    },
  );

  test('falls back to a plain message when the body is not JSON', () async {
    final service = _serviceReturning(http.Response('<html>oops</html>', 502));
    expect(
      () => service.checkIn(_position),
      throwsA(
        isA<CheckinException>().having(
          (e) => e.message,
          'message',
          '打卡失败，请稍后再试',
        ),
      ),
    );
  });

  test('refuses to send without a signed-in user', () async {
    final service = CheckinService(
      client: MockClient((_) async => throw StateError('must not be called')),
      idToken: () async => null,
      endpoint: Uri.parse('https://example.test/api/checkin'),
    );
    expect(
      () => service.checkIn(_position),
      throwsA(
        isA<CheckinException>().having((e) => e.message, 'message', '请先登录'),
      ),
    );
  });

  test(
    'a success body that does not match the contract is reported, not crashed on',
    () async {
      final service = _serviceReturning(_json(201, {'unexpected': true}));
      expect(
        () => service.checkIn(_position),
        throwsA(isA<CheckinException>()),
      );
    },
  );
}
