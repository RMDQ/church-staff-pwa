import '../domain/checkin_models.dart';

/// 非网页的平台没有这个定位实现。
Future<CheckinPosition> currentPosition() =>
    Future.error(const CheckinException('这个平台暂不支持打卡定位'));
