import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:church_staff_pwa/features/dashboard/domain/entities/recent_activity.dart';
import 'package:church_staff_pwa/features/dashboard/presentation/widgets/recent_activity_row.dart';

/// 日期栏是单行 + ellipsis：字太长不会报 overflow，只会被默默截掉，
/// 所以要主动量。
///
/// 但**不能**拿量到的数字去跟栏宽比对绝对值：widget test 跑的是测试字型
/// （每个字元都是 1em 的方块），数字与括号被高估将近一倍。实测
/// 「08/12 (三) 19:30」在测试字型下是 180px，真实字型大约只有 96px。
/// 拿测试字型的绝对值当门槛，测到的是字型而不是版面。
///
/// 站得住脚的是**相对比较**：两个字串在同一个字型下量，比出来的大小关系
/// 在真实字型下同样成立。所以这里守的是「新格式不会比改动前最宽的格式更宽」
/// —— 只要这条成立，这次改动就不可能造成原本没有的跑版。
double _intrinsicWidth(String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  return painter.width;
}

/// 首页那张卡片外面有 body 的 16 padding，卡片内还有 16 —— 两侧各 32。
const double _horizontalChrome = 32 * 2;

RecentActivity _allDay(String start, String endExclusive) => RecentActivity(
  startTime: DateTime.parse('$start 00:00'),
  endTime: DateTime.parse('$endExclusive 00:00'),
  isAllDay: true,
  title: '夏令会',
);

RecentActivity _timed(String start, String end) => RecentActivity(
  startTime: DateTime.parse(start),
  endTime: DateTime.parse(end),
  isAllDay: false,
  title: '祷告会',
);

/// 改动前就存在、而且最长的格式：有时间的单日活动。当作宽度基准线。
final _widestExistingFormat = _timed('2026-08-12 19:30', '2026-08-12 21:00');

/// 跨月的区间是新格式里最长的：08/30–09/02。
final _widestRangeFormat = _allDay('2026-08-30', '2026-09-03');

void main() {
  setUpAll(() async => initializeDateFormatting('zh_TW', null));

  group('跑版防线', () {
    test('跨日区间不比改动前最宽的格式更宽', () {
      final range = _intrinsicWidth(
        formatRecentActivityDate(_widestRangeFormat),
        RecentActivityRow.dateStyle,
      );
      final baseline = _intrinsicWidth(
        formatRecentActivityDate(_widestExistingFormat),
        RecentActivityRow.dateStyle,
      );

      expect(
        range,
        lessThanOrEqualTo(baseline),
        reason:
            '「${formatRecentActivityDate(_widestRangeFormat)}」($range) 比 '
            '「${formatRecentActivityDate(_widestExistingFormat)}」($baseline) 还宽，'
            '栏宽没变，等于这次改动自己造成截断',
      );
    });

    test('跨日格式刻意不带星期，带了就会超过基准线', () {
      // 记录为什么格式长这样：加上 (三) 之类的星期会让区间变成最宽的格式，
      // 上面那条防线就会失守。有人想加回星期时会先撞到这里。
      final withWeekday = _intrinsicWidth(
        '08/30 (日)–09/02 (三)',
        RecentActivityRow.dateStyle,
      );
      final baseline = _intrinsicWidth(
        formatRecentActivityDate(_widestExistingFormat),
        RecentActivityRow.dateStyle,
      );
      expect(withWeekday, greaterThan(baseline));
    });

    testWidgets('标题起始位置不受日期格式影响', (tester) async {
      // 固定 flex 的用意就是这个：不同日期格式不能让标题左右跳动。
      tester.view.physicalSize = const Size(390 * 3, 800 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      final xs = <double>[];
      for (final activity in [
        _allDay('2026-08-12', '2026-08-13'),
        _widestRangeFormat,
        _widestExistingFormat,
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 390 - _horizontalChrome,
                  child: RecentActivityRow(activity: activity),
                ),
              ),
            ),
          ),
        );
        xs.add(tester.getTopLeft(find.text(activity.title)).dx);
      }

      expect(xs.toSet(), hasLength(1), reason: '标题的 x 起点必须一致，实际: $xs');
    });

    testWidgets('窄萤幕上不会 overflow（该截的是文字，不是版面）', (tester) async {
      tester.view.physicalSize = const Size(320 * 3, 800 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320 - _horizontalChrome,
                child: RecentActivityRow(activity: _widestRangeFormat),
              ),
            ),
          ),
        ),
      );

      // RenderFlex overflow 会以例外的形式被 flutter_test 收集起来。
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('跨日活动显示的是区间而不是只有开始那天', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: RecentActivityRow(activity: _widestRangeFormat)),
      ),
    );
    expect(find.text('08/30–09/02'), findsOneWidget);
  });
}
