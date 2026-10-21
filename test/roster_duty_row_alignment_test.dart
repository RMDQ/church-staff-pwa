import 'package:church_staff_pwa/core/types/service_type.dart';
import 'package:church_staff_pwa/features/roster/domain/entities/service_roster.dart';
import 'package:church_staff_pwa/features/roster/presentation/providers/roster_provider.dart';
import 'package:church_staff_pwa/features/roster/presentation/widgets/duty_row.dart';
import 'package:church_staff_pwa/features/roster/presentation/widgets/roster_card.dart';
import 'package:church_staff_pwa/features/roster/presentation/widgets/roster_view_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';

import 'support/in_memory_roster_repository.dart';

/// 服事列在两个模式各自该有的高度。
///
/// 编辑模式撑到 48（删除钮的触控目标，给长辈按的，不能缩）；检视模式没有按
/// 钮，列高跟著文字走 —— 这个画面是拿来读的，一页看得到几天比每列多 25px 留
/// 白重要。切换模式的位移是靠锚定日期修的（见 roster_scroll_anchor_test），
/// 不靠两边列高一样。

ServiceRoster _roster() => ServiceRoster(
  id: 'r1',
  date: DateTime(2026, 1, 4),
  type: ServiceType.sundayService,
  serviceName: '主日崇拜',
  duties: [
    RosterEntry(role: '敬拜主领', people: const ['美玉']),
    RosterEntry(role: '司琴', people: const ['王小明', '李大华']),
    RosterEntry(role: '招待', people: const ['王小明', '李大华', '陈美丽']),
    RosterEntry(role: '音控', people: const ['王小明', '李大华', '陈美丽', '张志豪']),
  ],
);

/// 挂一张卡片，回传每一列服事的高度。
Future<List<double>> _rowHeights(
  WidgetTester tester, {
  required bool editMode,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final provider = RosterProvider(InMemoryRosterRepository());
  if (editMode) provider.toggleEditMode();

  await tester.pumpWidget(
    ChangeNotifierProvider<RosterProvider>.value(
      value: provider,
      child: MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              if (editMode)
                RosterCard(roster: _roster(), initiallyExpanded: true)
              else
                RosterViewCard(
                  roster: _roster(),
                  initiallyExpanded: true,
                  resolveEventColor: (_, _) => 0xFF000000,
                ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  return tester
      .widgetList<DutyRow>(find.byType(DutyRow))
      .map((row) => tester.getSize(find.byWidget(row)).height)
      .toList();
}

/// 挂一张卡片，回传某一个服事项目那一列「人名栏」的实际尺寸。
///
/// 人名不再是一整个 Text（见 [DutyRow]：一个名字一段，才不会从名字中间断
/// 行），所以量的是包住那些段落的 Wrap。
Future<Size> _peopleColumnSize(
  WidgetTester tester, {
  required bool editMode,
  required String role,
}) async {
  await _rowHeights(tester, editMode: editMode);
  return tester.getSize(
    find.descendant(
      of: find.byWidgetPredicate((w) => w is DutyRow && w.role == role),
      matching: find.byType(Wrap),
    ),
  );
}

void main() {
  setUpAll(() async => initializeDateFormatting('zh_TW'));

  testWidgets('编辑模式的服事列撑到按钮的触控目标', (tester) async {
    final editHeights = await _rowHeights(tester, editMode: true);

    expect(editHeights, hasLength(4));
    expect(
      editHeights.every((h) => h >= kDutyRowMinHeight),
      isTrue,
      reason: '列高低于 $kDutyRowMinHeight 的话删除钮就不好按了：$editHeights',
    );
  });

  testWidgets('检视模式的服事列跟著文字高度走', (tester) async {
    final viewHeights = await _rowHeights(tester, editMode: false);
    final editHeights = await _rowHeights(tester, editMode: true);

    expect(viewHeights, hasLength(4));
    // 前三列的名字都排得下一行，列高就该是一行文字的高度，不是 48。
    for (final height in viewHeights.take(3)) {
      expect(
        height,
        lessThan(kDutyRowMinHeight),
        reason: '检视模式又被撑高了（$viewHeights），一页看得到的天数会变少',
      );
    }
    // 第四列（音控，四个名字）会换行，本来就比一行高 —— 但仍不该吃到那个下限
    // 才叫「跟著文字走」。
    expect(viewHeights[3], lessThan(editHeights[3]));
  });

  // ⇄ 曾经直接挂在服事列上，名字栏因此只剩 142px，三个三字名字会被挤成两行。
  // 交换入口移进编辑视窗之后，名字栏拿回那 44px。
  testWidgets('三个名字在编辑模式也排得下一行', (tester) async {
    final viewSize = await _peopleColumnSize(
      tester,
      editMode: false,
      role: '招待',
    );
    final editSize = await _peopleColumnSize(
      tester,
      editMode: true,
      role: '招待',
    );

    // 只比对两边相等不够 —— 两边一起换行也会相等。拿单一名字那列当「一行」
    // 的基准，两边都必须是那个高度。
    final oneLine = await _peopleColumnSize(
      tester,
      editMode: true,
      role: '敬拜主领',
    );
    expect(
      editSize.height,
      oneLine.height,
      reason: '编辑模式的名字换行了：$editSize（一行应为 ${oneLine.height}）',
    );
    expect(
      viewSize.height,
      oneLine.height,
      reason: '检视模式的名字换行了：$viewSize（一行应为 ${oneLine.height}）',
    );
  });

  // 栏宽不够时中文预设会从任何一个字之间断开，「陈美丽」被切成「陈美／丽」。
  // 一个名字一段就只剩名字之间可以断。
  testWidgets('名字多到得换行时，不会从名字中间断开', (tester) async {
    await _rowHeights(tester, editMode: true);

    // 每个名字各自是一段（最后一个之外都带著顿号），所以不可能被切开。
    expect(find.text('王小明、'), findsWidgets);
    expect(find.text('李大华、'), findsWidgets);
    expect(find.text('陈美丽'), findsWidgets);

    final wide = await _peopleColumnSize(tester, editMode: true, role: '音控');
    final oneLine = await _peopleColumnSize(
      tester,
      editMode: true,
      role: '敬拜主领',
    );
    expect(
      wide.height,
      greaterThan(oneLine.height),
      reason: '四个名字在编辑模式的栏宽下本来就该换行，这条测试才有意义',
    );
  });
}
