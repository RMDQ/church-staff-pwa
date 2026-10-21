import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../domain/checkin_models.dart';

/// 浏览器定位。使用高精度；超过 10 秒就放弃，不要让按钮一直转。
Future<CheckinPosition> currentPosition() {
  final completer = Completer<CheckinPosition>();
  web.window.navigator.geolocation.getCurrentPosition(
    (web.GeolocationPosition position) {
      completer.complete(
        CheckinPosition(
          latitude: position.coords.latitude,
          longitude: position.coords.longitude,
        ),
      );
    }.toJS,
    (web.GeolocationPositionError error) {
      completer.completeError(const CheckinException('无法取得位置，请允许浏览器使用定位后再试'));
    }.toJS,
    web.PositionOptions(
      enableHighAccuracy: true,
      timeout: 10000,
      maximumAge: 0,
    ),
  );
  return completer.future;
}
