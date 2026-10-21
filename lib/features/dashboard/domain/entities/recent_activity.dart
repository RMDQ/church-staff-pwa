import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../core/time/church_time.dart';

/// 首页「近期活动」列出的一筆行事曆活动。
///
/// 这里刻意带着结束时间。先前的版本只存开始时间，于是跨日活动整个坏掉：
/// 筛选条件是「开始时间还没过」，所以 8/12–8/14 的特会在 8/13 当天会从首
/// 页消失 —— 明明正在进行中。Google Calendar 的 `timeMin` 是用活动的**结束**
/// 时间过滤的，那笔资料本来就有回传，是前端自己丢掉的。
@immutable
class RecentActivity {
  const RecentActivity({
    required this.startTime,
    required this.endTime,
    required this.isAllDay,
    required this.title,
  });

  final DateTime startTime;

  /// 活动结束时间，采 Google Calendar 的惯例：**不含**这个瞬间。
  /// 全日活动的 `end.date` 是隔天，一日活动的 end 是次日零点。
  final DateTime endTime;

  final bool isAllDay;
  final String title;

  DateTime get startInstant =>
      ChurchTime.eventInstant(startTime, isAllDay: isAllDay);

  DateTime get startDay => ChurchTime.dateOnly(startTime);

  /// 活动实际涵盖的最后一天。
  ///
  /// 因为 [endTime] 是排他的，直接 dateOnly 会多算一天：8/12–8/14 的全日
  /// 活动，Google 给的 end.date 是 8/15。减一微秒再取日期才会落在 8/14。
  /// 行事历画面的 CalendarEvent.endDay 用的是同一套算法，两边要一致，
  /// 否则同一笔活动在两个画面上的天数会对应不起来。
  DateTime get endDay {
    final normalizedEnd = endTime.isBefore(startTime) ? startTime : endTime;
    final adjusted = normalizedEnd.subtract(const Duration(microseconds: 1));
    final endDayOnly = ChurchTime.dateOnly(adjusted);
    return endDayOnly.isBefore(startDay) ? startDay : endDayOnly;
  }

  bool get spansMultipleDays => endDay.isAfter(startDay);

  /// [now] 当前这笔活动是否仍未结束（包含正在进行中）。
  ///
  /// 全日活动以「天」为单位判断：只要今天还没超过最后一天就算数，不会因为
  /// 现在是下午三点就把今天的全日活动视为过去式。
  bool isCurrentOrUpcoming(DateTime now) {
    if (isAllDay) {
      return !endDay.isBefore(ChurchTime.dateOnly(ChurchTime.inZone(now)));
    }
    return endTime.isAfter(now);
  }

  bool isOngoing(DateTime now) {
    if (isAllDay) {
      final today = ChurchTime.dateOnly(ChurchTime.inZone(now));
      return !today.isBefore(startDay) && !today.isAfter(endDay);
    }
    return !startTime.isAfter(now) && endTime.isAfter(now);
  }

  Map<String, dynamic> toJson() => {
    'startTime': startTime.toIso8601String(),
    'endTime': endTime.toIso8601String(),
    'isAllDay': isAllDay,
    'title': title,
  };

  /// 旧版快取没有 endTime。真的读到旧资料时退化成「当天结束」，宁可少显示
  /// 一天也不要凭空生出一个不存在的区间；快取 key 已经升版，正常情况下走
  /// 不到这条路。
  factory RecentActivity.fromJson(Map<String, dynamic> json) {
    final isAllDay = json['isAllDay'] as bool? ?? false;
    final start = ChurchTime.parseEventTime(
      json['startTime'] as String,
      isAllDay: isAllDay,
    );
    final endRaw = json['endTime'];
    return RecentActivity(
      startTime: start,
      endTime: endRaw is String
          ? ChurchTime.parseEventTime(endRaw, isAllDay: isAllDay)
          : start.add(const Duration(minutes: 1)),
      isAllDay: isAllDay,
      title: json['title'] as String,
    );
  }
}

/// 筛掉已结束的活动、依开始时间排序，取前 [limit] 笔。
///
/// 正在进行的活动会排在最前面（它的开始时间最早），这是刻意的：正在办的活动
/// 比还没到的更该被看见。
List<RecentActivity> selectRecentActivities(
  List<RecentActivity> activities, {
  required DateTime now,
  required int limit,
}) {
  final upcoming =
      activities.where((activity) => activity.isCurrentOrUpcoming(now)).toList()
        ..sort((a, b) => a.startInstant.compareTo(b.startInstant));
  if (upcoming.length <= limit) return upcoming;
  return upcoming.take(limit).toList();
}

final _monthDay = DateFormat('MM/dd', 'zh_CN');
final _monthDayWeekday = DateFormat('MM/dd (EEEEE)', 'zh_CN');
final _monthDayWeekdayTime = DateFormat('MM/dd (EEEEE) HH:mm', 'zh_CN');

/// 首页那一栏要显示的日期文字。
///
/// 版面限制：这串字挤在 `Expanded(flex: 2)` 里、单行、超出就 ellipsis ——
/// 也就是说太长不会报错，只会被默默截掉。所以跨日的格式刻意不带星期，
/// 「08/12–08/14」比原本最长的「08/12 (三) 15:30」还短，栏宽不会被撑爆。
/// recent_activity_test.dart 有一条测试专门盯住这个宽度上限。
String formatRecentActivityDate(RecentActivity activity) {
  if (activity.spansMultipleDays) {
    return '${_monthDay.format(activity.startDay)}'
        '–${_monthDay.format(activity.endDay)}';
  }
  return activity.isAllDay
      ? _monthDayWeekday.format(activity.startTime)
      : _monthDayWeekdayTime.format(activity.startTime);
}
