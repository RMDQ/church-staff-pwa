import 'package:flutter/widgets.dart';

/// 让 [TextEditingController] 的生命周期绑在它所在的子树上。
///
/// `showDialog` / `showModalBottomSheet` 回传的 future 在 `Navigator.pop` 当下
/// 就同步完成，但退场动画还要再跑约 250 ms，这段期间 `TextField` 仍挂在树上。
/// 若在 future 完成后（例如 `finally` 里）马上 dispose controller，之后 route
/// 的 focus scope 拆除时 `EditableText._handleFocusChanged` 会写入已经 dispose
/// 的 controller，触发
/// `A TextEditingController was used after being disposed`，debug build 直接红屏。
///
/// 把 controller 交给这个 widget，dispose 就会发生在子树真的被卸载之后 ——
/// 也就是动画结束、TextField 已经离开树的时候。
class TextControllerScope extends StatefulWidget {
  const TextControllerScope({
    super.key,
    required this.controller,
    required this.child,
  });

  final TextEditingController controller;
  final Widget child;

  @override
  State<TextControllerScope> createState() => _TextControllerScopeState();
}

class _TextControllerScopeState extends State<TextControllerScope> {
  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
