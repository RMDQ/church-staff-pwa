import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import 'roster_photo.dart';

const bool canPickRosterPhotos = true;

/// 开一个档案选择器拿一张服事表照片。
///
/// 没有用 image_picker 之类的套件：这是 PWA，`<input type="file">` 在手机上
/// 本来就会跳出「相机／相簿」，多一个相依只是多一层。
Future<RosterPhoto?> pickRosterPhoto() async {
  final input = web.HTMLInputElement()
    ..type = 'file'
    // accept 用 image/* 而不是列副档名：手机相机拍出来的可能是 HEIC，
    // 列举一定会漏。真正的把关在 worker 那边。
    ..accept = 'image/*';
  // 一定要挂进 DOM。没挂上去的 input 在手机浏览器（iOS Safari、Android 开
  // 相机时）常常不发 change，或在使用者选照片的期间就被回收 —— 症状是选完
  // 照片什么都没发生，没有错误也没有转圈。
  input.style
    ..position = 'fixed'
    ..left = '-10000px'
    ..opacity = '0';
  web.document.body?.append(input);

  final completer = Completer<RosterPhoto?>();

  input.onchange = (web.Event _) {
    if (completer.isCompleted) return;
    final file = input.files?.item(0);
    completer.complete(file == null ? null : readRosterPhoto(file));
  }.toJS;

  // 使用者按取消时浏览器只会发 cancel，不会发 change。没有接这个事件的话
  // 那个 future 永远不会完成，而画面上的转圈也就永远停不下来。
  input.addEventListener(
    'cancel',
    (web.Event _) {
      if (!completer.isCompleted) completer.complete(null);
    }.toJS,
  );

  input.click();
  try {
    return await completer.future;
  } finally {
    input.remove();
  }
}

/// 照片在手机上先缩成长边这么多 px 再送出。
///
/// 不缩的话，一张 iPhone 照片是 3-5MB，base64 之后 worker 光是把请求解析再
/// 组给 Gemini 就要十几 ms CPU —— 超过 Cloudflare 免费方案每个请求 10ms 的
/// 上限，Cloudflare 直接回 503，画面上变成「辨识服务忙碌中」，看起来像是
/// Gemini 的问题。实际踩过。
///
/// 2400 是依实测挑的：验证过的服事表截图最大 1755px，全部辨识正确，留一点
/// 余裕给手机拍的斜角与边框。Gemini 自己也会把图缩到差不多这个尺度，送更大
/// 只是多花上传时间。
const int _maxEdge = 2400;

/// JPEG 品质。表格是细字，0.85 以下开始糊。
const double _jpegQuality = 0.85;

/// 原图大到这样就不读了：解码一张的记忆体是长×宽×4，手机分页会被系统砍掉。
const int _maxSourceBytes = 40 * 1024 * 1024;

/// 读一张照片、缩小、转成 JPEG。
///
/// 公开只是为了 test/roster_photo_picker_web_test.dart —— 这段只有真的浏览器
/// 跑得动（canvas、影像解码），VM 上的测试碰不到。
@visibleForTesting
Future<RosterPhoto> readRosterPhoto(web.File file) async {
  if (file.size > _maxSourceBytes) {
    throw RosterPhotoException('${file.name} 太大了，请换一张照片');
  }

  final url = web.URL.createObjectURL(file);
  try {
    final image = web.HTMLImageElement()..src = url;
    try {
      await image.decode().toDart;
    } catch (_) {
      throw RosterPhotoException('${file.name} 打不开，请换一张照片');
    }

    final width = image.naturalWidth;
    final height = image.naturalHeight;
    final scale = math.min(1.0, _maxEdge / math.max(width, height));
    final canvas = web.HTMLCanvasElement()
      ..width = (width * scale).round()
      ..height = (height * scale).round();
    // 浏览器画进 canvas 时会照 EXIF 转正，直拍的照片不会躺著送出去。
    (canvas.getContext('2d') as web.CanvasRenderingContext2D).drawImage(
      image,
      0,
      0,
      canvas.width,
      canvas.height,
    );

    // 一律转成 JPEG：iPhone 的 HEIC 也在这里变成 worker 与 Gemini 都认得的格式。
    final bytes = await _encodeJpeg(canvas);
    if (bytes.length > maxRosterPhotoBytes) {
      throw RosterPhotoException('${file.name} 缩小后还是太大，请裁掉表格以外的部分');
    }
    return RosterPhoto(mimeType: 'image/jpeg', data: base64Encode(bytes));
  } finally {
    web.URL.revokeObjectURL(url);
  }
}

Future<Uint8List> _encodeJpeg(web.HTMLCanvasElement canvas) async {
  final completer = Completer<web.Blob?>();
  canvas.toBlob(
    (web.Blob? blob) {
      completer.complete(blob);
    }.toJS,
    'image/jpeg',
    _jpegQuality.toJS,
  );
  final blob = await completer.future;
  if (blob == null) {
    // iOS 对 canvas 有像素上限，超过时 toBlob 给 null 而不是丢错。
    throw const RosterPhotoException('照片转档失败，请换一张照片');
  }
  final buffer = await blob.arrayBuffer().toDart;
  return buffer.toDart.asUint8List();
}
