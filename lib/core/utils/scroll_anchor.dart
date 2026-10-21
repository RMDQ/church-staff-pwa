import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

/// 「画面顶端是哪一张卡片、离顶端多远」的一笔纪录。
///
/// 为什么不能只记 `position.pixels`：检视与编辑是两份高度不同的清单（编辑多了
/// 汇入卡、每列多了两颗 48px 的按钮、展开的卡片因此高上一截），同一个 offset
/// 在两边指到的是不同的日期。记「哪一天」才换得回原本在看的地方，
/// [pixels] 只当还原时的第一次粗估。
@immutable
class ScrollAnchor {
  const ScrollAnchor({
    required this.itemId,
    required this.dy,
    required this.pixels,
  });

  /// 顶端那张卡片的 id。
  final String itemId;

  /// 该卡片左上角相对清单顶端的位移。卡片被切掉上缘时为负值。
  final double dy;

  /// 当下的卷动位置。还原时先跳到这里，让目标卡片被 build 出来。
  final double pixels;
}

/// 挂在清单每个项目上的标记，让 [ScrollAnchorSupport] 认得出这是哪一张卡片。
@immutable
class ScrollAnchorTag {
  const ScrollAnchorTag(this.id);
  final String id;
}

/// 包住清单项目，替它挂上 [ScrollAnchorTag]。
class ScrollAnchorItem extends StatelessWidget {
  const ScrollAnchorItem({super.key, required this.id, required this.child});

  final String id;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MetaData(metaData: ScrollAnchorTag(id), child: child);
  }
}

/// 让一个卷动清单记得住、也还原得回「顶端那张卡片的位置」。
///
/// 用法：把 [anchorListKey] 放到 ListView 上、[anchorController] 当它的
/// controller、每个项目用 [ScrollAnchorItem] 包起来，切换画面前呼叫
/// [captureScrollAnchor] 存起来，新画面挂好后呼叫 [restoreScrollAnchor]。
mixin ScrollAnchorSupport<T extends StatefulWidget> on State<T> {
  final GlobalKey anchorListKey = GlobalKey();
  final ScrollController anchorController = ScrollController();

  @override
  void dispose() {
    anchorController.dispose();
    super.dispose();
  }

  /// 记下目前顶端的卡片。清单还没挂上或看不到任何卡片时回传 null。
  ScrollAnchor? captureScrollAnchor() {
    if (!anchorController.hasClients) return null;
    final entries = _visibleItems();
    if (entries.isEmpty) return null;
    // 「顶端那张」＝ 还没被卷出画面的第一张：下缘仍在 0 以下的都不算。
    _AnchorHit? best;
    for (final entry in entries) {
      if (entry.dy + entry.height <= 0) continue;
      if (best == null || entry.dy < best.dy) best = entry;
    }
    best ??= entries.first;
    return ScrollAnchor(
      itemId: best.id,
      dy: best.dy,
      pixels: anchorController.position.pixels,
    );
  }

  /// 把 [anchor] 那张卡片挪回原本的位置。
  ///
  /// 清单是 lazy build 的，目标卡片一开始可能根本不在树上，所以先用当初的
  /// pixel 位置粗估一次，等它被 build 出来再依实际位移修正。收合的卡片两个
  /// 模式一样高，粗估通常只差一两张卡片，修正一次就到位。
  Future<void> restoreScrollAnchor(ScrollAnchor anchor) async {
    // 本来就停在最上面的话什么都不用做 —— 硬把第一张卡片拉回同一个 y，只会
    // 把清单顶端新增的东西（编辑模式的汇入卡）推到看不见的地方。
    if (anchor.pixels <= 0.5) return;
    for (var attempt = 0; attempt < 4; attempt++) {
      if (!mounted) return;
      if (!anchorController.hasClients) {
        // endOfFrame 只在 idle 时自己排一帧，而第一轮是在 post-frame callback
        // 里跑的 —— 不主动排一帧的话，这个 await 会等到某个无关的重绘才醒，
        // 还原就静静地没发生。
        SchedulerBinding.instance.ensureVisualUpdate();
        await SchedulerBinding.instance.endOfFrame;
        continue;
      }
      final hit = _findItem(anchor.itemId);
      if (hit == null) {
        // 还没被 build 出来：先跳到当初的位置，下一轮再修正。跳不动（已经在
        // 边界上）也不能就此收工 —— 卡片可能下一帧才被 build 出来。
        _jumpTo(anchor.pixels);
        SchedulerBinding.instance.ensureVisualUpdate();
      } else {
        final delta = hit.dy - anchor.dy;
        if (delta.abs() < 0.5) return;
        if (!_jumpTo(anchorController.position.pixels + delta)) return;
      }
      await SchedulerBinding.instance.endOfFrame;
    }
  }

  /// 回传 false 代表已经在边界上，再跳也不会动 —— 呼叫端就可以收工，
  /// 不必空转剩下的重试次数。
  bool _jumpTo(double target) {
    final position = anchorController.position;
    final clamped = target.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((clamped - position.pixels).abs() < 0.5) return false;
    anchorController.jumpTo(clamped);
    return true;
  }

  _AnchorHit? _findItem(String id) {
    for (final entry in _visibleItems()) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  /// 扫出目前这一帧真的存在于树上的项目。ListView 只 build 看得到的那几张，
  /// 所以这里走访的是十几个 render object，不是整份服事表。
  List<_AnchorHit> _visibleItems() {
    final listRender = anchorListKey.currentContext?.findRenderObject();
    if (listRender is! RenderBox || !listRender.hasSize) return const [];

    final hits = <_AnchorHit>[];
    void visit(RenderObject node) {
      if (node is RenderMetaData) {
        final tag = node.metaData;
        if (tag is ScrollAnchorTag) {
          if (node.hasSize && node.attached) {
            hits.add(
              _AnchorHit(
                id: tag.id,
                dy: node.localToGlobal(Offset.zero, ancestor: listRender).dy,
                height: node.size.height,
              ),
            );
          }
          // 标记底下不会再有另一张卡片，不必再往下走。
          return;
        }
      }
      node.visitChildren(visit);
    }

    listRender.visitChildren(visit);
    return hits;
  }
}

class _AnchorHit {
  const _AnchorHit({required this.id, required this.dy, required this.height});
  final String id;
  final double dy;
  final double height;
}
