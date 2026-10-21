import 'dart:async';

import 'package:church_staff_pwa/core/services/app_update_service.dart';
import 'package:church_staff_pwa/core/services/app_version_service.dart';
import 'package:church_staff_pwa/features/auth/domain/entities/user.dart';
import 'package:church_staff_pwa/features/auth/presentation/providers/session_provider.dart';
import 'package:church_staff_pwa/features/auth/presentation/screens/profile_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'support/signed_in_auth_repository.dart';

/// 个人页的「检查更新」。
///
/// 真正的交接（waiting / skipWaiting / controllerchange）在
/// `web/app_update.js`，那边有自己的一组测试（web-tests/app_update.test.js）。
/// 这里守的是接到 UI 上的那一段：按钮在什么情况出现、按下去之后使用者看到
/// 什么 —— 尤其是失败时不能看起来像「检查过了，没事」，那正是这颗按钮存在的
/// 情境（使用者已经不相信画面上的版本了）。
class _FakeUpdateService implements AppUpdateService {
  _FakeUpdateService({
    required this.result,
    this.isSupported = true,
    this.error,
    this.gate,
  });

  final AppUpdateResult result;
  final Object? error;

  /// 给「检查中」那个测试用：不完成的话，按钮就停在等待状态。
  final Completer<void>? gate;

  @override
  final bool isSupported;

  int calls = 0;

  @override
  Future<AppUpdateResult> checkForUpdate() async {
    calls += 1;
    if (gate != null) await gate!.future;
    if (error != null) throw error!;
    return result;
  }
}

/// 正式环境是去抓 version.json；测试里直接给一个时间，才有「更新于 …」那行
/// 可以量位置。
class _FakeVersionService implements AppVersionService {
  const _FakeVersionService();

  @override
  Future<AppVersionInfo?> fetchVersionInfo() async =>
      AppVersionInfo(generatedAt: DateTime(2026, 8, 28, 16, 42));
}

const _user = User(
  id: 'u1',
  name: '测试者',
  email: 'a@b.c',
  username: 'tester',
  role: UserRole.member,
);

Future<void> _pumpProfile(
  WidgetTester tester,
  _FakeUpdateService updateService,
) async {
  await tester.pumpWidget(
    ChangeNotifierProvider(
      create: (_) => SessionProvider(SignedInAuthRepository(_user)),
      child: MaterialApp(
        home: ProfileScreen(
          updateService: updateService,
          versionService: const _FakeVersionService(),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('已是最新版本时说清楚', (tester) async {
    final service = _FakeUpdateService(result: AppUpdateResult.latest);
    await _pumpProfile(tester, service);

    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();

    expect(service.calls, 1);
    expect(find.text('已经是最新版本'), findsOneWidget);
  });

  testWidgets('找到新版时告诉使用者正在换', (tester) async {
    // 换完页面会自己重载，所以这句话只会出现一下下 —— 但没有它，按下去到
    // 重载之间画面完全没有反应。
    final service = _FakeUpdateService(result: AppUpdateResult.updating);
    await _pumpProfile(tester, service);

    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();

    expect(find.text('找到新版本，正在更新…'), findsOneWidget);
  });

  testWidgets('检查失败要说出来，不能静静地回「已是最新」', (tester) async {
    final service = _FakeUpdateService(
      result: AppUpdateResult.latest,
      error: Exception('offline'),
    );
    await _pumpProfile(tester, service);

    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();

    expect(find.textContaining('检查更新失败'), findsOneWidget);
    expect(find.text('已经是最新版本'), findsNothing);
  });

  testWidgets('检查中不能重复按', (tester) async {
    final gate = Completer<void>();
    final service = _FakeUpdateService(
      result: AppUpdateResult.latest,
      gate: gate,
    );
    await _pumpProfile(tester, service);

    await tester.tap(find.text('检查更新'));
    await tester.pump(); // 让 setState 生效，但结果还没回来

    expect(find.text('检查中…'), findsOneWidget);
    final button = tester.widget<InkWell>(
      find.ancestor(of: find.text('检查中…'), matching: find.byType(InkWell)),
    );
    expect(button.onTap, isNull, reason: '按著不放也只会送出一次');

    gate.complete();
    await tester.pumpAndSettle();
    expect(service.calls, 1);
    expect(find.text('检查更新'), findsOneWidget, reason: '结束后回到原本的字');
  });

  testWidgets('是页尾的注脚，不是一颗按钮', (tester) async {
    // 平常不必按（载入与切回前景都会自己检查），所以它要跟旁边的版本资讯
    // 一样是灰色小字 —— 一颗主色的 TextButton 会比它上面那行还抢眼。
    final service = _FakeUpdateService(result: AppUpdateResult.latest);
    await _pumpProfile(tester, service);

    expect(find.byType(TextButton), findsNothing);
    final label = tester.widget<Text>(find.text('检查更新'));
    final caption = Theme.of(
      tester.element(find.text('检查更新')),
    ).textTheme.bodySmall;
    expect(label.style?.fontSize, caption?.fontSize);
    expect(label.style?.color, Colors.grey.shade600);
  });

  testWidgets('自己一行，跟版本资讯各自置中', (tester) async {
    final service = _FakeUpdateService(result: AppUpdateResult.latest);
    await _pumpProfile(tester, service);

    final screenCentre = tester.getCenter(find.byType(Scaffold)).dx;
    final version = tester.getCenter(find.textContaining('更新于'));
    final link = tester.getCenter(find.text('检查更新'));

    expect(version.dx, moreOrLessEquals(screenCentre, epsilon: 1));
    expect(link.dx, moreOrLessEquals(screenCentre, epsilon: 1));
    expect(link.dy, greaterThan(version.dy), reason: '在版本资讯的下一行');
  });

  testWidgets('不支援的环境（非 web）不显示按钮', (tester) async {
    final service = _FakeUpdateService(
      result: AppUpdateResult.unsupported,
      isSupported: false,
    );
    await _pumpProfile(tester, service);

    expect(find.text('检查更新'), findsNothing);
  });
}
