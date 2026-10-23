import 'package:church_staff_pwa/features/auth/presentation/providers/session_provider.dart';
import 'package:church_staff_pwa/features/auth/presentation/screens/login_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/church_test_config.dart';
import 'support/signed_in_auth_repository.dart';

Future<SignedInAuthRepository> _pumpLogin(WidgetTester tester) async {
  final repo = SignedInAuthRepository(null);
  final session = SessionProvider(repo);
  addTearDown(session.dispose);
  await tester.pumpWidget(
    ChangeNotifierProvider<SessionProvider>.value(
      value: session,
      child: const MaterialApp(home: LoginScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  setUp(setTestChurchConfig);

  testWidgets('忘记密码带入登录栏的 Email，寄出后只说「如果有帐号」', (tester) async {
    final repo = await _pumpLogin(tester);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email'),
      ' staff@example.org ',
    );
    await tester.tap(find.text('忘记密码？'));
    await tester.pumpAndSettle();

    final dialog = find.byType(AlertDialog);
    final field = find.descendant(
      of: dialog,
      matching: find.byType(TextFormField),
    );
    expect(
      tester.widget<TextFormField>(field).controller!.text,
      'staff@example.org',
    );

    await tester.tap(find.text('寄出'));
    await tester.pumpAndSettle();

    expect(repo.resetEmails, ['staff@example.org']);
    expect(find.text('请到信箱收信'), findsOneWidget);
    expect(find.textContaining('如果 staff@example.org 有帐号'), findsOneWidget);

    await tester.tap(find.text('好'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('忘记密码没填 Email 不寄信', (tester) async {
    final repo = await _pumpLogin(tester);
    await tester.tap(find.text('忘记密码？'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('寄出'));
    await tester.pumpAndSettle();

    expect(repo.resetEmails, isEmpty);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('请输入 Email'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('寄信失败时讯息留在对话框，不当成登录错误', (tester) async {
    final repo = await _pumpLogin(tester);
    repo.resetException = Exception('boom');
    await tester.tap(find.text('忘记密码？'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextFormField),
      ),
      'staff@example.org',
    );
    await tester.tap(find.text('寄出'));
    await tester.pumpAndSettle();

    expect(find.text('无法寄出重设信，请稍后再试'), findsOneWidget);
    expect(find.text('请到信箱收信'), findsNothing);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('无法寄出重设信，请稍后再试'), findsNothing);
  });
}
