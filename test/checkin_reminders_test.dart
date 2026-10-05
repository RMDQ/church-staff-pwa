import 'package:church_staff_pwa/features/checkin/domain/checkin_reminders.dart';
import 'package:flutter_test/flutter_test.dart';

/// 2026-10-04 是周日。
DateTime _sunday(int hour, int minute) => DateTime(2026, 10, 4, hour, minute);

List<CheckinReminder> _at(
  DateTime now, {
  bool checkedIn = false,
  bool verified = true,
}) => checkinReminders(
  now: now,
  start: '13:00',
  end: '15:30',
  allowedMeters: 100,
  serviceWeekday: 7,
  checkedInToday: checkedIn,
  emailVerified: verified,
);

void main() {
  test('an hour before the window opens, says when it opens', () {
    final list = _at(_sunday(12, 30));
    expect(list.single.title, '今天 13:00 开放打卡');
    expect(list.single.urgent, isFalse);
  });

  test('inside the window and not yet checked in, it is urgent', () {
    final list = _at(_sunday(13, 10));
    expect(list.single.title, '现在可以打卡');
    expect(list.single.urgent, isTrue);
  });

  test('once checked in, no check-in reminder is shown', () {
    expect(_at(_sunday(13, 10), checkedIn: true), isEmpty);
  });

  test('after the window closes, nothing is shown', () {
    expect(_at(_sunday(15, 31)), isEmpty);
  });

  test('on a day that is not the service day, nothing is shown', () {
    final saturday = DateTime(2026, 10, 3, 13, 10);
    expect(_at(saturday), isEmpty);
  });

  test('an unverified email is always reminded, urgently', () {
    final list = _at(_sunday(9, 0), verified: false);
    expect(list.single.title, '邮箱还没有验证');
    expect(list.single.urgent, isTrue);
  });
}
