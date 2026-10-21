import 'roster_photo.dart';
import 'roster_photo_picker_stub.dart'
    if (dart.library.html) 'roster_photo_picker_web.dart'
    as impl;

/// 这个平台能不能直接选照片。
///
/// 只有网页版能 —— app 本来就是 PWA，但非 web 的建置照样要编得过，而给一颗
/// 按下去必定失败的按钮比不给还糟。UI 靠这个决定要不要画那颗按钮。
bool get canPickRosterPhotos => impl.canPickRosterPhotos;

/// 开启档案选择器选一张照片。使用者取消就回 null，不是丢例外 —— 取消不是错误。
Future<RosterPhoto?> pickRosterPhoto() => impl.pickRosterPhoto();
