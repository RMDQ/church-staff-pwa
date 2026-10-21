import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/roster_import_service.dart';

/// 照片辨识进行中，按钮底下那一行「现在在干嘛」。
///
/// 辨识是一个请求送出去、一分钟后才回来，中间 app 什么都不知道 —— worker 在
/// 重试也不会告诉我们。所以这里说的只有两件确定的事：已经等了多久，以及照
/// 过去的量测，这个时间算不算正常。只有一颗转圈的话，等到第 90 秒的人分不出
/// 是卡住了还是快好了，就会关掉重来，把当天的免费额度又烧掉一次。
///
/// 计时自己管：出现在画面上就开始，拿掉就停。呼叫端只要决定画不画它。
class PhotoImportProgress extends StatefulWidget {
  const PhotoImportProgress({super.key});

  @override
  State<PhotoImportProgress> createState() => _PhotoImportProgressState();
}

class _PhotoImportProgressState extends State<PhotoImportProgress> {
  final Stopwatch _stopwatch = Stopwatch()..start();
  late final Timer _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      photoImportProgressText(_stopwatch.elapsed),
      key: const ValueKey('photo-import-progress'),
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: 12,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// 抽出来是为了测：文字只跟经过的时间有关。
String photoImportProgressText(Duration elapsed) {
  final seconds = elapsed.inSeconds;
  if (elapsed < RosterImportService.usualDuration) {
    return '正在读照片，已经 $seconds 秒\n'
        '通常要一分钟左右；服务忙碌时伺服器会自动重试';
  }
  final remaining = (RosterImportService.timeout - elapsed).inSeconds;
  if (remaining <= 0) return '快要逾时了，已经 $seconds 秒';
  return '比平常久，仍在等待辨识结果\n'
      '已经 $seconds 秒，最多再等 $remaining 秒';
}
