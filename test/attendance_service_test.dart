import 'dart:convert';

import 'package:church_staff_pwa/features/attendance/data/attendance_service.dart';
import 'package:church_staff_pwa/features/attendance/domain/attendance_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _sample = {
  'date': '2026-10-04',
  'records': [
    {
      'name': '甲',
      'smallGroups': ['小组甲'],
      'time': '13:10',
      'status': 'onTime',
      'distanceMeters': 22,
    },
    {
      'name': '乙',
      'smallGroups': <String>[],
      'time': '13:40',
      'status': 'late',
      'distanceMeters': null,
    },
  ],
  'counts': {'total': 2, 'onTime': 1, 'late': 1},
};

AttendanceService _serviceReturning(
  http.Response response, {
  List<http.Request>? sent,
}) {
  return AttendanceService(
    client: MockClient((request) async {
      sent?.add(request);
      return response;
    }),
    idToken: () async => 'token-1',
    endpoint: Uri.parse('https://example.test/api/attendance'),
  );
}

http.Response _json(int status, Object body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  test('reads a day with its rows and counts', () async {
    final day = await _serviceReturning(
      _json(200, _sample),
    ).load(date: '2026-10-04');

    expect(day.date, '2026-10-04');
    expect(day.total, 2);
    expect(day.onTime, 1);
    expect(day.late, 1);
    expect(day.rows.first.name, '甲');
    expect(day.rows.first.smallGroups, ['小组甲']);
    expect(day.rows.first.onTime, isTrue);
    expect(day.rows.last.onTime, isFalse);
    expect(day.rows.last.distanceMeters, isNull);
  });

  test('sends the date and the ID token', () async {
    final sent = <http.Request>[];
    await _serviceReturning(
      _json(200, _sample),
      sent: sent,
    ).load(date: '2026-10-04');

    expect(sent.single.url.queryParameters['date'], '2026-10-04');
    expect(sent.single.headers['Authorization'], 'Bearer token-1');
  });

  test('without a date the server chooses today', () async {
    final sent = <http.Request>[];
    await _serviceReturning(_json(200, _sample), sent: sent).load();

    expect(sent.single.url.queryParameters.containsKey('date'), isFalse);
  });

  test('shows the server message for a refusal', () async {
    final service = _serviceReturning(_json(403, {'error': '只有管理员和小组长可以查看出勤'}));
    expect(
      () => service.load(),
      throwsA(
        isA<AttendanceException>().having(
          (e) => e.message,
          'message',
          '只有管理员和小组长可以查看出勤',
        ),
      ),
    );
  });

  test(
    'a body that does not match the contract is reported, not crashed on',
    () async {
      final service = _serviceReturning(_json(200, {'unexpected': true}));
      expect(() => service.load(), throwsA(isA<AttendanceException>()));
    },
  );

  test('refuses to send without a signed-in user', () async {
    final service = AttendanceService(
      client: MockClient((_) async => throw StateError('must not be called')),
      idToken: () async => null,
      endpoint: Uri.parse('https://example.test/api/attendance'),
    );
    expect(
      () => service.load(),
      throwsA(
        isA<AttendanceException>().having((e) => e.message, 'message', '请先登录'),
      ),
    );
  });

  test('a row with no name is refused rather than shown blank', () {
    expect(
      () => AttendanceRow.fromJson({'time': '13:00', 'status': 'onTime'}),
      throwsFormatException,
    );
  });
}
