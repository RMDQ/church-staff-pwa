import 'package:flutter/foundation.dart';

/// 一张要送去辨识的服事表照片。
///
/// [data] 已经是 base64，因为它唯一的去处就是 JSON 请求的 body。存 bytes 再
/// 在送出前转一次，等于在手机上把同一份资料多留一份在记忆体里。
@immutable
class RosterPhoto {
  final String mimeType;
  final String data;

  const RosterPhoto({required this.mimeType, required this.data});

  Map<String, dynamic> toJson() => {'mimeType': mimeType, 'data': data};
}

/// 选照片时使用者看得懂、也能处理的失败。
class RosterPhotoException implements Exception {
  final String message;
  const RosterPhotoException(this.message);

  @override
  String toString() => message;
}

/// 缩小、转成 JPEG 之后的单张上限，跟 worker 的 MAX_IMAGE_BYTES 一致。
///
/// 会这么小是因为 Cloudflare 免费方案每个请求只有 10ms CPU，照片越大 worker
/// 解析越久，超过就被 Cloudflare 砍掉（详见 import-image.js）。长边 2400px
/// 的 JPEG 一般不到 1MB，碰到这条线的只会是细节多到异常的照片。
const int maxRosterPhotoBytes = 2 * 1024 * 1024;
