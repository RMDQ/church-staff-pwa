import '../domain/checkin_models.dart';
import 'checkin_location_stub.dart'
    if (dart.library.html) 'checkin_location_web.dart'
    as impl;

/// 取得手机目前的位置。拒绝授权、无法定位时抛出 [CheckinException]。
Future<CheckinPosition> currentCheckinPosition() => impl.currentPosition();
