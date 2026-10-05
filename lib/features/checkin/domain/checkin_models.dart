/// 一次打卡的结果，由服务器决定，App 只负责显示。
class CheckinResult {
  const CheckinResult({
    required this.onTime,
    required this.time,
    required this.distanceMeters,
  });

  /// 服务器给的状态：准时（onTime）或迟到（late）。
  final bool onTime;

  /// 服务器时间，教会时区的 HH:mm。
  final String time;

  /// 离教堂大约多少米。
  final int distanceMeters;

  factory CheckinResult.fromJson(Map<String, dynamic> json) {
    final status = json['status'];
    final time = json['time'];
    final distance = json['distanceMeters'];
    if (status is! String || time is! String || distance is! num) {
      throw const FormatException('checkin response');
    }
    return CheckinResult(
      onTime: status == 'onTime',
      time: time,
      distanceMeters: distance.round(),
    );
  }
}

/// 手机报告的位置。只用来发给服务器判断，App 不做任何判断。
class CheckinPosition {
  const CheckinPosition({required this.latitude, required this.longitude});

  final double latitude;
  final double longitude;
}

/// 打卡失败。message 直接显示给使用者，所以写成可以照着做的话。
class CheckinException implements Exception {
  const CheckinException(this.message);

  final String message;

  @override
  String toString() => message;
}
