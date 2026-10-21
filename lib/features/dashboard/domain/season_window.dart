/// 首页「本季服事」涵盖的日期范围。
///
/// 只看本季的话，季末最后几天常常一场聚会都没有（例如 9/28–9/30），首页就
/// 显示「本季尚无排到服事」，但下一季的服事表早就排好了。所以最后两週一并
/// 列出下一季；服事表在季末那个月本来就会读到下一季底。
class SeasonWindow {
  const SeasonWindow({
    required this.start,
    required this.end,
    required this.includesNextQuarter,
  });

  final DateTime start;
  final DateTime end;
  final bool includesNextQuarter;

  // 范围照样是本季（季末两週含下季），但不写在标题上：同工在意的是「我接下来
  // 要服事什么」，不是季度怎么切。
  String get title => '我的服事';

  String get emptyText => '最近还没有排到你的服事';
}

/// [today] 是教会时区的日期（见 ChurchTime.today）。
SeasonWindow seasonWindow(DateTime today) {
  final startMonth = ((today.month - 1) ~/ 3) * 3 + 1;
  final start = DateTime.utc(today.year, startMonth, 1);
  final quarterEnd = DateTime.utc(today.year, startMonth + 3, 0);
  final day = DateTime.utc(today.year, today.month, today.day);
  if (quarterEnd.difference(day).inDays >= 14) {
    return SeasonWindow(
      start: start,
      end: quarterEnd,
      includesNextQuarter: false,
    );
  }
  return SeasonWindow(
    start: start,
    end: DateTime.utc(today.year, startMonth + 6, 0),
    includesNextQuarter: true,
  );
}
