import 'package:flutter/widgets.dart';

/// 让分页切换的收尾动画更快停下来的 [ScrollPhysics]。
///
/// 解决的问题：在服事表左右滑换分页之后，如果马上想往下滑，手势常常没有反应。
///
/// 成因是 Flutter 的既定行为，不是 bug：分页还在滑行时把手指放上去，父层的
/// [Scrollable] 会「接住」那个动画（让你能中途抓住一页），于是指标被父层拿走，
/// 底下清单的垂直手势就收不到了。实测（widget test，在画面中央模拟手指往下
/// 拖）：动画途中两页的卷动位置都是 0 → 0，完全静止之后同样的手势移动 270。
///
/// 这个接住的行为没有办法关掉，能做的是**缩短窗口**。收尾动画的时间由 spring
/// 决定，换一组更硬、临界阻尼（ratio > 1，不回弹）的 spring 之后，实测从
/// 甩动到完全静止由 11 帧（约 176ms）降到 6 帧（约 96ms）。
///
/// 用法是把它当成 `TabBarView.physics` 传进去。TabBarView 会用自己的分页
/// physics 去 `applyTo` 我们这一份，把我们变成 parent；而分页 physics 产生
/// 收尾动画时取的 `spring` 会沿著 parent 链找上来，所以吸附感保留，只有速度
/// 变了。
class SnappyPageScrollPhysics extends ScrollPhysics {
  const SnappyPageScrollPhysics({super.parent});

  @override
  SnappyPageScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      SnappyPageScrollPhysics(parent: buildParent(ancestor));

  @override
  SpringDescription get spring => SpringDescription.withDampingRatio(
    mass: 0.4,
    stiffness: 400,
    // 略大于 1：临界阻尼再多一点，收得干脆且不会过冲。
    ratio: 1.1,
  );
}
