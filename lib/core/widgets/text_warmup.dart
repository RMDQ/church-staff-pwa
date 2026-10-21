import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// 把清单将来会显示的字串，提前在画面外排版一次。
///
/// 为什么是「字串」而不是「字元」：Flutter Web 的文字排版有两层成本，而且
/// 两层都以字串为单位快取。
///
///   1. 字型 —— CanvasKit 内建字型没有中文。排版遇到缺字会去 gstatic 抓
///      Noto subset，抓回来之后再通知框架重排一次。
///   2. 断行与字元边界分析 —— 引擎的 segmentation cache 是以整个字串当 key
///      的（见 text_fragmenter.dart：短字串 10 万笔、中等字串 1 万笔），
///      同一个字串排版过第二次就便宜得多。
///
/// 只预热字元只解决第 1 层。实测（?bench=1）：同一批中文字串第一次卷是红
/// 的，换到另一个变体重卷同样的字串就变绿 —— 贵的是「第一次排版这个字串」，
/// 跟 widget 用 ListTile 还是手写 Row 几乎无关。
///
/// 分批进行：一次把几百个字串塞进同一帧会换来一次明显的顿挫，所以每帧只处
/// 理 [_chunkSize] 个，摊平在载入阶段。全部做完就把自己从树上移除 —— 常驻
/// 只会让每一帧白白多背这些 paragraph。
///
/// 必须放在 [Stack] 里：内容被放到可视范围外，而 Stack 预设会裁切，所以不
/// 会有实际的绘制成本，但 layout 一定会发生，这正是我们要的。
///
/// 对辅助科技完全隐形（[ExcludeSemantics]）：这些字只是拿来逼引擎排版的，
/// 使用者看不到也不该听到。少了这层，VoiceOver／TalkBack 会把整份名单的每
/// 个名字都念出来。
class TextWarmup extends StatefulWidget {
  const TextWarmup({super.key, required this.strings});

  /// 要预热的字串（会自行去重）。
  final List<String> strings;

  /// 每一帧处理几个字串。
  static const int _chunkSize = 24;

  /// 全部排版完之后，再等这么久才移除 —— 字型是非同步抓回来的，太早撤掉会
  /// 来不及触发字型变更后的重排。
  static const Duration _settleDuration = Duration(seconds: 4);

  /// 从任意来源取出不重复、非空白的字串。
  static List<String> uniqueStringsOf(Iterable<String> sources) {
    final seen = <String>{};
    final result = <String>[];
    for (final source in sources) {
      final trimmed = source.trim();
      if (trimmed.isEmpty) continue;
      if (seen.add(trimmed)) result.add(trimmed);
    }
    return result;
  }

  @override
  State<TextWarmup> createState() => _TextWarmupState();
}

class _TextWarmupState extends State<TextWarmup> {
  int _warmed = 0;
  bool _settled = false;
  bool _scheduled = false;
  Timer? _settleTimer;

  @override
  void initState() {
    super.initState();
    _scheduleNextChunk();
  }

  @override
  void didUpdateWidget(TextWarmup oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 资料换了（切换帐号、名单重抓）就重来一次。
    //
    // 不能只看 identity：呼叫端若在 build 里现算 List，每次 rebuild 都会是
    // 新 instance，光看 identity 会让预热永远从头来过 —— 那些 off-screen
    // paragraph 就再也撤不掉，每一帧都白排一次版。内容一样就当作没变。
    if (!identical(oldWidget.strings, widget.strings) &&
        !listEquals(oldWidget.strings, widget.strings)) {
      _settleTimer?.cancel();
      _warmed = 0;
      _settled = false;
      _scheduleNextChunk();
      return;
    }
    // identity 没变不代表内容没变：呼叫端就地改写并缩短清单时，_warmed 会
    // 停在界外。夹回长度内，让排程与 build 都在合法区间运作。
    if (_warmed > widget.strings.length) {
      _warmed = widget.strings.length;
    }
  }

  void _scheduleNextChunk() {
    if (_scheduled) return;
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;

      if (_warmed >= widget.strings.length) {
        // 全部排版完，等字型下载与重排落地之后把自己撤掉。
        _settleTimer?.cancel();
        _settleTimer = Timer(TextWarmup._settleDuration, () {
          if (mounted) setState(() => _settled = true);
        });
        return;
      }

      setState(() {
        _warmed = (_warmed + TextWarmup._chunkSize).clamp(
          0,
          widget.strings.length,
        );
      });
      _scheduleNextChunk();
    });
  }

  @override
  void dispose() {
    _settleTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_settled) return const SizedBox.shrink();

    // 只放「这一批」：已经排版过的字串留在树上没有意义，那些成本已经付过了。
    //
    // 结束点也要夹，不能只夹起点：清单被就地改短时 identity 不变，state 里
    // 的 _warmed 会超出长度，sublist 就会抛 RangeError。
    final total = widget.strings.length;
    final end = _warmed.clamp(0, total);
    final start = (end - TextWarmup._chunkSize).clamp(0, total);
    if (start == end) return const SizedBox.shrink();

    return Positioned(
      // 放在画面外。Stack 预设 Clip.hardEdge，所以不会真的被画出来。
      left: -100000,
      top: 0,
      child: ExcludeSemantics(
        child: IgnorePointer(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final text in widget.strings.sublist(start, end))
                Text(
                  text,
                  softWrap: false,
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  // segmentation cache 以字串为 key，跟字级无关，所以用小字级。
                  style: const TextStyle(fontSize: 8),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
