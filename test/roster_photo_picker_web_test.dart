@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

import 'package:church_staff_pwa/features/roster/data/roster_photo.dart';
import 'package:church_staff_pwa/features/roster/data/roster_photo_picker_web.dart';

/// 在浏览器里画一张指定大小的图，包成使用者选到的那种 File。
Future<web.File> _photo(
  int width,
  int height, {
  String type = 'image/png',
}) async {
  final canvas = web.HTMLCanvasElement()
    ..width = width
    ..height = height;
  final context = canvas.getContext('2d') as web.CanvasRenderingContext2D
    ..fillStyle = '#ffffff'.toJS;
  context.fillRect(0, 0, width, height);
  context.fillStyle = '#000000'.toJS;
  context.fillRect(width / 4, height / 4, width / 2, height / 2);

  final blob = await _toBlob(canvas, type);
  return web.File([blob].toJS, 'roster.png', web.FilePropertyBag(type: type));
}

Future<web.Blob> _toBlob(web.HTMLCanvasElement canvas, String type) {
  final completer = Completer<web.Blob>();
  canvas.toBlob(((web.Blob? blob) => completer.complete(blob!)).toJS, type);
  return completer.future;
}

/// 把送出去的 base64 解回图，量它的尺寸。
Future<(int, int)> _size(RosterPhoto photo) async {
  final image = web.HTMLImageElement()
    ..src = 'data:${photo.mimeType};base64,${photo.data}';
  await image.decode().toDart;
  return (image.naturalWidth, image.naturalHeight);
}

void main() {
  test('手机照片大小的图缩到长边 2400，转成 JPEG', () async {
    // iPhone 主镜头的原始尺寸。
    final photo = await readRosterPhoto(await _photo(4032, 3024));

    expect(photo.mimeType, 'image/jpeg');
    expect(await _size(photo), (2400, 1800));
    expect(base64Decode(photo.data).length, lessThan(maxRosterPhotoBytes));
  });

  test('直拍的照片缩的是高', () async {
    final photo = await readRosterPhoto(await _photo(3024, 4032));
    expect(await _size(photo), (1800, 2400));
  });

  test('本来就小的截图不放大', () async {
    final photo = await readRosterPhoto(await _photo(1206, 848));
    expect(photo.mimeType, 'image/jpeg');
    expect(await _size(photo), (1206, 848));
  });

  test('不是图的档案给看得懂的错误', () async {
    final file = web.File(
      ['not an image'.toJS].toJS,
      'notes.txt',
      web.FilePropertyBag(type: 'image/jpeg'),
    );
    await expectLater(
      readRosterPhoto(file),
      throwsA(isA<RosterPhotoException>()),
    );
  });
}
