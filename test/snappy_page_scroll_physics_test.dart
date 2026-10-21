import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:church_staff_pwa/core/utils/snappy_page_scroll_physics.dart';

/// 服事表左右滑换分页之后，如果马上想往下滑，手势会被 TabBarView 吃掉 ——
/// 那是 Flutter 既定的「接住滑行中的分页」行为，关不掉，只能缩短窗口。
/// 这组测试把窗口大小钉住，避免有人改回慢的 physics 而没人发现。
Widget _app(ScrollPhysics? physics) => MaterialApp(
  home: DefaultTabController(
    length: 3,
    child: Scaffold(
      appBar: AppBar(
        bottom: const TabBar(
          tabs: [
            Tab(text: 'A'),
            Tab(text: 'B'),
            Tab(text: 'C'),
          ],
        ),
      ),
      body: TabBarView(
        physics: physics,
        children: [
          for (var tab = 0; tab < 3; tab++)
            ListView.builder(
              key: ValueKey('list$tab'),
              itemExtent: 100,
              itemCount: 100,
              itemBuilder: (context, i) => Text('tab$tab item$i'),
            ),
        ],
      ),
    ),
  ),
);

/// 甩一页之后要几帧才完全静止 —— 这段时间内垂直手势都会被吃掉。
Future<int> _framesToSettle(WidgetTester tester, ScrollPhysics? physics) async {
  await tester.pumpWidget(_app(physics));
  await tester.pumpAndSettle();
  await tester.fling(find.byType(TabBarView), const Offset(-400, 0), 1200);
  return tester.pumpAndSettle();
}

/// TabBarView 内部叠在使用者 physics 之上的那一份。
ScrollPhysics _asTabBarViewWouldCompose(ScrollPhysics physics) =>
    const PageScrollPhysics()
        .applyTo(
          const ClampingScrollPhysics(parent: RangeMaintainingScrollPhysics()),
        )
        .applyTo(physics);

void main() {
  test('spring 会沿著 TabBarView 叠上去的 physics 链传上来', () {
    // TabBarView 拿自己的分页 physics 去 applyTo 我们这一份，我们只是 parent。
    // 中间任何一环把 spring 拦下来，手感就悄悄退回慢的，画面上看不出来。
    const snappy = SnappyPageScrollPhysics();
    final composed = _asTabBarViewWouldCompose(snappy);

    expect(composed.spring.mass, snappy.spring.mass);
    expect(composed.spring.stiffness, snappy.spring.stiffness);
    expect(composed.spring.damping, snappy.spring.damping);

    // 对照组：少了我们这份 parent 就是框架预设的 spring。
    expect(
      _asTabBarViewWouldCompose(const ScrollPhysics()).spring.stiffness,
      isNot(snappy.spring.stiffness),
    );

    // applyTo 必须回传自己的型别。TabBarView 这条路径上我们是链尾、不会被
    // 呼叫到，但只要有人把它当成中间一环（巢状 Scrollable、ScrollBehavior），
    // 少了这个覆写就会退化成一份普通 ScrollPhysics，spring 一起不见。
    expect(
      const SnappyPageScrollPhysics().applyTo(const ClampingScrollPhysics()),
      isA<SnappyPageScrollPhysics>(),
    );
  });

  test('链尾换掉 AlwaysScrollableScrollPhysics 之后，是否接受手势跟框架预设一致', () {
    // 这份 physics 取代了原本挂在 TabBarView 上的 AlwaysScrollableScrollPhysics。
    // 那一份会无条件接受手势；换掉之后判断交还给框架预设，两种情况都要对：
    // 多页时照样能滑，只有一页时不接受（本来就没地方可去）。
    final physics = _asTabBarViewWouldCompose(const SnappyPageScrollPhysics());
    ScrollMetrics pages(int count) => FixedScrollMetrics(
      minScrollExtent: 0,
      maxScrollExtent: 800.0 * (count - 1),
      pixels: 0,
      viewportDimension: 800,
      axisDirection: AxisDirection.right,
      devicePixelRatio: 1,
    );

    expect(physics.shouldAcceptUserOffset(pages(3)), isTrue);
    expect(physics.shouldAcceptUserOffset(pages(1)), isFalse);
    // 与框架预设（没传 physics 的 TabBarView）逐字相同，没有偷偷改行为。
    final frameworkDefault = _asTabBarViewWouldCompose(const ScrollPhysics());
    expect(
      physics.shouldAcceptUserOffset(pages(1)),
      frameworkDefault.shouldAcceptUserOffset(pages(1)),
    );
  });

  testWidgets('比预设 physics 更快静止', (tester) async {
    final snappy = await _framesToSettle(
      tester,
      const SnappyPageScrollPhysics(),
    );
    final defaultPhysics = await _framesToSettle(tester, null);

    expect(snappy, lessThan(defaultPhysics), reason: '收尾越久，换分页后手势没反应的时间就越长');
    // 量到的是 6 帧 vs 11 帧；留点余裕避免 Flutter 版本微调就坏掉。
    expect(snappy, lessThanOrEqualTo(8));
  });

  testWidgets('分页吸附感还在：甩一下就是换一页，不会停在中间', (tester) async {
    await tester.pumpWidget(_app(const SnappyPageScrollPhysics()));
    await tester.pumpAndSettle();
    expect(find.text('tab0 item0'), findsOneWidget);

    await tester.fling(find.byType(TabBarView), const Offset(-400, 0), 1200);
    await tester.pumpAndSettle();

    expect(find.text('tab1 item0'), findsOneWidget);
    expect(find.text('tab0 item0'), findsNothing);
  });

  testWidgets('静止之后垂直卷动正常', (tester) async {
    await tester.pumpWidget(_app(const SnappyPageScrollPhysics()));
    await tester.pumpAndSettle();
    await tester.fling(find.byType(TabBarView), const Offset(-400, 0), 1200);
    await tester.pumpAndSettle();

    final listFinder = find.descendant(
      of: find.byKey(const ValueKey('list1')),
      matching: find.byType(Scrollable),
    );
    final before = tester.state<ScrollableState>(listFinder).position.pixels;
    await tester.drag(listFinder, const Offset(0, -300));
    await tester.pump();

    expect(
      tester.state<ScrollableState>(listFinder).position.pixels,
      greaterThan(before),
    );
    await tester.pumpAndSettle();
  });
}
