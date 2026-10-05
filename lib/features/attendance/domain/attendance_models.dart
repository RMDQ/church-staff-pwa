/// 一位会众在某一天的打卡记录，由服务器整理好后返回。
class AttendanceRow {
  const AttendanceRow({
    required this.name,
    required this.smallGroups,
    required this.time,
    required this.onTime,
    required this.distanceMeters,
  });

  final String name;
  final List<String> smallGroups;

  /// 服务器时间，教会时区的 HH:mm。
  final String time;

  /// 准时（true）或迟到（false）。
  final bool onTime;

  /// 打卡时离教堂的距离，读不到时为 null。
  final int? distanceMeters;

  factory AttendanceRow.fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    final time = json['time'];
    final status = json['status'];
    final groups = json['smallGroups'];
    final distance = json['distanceMeters'];
    if (name is! String || time is! String) {
      throw const FormatException('attendance row');
    }
    return AttendanceRow(
      name: name,
      smallGroups: groups is List ? groups.whereType<String>().toList() : const [],
      time: time,
      onTime: status == 'onTime',
      distanceMeters: distance is num ? distance.round() : null,
    );
  }
}

/// 一天的出勤：日期、名单和人数。
class AttendanceDay {
  const AttendanceDay({
    required this.date,
    required this.rows,
    required this.total,
    required this.onTime,
  });

  final String date;
  final List<AttendanceRow> rows;
  final int total;
  final int onTime;

  int get late => total - onTime;

  factory AttendanceDay.fromJson(Map<String, dynamic> json) {
    final date = json['date'];
    final records = json['records'];
    final counts = json['counts'];
    if (date is! String || records is! List || counts is! Map) {
      throw const FormatException('attendance day');
    }
    final total = counts['total'];
    final onTime = counts['onTime'];
    return AttendanceDay(
      date: date,
      rows: [
        for (final row in records)
          if (row is Map<String, dynamic>) AttendanceRow.fromJson(row),
      ],
      total: total is num ? total.round() : records.length,
      onTime: onTime is num ? onTime.round() : 0,
    );
  }
}

/// 出勤读取失败，message 直接显示给使用者。
class AttendanceException implements Exception {
  const AttendanceException(this.message);

  final String message;

  @override
  String toString() => message;
}
