/// 打卡相关的提醒。只在 App 打开时计算，不发推送。
class CheckinReminder {
  const CheckinReminder({
    required this.title,
    required this.detail,
    required this.urgent,
  });

  final String title;
  final String detail;

  /// 马上要做的（true），还是只是留意（false）。
  final bool urgent;
}

/// [now] 是教会时区的时间。[serviceWeekday] 为 1 至 7（周一至周日）。
List<CheckinReminder> checkinReminders({
  required DateTime now,
  required String start,
  required String end,
  required int allowedMeters,
  required int serviceWeekday,
  required bool checkedInToday,
  required bool emailVerified,
}) {
  final reminders = <CheckinReminder>[];

  if (!emailVerified) {
    reminders.add(
      const CheckinReminder(title: '邮箱还没有验证', detail: '验证后才能打卡', urgent: true),
    );
  }

  if (now.weekday == serviceWeekday && !checkedInToday) {
    final minutes = now.hour * 60 + now.minute;
    final open = _minutesOf(start);
    final close = _minutesOf(end);
    if (minutes >= open - 60 && minutes < open) {
      reminders.add(
        CheckinReminder(
          title: '今天 $start 开放打卡',
          detail: '需要在教堂附近 $allowedMeters 米内',
          urgent: false,
        ),
      );
    }
    if (minutes >= open && minutes <= close) {
      reminders.add(
        CheckinReminder(title: '现在可以打卡', detail: '截止 $end，还没有打卡', urgent: true),
      );
    }
  }

  return reminders;
}

int _minutesOf(String clock) {
  final parts = clock.split(':');
  return int.parse(parts[0]) * 60 + int.parse(parts[1]);
}
