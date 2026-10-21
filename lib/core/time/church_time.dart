import 'package:timezone/timezone.dart' as tz;

import '../config/church_config.dart';
import 'time_zone_database.dart';

/// 时间点使用教会时区；只有日期的值使用 UTC 年月日，避免装置时区及 DST
/// 让加七天变成不同的日子。日期值不是活动开始的 UTC 时间点。
abstract final class ChurchTime {
  static String get timeZone => ChurchConfig.current.timeZone;

  static tz.TZDateTime now() => inZone(DateTime.now());

  static tz.TZDateTime inZone(DateTime instant) =>
      tz.TZDateTime.from(instant, timeZoneLocation(timeZone));

  static DateTime today() => dateOnly(now());

  static DateTime dateOnly(DateTime value) =>
      DateTime.utc(value.year, value.month, value.day);

  /// 行事历与首页共用快取语意：全天存日期，有时间的活动存时间点。
  static DateTime parseEventTime(String value, {required bool isAllDay}) {
    final parsed = DateTime.parse(value);
    return isAllDay ? dateOnly(parsed) : inZone(parsed);
  }

  static DateTime eventInstant(DateTime value, {required bool isAllDay}) =>
      isAllDay ? atDate(value) : value;

  static tz.TZDateTime atDate(DateTime date) => tz.TZDateTime(
    timeZoneLocation(timeZone),
    date.year,
    date.month,
    date.day,
  );

  static tz.TZDateTime atTime(DateTime date, int hour, int minute) {
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
      throw const FormatException('无效的时间');
    }
    final result = tz.TZDateTime(
      timeZoneLocation(timeZone),
      date.year,
      date.month,
      date.day,
      hour,
      minute,
    );
    if (result.year != date.year ||
        result.month != date.month ||
        result.day != date.day ||
        result.hour != hour ||
        result.minute != minute) {
      throw const FormatException('这个时间因夏令时间切换而不存在，请选其他时间');
    }
    return result;
  }

  static String dateKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  static DateTime parseDate(String value) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
      throw const FormatException('日期必须是 YYYY-MM-DD');
    }
    final parts = value.split('-').map(int.parse).toList();
    final date = DateTime.utc(parts[0], parts[1], parts[2]);
    if (dateKey(date) != value) throw const FormatException('无效的日期');
    return date;
  }
}
