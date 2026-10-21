import 'roster_photo.dart';

const bool canPickRosterPhotos = false;

Future<RosterPhoto?> pickRosterPhoto() async {
  // 走不到这里 —— canPickRosterPhotos 是 false，UI 不会画那颗按钮。
  throw const RosterPhotoException('这个版本不支援直接选照片');
}
