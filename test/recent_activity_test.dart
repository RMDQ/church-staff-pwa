import 'support/church_test_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:church_staff_pwa/features/dashboard/domain/entities/recent_activity.dart';

RecentActivity _timed(String start, String end, {String title = '活动'}) =>
    RecentActivity(
      startTime: DateTime.parse('${start}Z'),
      endTime: DateTime.parse('${end}Z'),
      isAllDay: false,
      title: title,
    );

/// 全日活动照 Google 的惯例：end.date 是**隔天**（不含当天）。
RecentActivity _allDay(
  String startDate,
  String endDateExclusive, {
  String title = '活动',
}) => RecentActivity(
  startTime: DateTime.parse('${startDate}T00:00Z'),
  endTime: DateTime.parse('${endDateExclusive}T00:00Z'),
  isAllDay: true,
  title: title,
);

void main() {
  setUp(() => setTestChurchConfig(timeZone: 'Etc/UTC'));
  setUpAll(() async => initializeDateFormatting('zh_TW', null));

  group('跨日活动的天数判读', () {
    test('全日活动：end.date 是排他的，不能多算一天', () {
      // 8/12 到 8/14 的三天特会，Google 给的 end.date 是 8/15
      final retreat = _allDay('2026-08-12', '2026-08-15');
      expect(retreat.startDay, DateTime.utc(2026, 8, 12));
      expect(retreat.endDay, DateTime.utc(2026, 8, 14));
      expect(retreat.spansMultipleDays, isTrue);
    });

    test('单日全日活动不算跨日', () {
      final single = _allDay('2026-08-12', '2026-08-13');
      expect(single.endDay, DateTime.utc(2026, 8, 12));
      expect(single.spansMultipleDays, isFalse);
    });

    test('有时间的活动跨过午夜才算跨日', () {
      expect(
        _timed('2026-08-12 19:00', '2026-08-12 21:00').spansMultipleDays,
        isFalse,
      );
      expect(
        _timed('2026-08-12 22:00', '2026-08-13 02:00').spansMultipleDays,
        isTrue,
      );
    });

    test('结束正好落在午夜不算跨到隔天', () {
      final event = _timed('2026-08-12 19:00', '2026-08-13 00:00');
      expect(event.endDay, DateTime.utc(2026, 8, 12));
      expect(event.spansMultipleDays, isFalse);
    });

    test('资料坏掉（end 早于 start）时退化成单日，不会炸也不会算出负区间', () {
      final broken = _timed('2026-08-12 19:00', '2026-08-10 09:00');
      expect(broken.endDay, DateTime.utc(2026, 8, 12));
      expect(broken.spansMultipleDays, isFalse);
    });
  });

  group('筛选：进行中的活动必须留下', () {
    // 这组是这次修改的核心。旧版以「开始时间」筛选，8/13 当天会把 8/12 开始
    // 的特会整个丢掉 —— 明明正在进行中。
    test('跨日全日活动在中间那天仍然要显示', () {
      final retreat = _allDay('2026-08-12', '2026-08-15', title: '夏令会');
      final result = selectRecentActivities(
        [retreat],
        now: DateTime.utc(2026, 8, 13, 10),
        limit: 3,
      );
      expect(result.map((e) => e.title), ['夏令会']);
      expect(retreat.isOngoing(DateTime.utc(2026, 8, 13, 10)), isTrue);
    });

    test('跨日活动在最后一天仍然要显示', () {
      final result = selectRecentActivities(
        [_allDay('2026-08-12', '2026-08-15', title: '夏令会')],
        now: DateTime.utc(2026, 8, 14, 23, 59),
        limit: 3,
      );
      expect(result, hasLength(1));
    });

    test('跨日活动结束后就不再显示', () {
      final result = selectRecentActivities(
        [_allDay('2026-08-12', '2026-08-15', title: '夏令会')],
        now: DateTime.utc(2026, 8, 15, 0, 1),
        limit: 3,
      );
      expect(result, isEmpty);
    });

    test('进行中的有时间活动要留下，已结束的不留', () {
      final ongoing = _timed('2026-08-13 09:00', '2026-08-13 17:00');
      final finished = _timed('2026-08-13 06:00', '2026-08-13 08:00');
      final result = selectRecentActivities(
        [ongoing, finished],
        now: DateTime.utc(2026, 8, 13, 10),
        limit: 3,
      );
      expect(result, hasLength(1));
      expect(result.single.startTime, ongoing.startTime);
    });

    test('今天的全日活动整天都算数，不会下午就消失', () {
      final result = selectRecentActivities(
        [_allDay('2026-08-13', '2026-08-14')],
        now: DateTime.utc(2026, 8, 13, 15, 30),
        limit: 3,
      );
      expect(result, hasLength(1));
    });

    test('进行中的排在还没开始的前面', () {
      final ongoing = _allDay('2026-08-12', '2026-08-15', title: '夏令会');
      final later = _allDay('2026-08-20', '2026-08-21', title: '儿童主日');
      final result = selectRecentActivities(
        [later, ongoing],
        now: DateTime.utc(2026, 8, 13),
        limit: 3,
      );
      expect(result.map((e) => e.title), ['夏令会', '儿童主日']);
    });

    test('超过上限只取前几笔', () {
      final result = selectRecentActivities(
        [
          for (var day = 14; day < 20; day++)
            _allDay('2026-08-$day', '2026-08-${day + 1}', title: 'day$day'),
        ],
        now: DateTime.utc(2026, 8, 13),
        limit: 3,
      );
      expect(result.map((e) => e.title), ['day14', 'day15', 'day16']);
    });
  });

  group('日期文字', () {
    test('单日全日活动带星期', () {
      expect(
        formatRecentActivityDate(_allDay('2026-08-12', '2026-08-13')),
        '08/12 (三)',
      );
    });

    test('单日有时间活动带星期与时间', () {
      expect(
        formatRecentActivityDate(
          _timed('2026-08-12 19:30', '2026-08-12 21:00'),
        ),
        '08/12 (三) 19:30',
      );
    });

    test('跨日活动显示区间', () {
      expect(
        formatRecentActivityDate(_allDay('2026-08-12', '2026-08-15')),
        '08/12–08/14',
      );
    });

    test('跨月的区间也正确', () {
      expect(
        formatRecentActivityDate(_allDay('2026-08-30', '2026-09-03')),
        '08/30–09/02',
      );
    });
  });

  group('JSON 往返', () {
    test('存进快取再读出来，区间不会走样', () {
      final original = _allDay('2026-08-12', '2026-08-15', title: '夏令会');
      final restored = RecentActivity.fromJson(original.toJson());
      expect(restored.startDay, original.startDay);
      expect(restored.endDay, original.endDay);
      expect(restored.isAllDay, isTrue);
      expect(restored.title, '夏令会');
    });

    test('旧版快取没有 endTime 时退化成单日而不是崩溃', () {
      final restored = RecentActivity.fromJson({
        'startTime': '2026-08-12T09:00:00.000',
        'isAllDay': false,
        'title': '旧资料',
      });
      expect(restored.spansMultipleDays, isFalse);
    });
  });
}
