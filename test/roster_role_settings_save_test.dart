import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:church_staff_pwa/core/config/church_config.dart';
import 'package:church_staff_pwa/core/types/service_type.dart';
import 'package:church_staff_pwa/features/auth/presentation/providers/user_admin_provider.dart';
import 'package:church_staff_pwa/features/roster/presentation/providers/roster_provider.dart';
import 'package:church_staff_pwa/features/roster/presentation/screens/role_settings_screen.dart';

import 'package:church_staff_pwa/features/roster/domain/entities/service_roster.dart';
import 'package:church_staff_pwa/features/roster/presentation/write_failure.dart';

import 'support/in_memory_roster_repository.dart';

/// 只记录 cleanupUserMinistries 有没有被叫到。其余方法这个画面用不到。
class _RecordingUserAdmin extends ChangeNotifier implements UserAdminProvider {
  final List<Map<ServiceType, List<String>>> cleanups = [];

  @override
  Future<void> cleanupUserMinistries(
    Map<ServiceType, List<String>> templates,
  ) async {
    cleanups.add(templates);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 样板写进去了，但改名同步到服事表时有一天没写成功。
class _PartialRenameRosterProvider extends RosterProvider {
  _PartialRenameRosterProvider(super.repository);

  @override
  Future<void> updateTemplates(
    Map<ServiceType, List<String>> newTemplates, {
    Map<ServiceType, Map<String, String>> renamedRolesByType = const {},
  }) async {
    throw PartialUpdateException(
      successCount: 2,
      failureCount: 1,
      failedRosters: const <ServiceRoster>[],
      cause: Exception('write failed'),
    );
  }
}

Future<void> _openRoleSettings(
  WidgetTester tester,
  RosterProvider rosterProvider,
  UserAdminProvider userAdmin,
) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<RosterProvider>.value(value: rosterProvider),
        ChangeNotifierProvider<UserAdminProvider>.value(value: userAdmin),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const RoleSettingsScreen(),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('writeFailureMessage', () {
    test('一般失败：动词＋原因', () {
      expect(writeFailureMessage('更新', Exception('x')), startsWith('更新失败：'));
    });

    test('部分失败不说「失败」，说几天没成功、几天已完成，再接画面的补充', () {
      final message = writeFailureMessage(
        '储存',
        PartialUpdateException(
          successCount: 2,
          failureCount: 1,
          failedRosters: const [],
          cause: Exception('x'),
        ),
        partialNote: '设定本身已储存',
      );
      expect(message, '有 1 天的服事表没有储存成功，其余 2 天已完成。设定本身已储存');
    });

    test('partialNote 只接在部分失败后面', () {
      expect(
        writeFailureMessage('储存', Exception('x'), partialNote: '设定本身已储存'),
        isNot(contains('设定本身已储存')),
      );
    });
  });

  testWidgets('样板写进去、只有改名同步部分失败：照样清同工设定，留在这页', (tester) async {
    final rosterProvider = _PartialRenameRosterProvider(
      InMemoryRosterRepository(
        templates: {
          for (final type in ServiceType.values) type: ['领会'],
        },
      ),
    );
    await rosterProvider.fetchInitialData();
    final userAdmin = _RecordingUserAdmin();
    await _openRoleSettings(tester, rosterProvider, userAdmin);

    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();

    expect(userAdmin.cleanups, hasLength(1));
    expect(find.byType(RoleSettingsScreen), findsOneWidget);
    expect(find.textContaining('设定本身已储存'), findsOneWidget);
  });

  // 清同工设定是依「新样板」删掉不在里面的服事。样板没写进去还照清的话，
  // 同工的服事被删了，样板却还是旧的 —— 以前就是这样。
  testWidgets('样板存档失败：不清同工设定、留在这页；再存一次成功才清', (tester) async {
    final repository = InMemoryRosterRepository(
      templates: {
        for (final type in ServiceType.values) type: ['领会'],
      },
    )..failTemplateWrite = StateError('permission-denied');
    final rosterProvider = RosterProvider(repository);
    await rosterProvider.fetchInitialData();
    final userAdmin = _RecordingUserAdmin();

    await _openRoleSettings(tester, rosterProvider, userAdmin);

    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();

    expect(userAdmin.cleanups, isEmpty);
    expect(find.byType(RoleSettingsScreen), findsOneWidget);
    expect(find.textContaining('储存失败'), findsOneWidget);

    repository.failTemplateWrite = null;
    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();

    expect(userAdmin.cleanups, hasLength(1));
    expect(find.byType(RoleSettingsScreen), findsNothing);
  });

  // 聚会设定里停用的聚会不再有分页，但它的样板要原封不动存回去：之后再开启
  // 时，服事项目都还在。
  testWidgets('停用的聚会不出现分页，存档时样板照样保留', (tester) async {
    final previous = ChurchConfig.current;
    addTearDown(() => ChurchConfig.current = previous);
    final services = previous.services;
    ChurchConfig.current = previous.withServices([
      for (final (index, service) in services.indexed)
        index == services.length - 1
            ? service.copyWith(enabled: false)
            : service,
    ]);
    final disabled = ServiceType(services.last.id);

    final repository = InMemoryRosterRepository(
      templates: {
        for (final type in ServiceType.values) type: ['领会'],
      },
    );
    final rosterProvider = RosterProvider(repository);
    await rosterProvider.fetchInitialData();
    final userAdmin = _RecordingUserAdmin();
    await _openRoleSettings(tester, rosterProvider, userAdmin);

    expect(find.widgetWithText(Tab, services.first.label), findsOneWidget);
    expect(find.widgetWithText(Tab, services.last.label), findsNothing);

    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();

    expect(repository.templates[disabled], ['领会']);
    expect(userAdmin.cleanups.single[disabled], ['领会']);
  });
}
