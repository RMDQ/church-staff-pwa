import 'package:church_staff_pwa/core/types/service_type.dart';
import 'package:church_staff_pwa/features/auth/domain/entities/user.dart';
import 'package:church_staff_pwa/features/auth/presentation/providers/session_provider.dart';
import 'package:church_staff_pwa/features/auth/presentation/providers/user_admin_provider.dart';
import 'package:church_staff_pwa/features/roster/domain/entities/service_roster.dart';
import 'package:church_staff_pwa/features/roster/presentation/providers/roster_provider.dart';
import 'package:church_staff_pwa/features/roster/presentation/screens/roster_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';

import 'support/in_memory_roster_repository.dart';
import 'support/signed_in_auth_repository.dart';

/// 快取与伺服器回同一份，样板只有主日。
InMemoryRosterRepository _repo(List<ServiceRoster> rosters) =>
    InMemoryRosterRepository(
      rosters: rosters,
      cachedRosters: rosters,
      templates: {
        ServiceType.sundayService: ['敬拜主领', '司琴', '招待'],
      },
    );

/// 切换检视／编辑模式时，画面要停在同一天。
///
/// 两份清单的高度本来就不一样（编辑模式多一张汇入卡、每列多两颗 48px 的按钮，
/// 展开的卡片因此高出一截），所以只保留 `position.pixels` 一定会对到别天 ——
/// 这组测试钉的就是「锚在日期上，不是锚在 pixel 上」。

const _kEditorUser = User(
  id: 'u1',
  name: '编辑者',
  email: 'a@b.c',
  username: 'editor',
  role: UserRole.admin,
  groups: {},
  zones: [],
);

List<ServiceRoster> _buildRosters(int count) => List.generate(
  count,
  (i) => ServiceRoster(
    id: 'r$i',
    date: DateTime(2026, 1, 4).add(Duration(days: 7 * i)),
    type: ServiceType.sundayService,
    serviceName: '主日崇拜',
    duties: [
      RosterEntry(role: '敬拜主领', people: const ['美玉']),
      RosterEntry(role: '司琴', people: const ['王小明', '李大华']),
      RosterEntry(role: '招待', people: const ['陈美丽']),
    ],
  ),
);

/// 挂好画面并等 session 还原完（理由同 permission_ui_test）。
Future<RosterProvider> _pumpRosterScreen(WidgetTester tester) async {
  final session = SessionProvider(SignedInAuthRepository(_kEditorUser));
  final rosters = RosterProvider(_repo(_buildRosters(24)));
  final users = UserAdminProvider(
    SignedInAuthRepository(_kEditorUser),
    session,
  );

  await tester.pumpWidget(
    ChangeNotifierProvider<SessionProvider>.value(
      value: session,
      child: const MaterialApp(home: SizedBox.shrink()),
    ),
  );
  await tester.pumpAndSettle();

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SessionProvider>.value(value: session),
        ChangeNotifierProvider<RosterProvider>.value(value: rosters),
        ChangeNotifierProvider<UserAdminProvider>.value(value: users),
      ],
      child: const MaterialApp(home: RosterScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return rosters;
}

/// 目前画面上，指定卡片的上缘落在哪里（萤幕座标）。找不到代表它根本没被
/// build 出来 —— 那本身就是「位置跑掉了」。
double _topOf(WidgetTester tester, String rosterId) {
  final finder = find.byKey(ValueKey(rosterId));
  expect(finder, findsOneWidget, reason: '$rosterId 不在画面上');
  return tester.getTopLeft(finder).dy;
}

/// 目前停在顶端的是哪一张卡片。
String _topmostId(WidgetTester tester, int count) {
  var bestId = '';
  var bestDy = double.negativeInfinity;
  for (var i = 0; i < count; i++) {
    final finder = find.byKey(ValueKey('r$i'));
    if (finder.evaluate().isEmpty) continue;
    final box = tester.getRect(finder);
    if (box.bottom <= 0) continue;
    if (bestDy == double.negativeInfinity || box.top < bestDy) {
      bestDy = box.top;
      bestId = 'r$i';
    }
  }
  return bestId;
}

void main() {
  setUpAll(() async => initializeDateFormatting('zh_TW'));

  testWidgets('切到编辑模式后，原本停在顶端的那一天还在同一个位置', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pumpRosterScreen(tester);

    // 卷到中段，让「顶端那张」不是第一张。
    await tester.drag(find.byType(ListView), const Offset(0, -700));
    await tester.pumpAndSettle();

    final anchorId = _topmostId(tester, 24);
    expect(anchorId, isNot(''), reason: '卷完之后画面上应该还有卡片');
    final before = _topOf(tester, anchorId);

    await tester.tap(find.byTooltip('切换至编辑模式'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('切换至检视模式'), findsOneWidget, reason: '应该已经在编辑模式');
    expect(
      _topOf(tester, anchorId),
      closeTo(before, 1.0),
      reason: '切进编辑模式后，同一天应该停在同一个位置',
    );
  });

  testWidgets('切回检视模式后也回到同一天', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pumpRosterScreen(tester);

    await tester.tap(find.byTooltip('切换至编辑模式'));
    await tester.pumpAndSettle();

    // 在编辑模式里卷动，再切回检视。
    await tester.drag(find.byType(ListView), const Offset(0, -900));
    await tester.pumpAndSettle();

    final anchorId = _topmostId(tester, 24);
    final before = _topOf(tester, anchorId);

    await tester.tap(find.byTooltip('切换至检视模式'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('切换至编辑模式'), findsOneWidget, reason: '应该已经回到检视模式');
    expect(
      _topOf(tester, anchorId),
      closeTo(before, 1.0),
      reason: '切回检视模式后，同一天应该停在同一个位置',
    );
  });

  // 停在最上面时刻意不锚定：把第一张卡片拉回同一个 y，等于把编辑模式顶端的
  // 汇入卡推到画面外，那颗功能就没人找得到了。
  testWidgets('本来就在最上面时，切过去仍停在清单顶端', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pumpRosterScreen(tester);

    await tester.tap(find.byTooltip('切换至编辑模式'));
    await tester.pumpAndSettle();

    expect(find.text('进阶：汇入整季服事表'), findsOneWidget, reason: '汇入卡应该看得到');
    final listOffset = tester
        .widget<ListView>(find.byType(ListView))
        .controller!
        .position
        .pixels;
    expect(listOffset, closeTo(0, 0.5), reason: '应该仍停在清单顶端');
  });
}
