import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:church_staff_pwa/core/types/service_type.dart';
import 'package:church_staff_pwa/features/auth/domain/entities/user.dart';
import 'package:church_staff_pwa/features/auth/presentation/providers/session_provider.dart';
import 'package:church_staff_pwa/features/auth/presentation/providers/user_admin_provider.dart';
import 'package:church_staff_pwa/features/roster/domain/entities/service_roster.dart';
import 'package:church_staff_pwa/features/roster/presentation/providers/roster_provider.dart';
import 'package:church_staff_pwa/features/roster/presentation/widgets/roster_card.dart';

import 'support/in_memory_roster_repository.dart';
import 'support/signed_in_auth_repository.dart';

/// 交换服事（「1/1 的破冰跟 1/8 换一下」）。
///
/// 这组测试守两件事：
///   1. 两笔一定走同一次 atomic 写入 —— 分两次写的话，中间失败会留下一个人
///      被排两天、另一个人的那天空著。
///   2. 写失败时本地状态不能先被改掉 —— 否则画面显示已交换，Firestore 上却
///      没有，而且没有任何提示。
InMemoryRosterRepository _repo({required List<ServiceRoster> rosters}) =>
    InMemoryRosterRepository(
      rosters: rosters,
      templates: {
        ServiceType.sundayService: ['破冰'],
      },
    );

/// 交换入口现在在「编辑服事项目」的视窗里，而那个视窗会去 UserAdminProvider
/// 捞同工名单 —— 所以这组 UI 测试得连 session 一起挂上。
const _kEditor = User(
  id: 'u1',
  name: '编辑者',
  email: 'a@b.c',
  username: 'editor',
  role: UserRole.admin,
  groups: {},
  zones: [],
);

ServiceRoster _roster({
  required String id,
  required int day,
  required List<RosterEntry> duties,
}) {
  return ServiceRoster(
    id: id,
    date: DateTime(2026, 1, day),
    type: ServiceType.sundayService,
    serviceName: '主日崇拜',
    duties: duties,
  );
}

RosterEntry _duty(
  List<String> people, {
  String role = '破冰',
  Map<String, String> ids = const {},
}) {
  return RosterEntry(role: role, people: people, personIdsByName: ids);
}

/// 直接把 provider 的内部状态填好，不必跑完整的 fetch 流程。
Future<RosterProvider> _providerWith(InMemoryRosterRepository repo) async {
  final provider = RosterProvider(repo);
  await provider.fetchRosters();
  return provider;
}

RosterEntry _dutyOf(RosterProvider provider, String rosterId) =>
    provider.rosters.firstWhere((r) => r.id == rosterId).duties.first;

void main() {
  group('replaceDutyPerson', () {
    test('换掉指定的人，其他人与顺序不动', () {
      final result = RosterProvider.replaceDutyPerson(
        _duty(['美玉', '小明'], ids: {'美玉': 'uid-fang', '小明': 'uid-ming'}),
        '美玉',
        '志豪',
        toId: 'uid-hao',
      );

      expect(result.people, ['志豪', '小明']);
      expect(result.personIdsByName, {'志豪': 'uid-hao', '小明': 'uid-ming'});
    });

    test('换成待定：这一天还有别人时不补占位符', () {
      final result = RosterProvider.replaceDutyPerson(
        _duty(['美玉', '小明']),
        '美玉',
        '待定',
      );

      expect(result.people, ['小明']);
    });

    test('换成待定：全空了才补回占位符', () {
      final result = RosterProvider.replaceDutyPerson(
        _duty(['美玉'], ids: {'美玉': 'uid-fang'}),
        '美玉',
        '待定',
      );

      expect(result.people, ['待定']);
      // 名字都不在了，uid 不能留著 —— 下次交换会被误搬。
      expect(result.personIdsByName, isEmpty);
    });

    test('待定被换成真人时，占位符要消失', () {
      final result = RosterProvider.replaceDutyPerson(
        _duty(['待定']),
        '待定',
        '美玉',
        toId: 'uid-fang',
      );

      expect(result.people, ['美玉']);
      expect(result.personIdsByName, {'美玉': 'uid-fang'});
    });

    test('换进来的人本来就在这一天：不留下两个同名', () {
      final result = RosterProvider.replaceDutyPerson(
        _duty(['美玉', '小明']),
        '美玉',
        '小明',
      );

      expect(result.people, ['小明']);
    });

    test('people 是空的（UI 显示成待定）时，换进来的人不能消失', () {
      // 没有人的 duty 在交换清单上长得跟「待定」一样，所以 from 会是「待定」。
      // 把空清单原样跑完的话，替换不到东西，补回一个待定 —— 换过来的人就在
      // 同一个 batch 里凭空不见，而来源那天已经把他移走了。
      final result = RosterProvider.replaceDutyPerson(
        RosterEntry(role: '破冰', people: const []),
        '待定',
        '美玉',
        toId: 'uid-fang',
      );

      expect(result.people, ['美玉']);
      expect(result.personIdsByName, {'美玉': 'uid-fang'});
    });
  });

  group('swapDutyPeople', () {
    test('两笔走同一次 atomic 写入，本地状态也跟著换', () async {
      final repo = _repo(
        rosters: [
          _roster(
            id: 'a',
            day: 4,
            duties: [
              _duty(['美玉'], ids: {'美玉': 'uid-fang'}),
            ],
          ),
          _roster(
            id: 'b',
            day: 11,
            duties: [
              _duty(['小明'], ids: {'小明': 'uid-ming'}),
            ],
          ),
        ],
      );
      final provider = await _providerWith(repo);

      await provider.swapDutyPeople(
        sourceRosterId: 'a',
        sourceDutyIndex: 0,
        sourcePerson: '美玉',
        targetRosterId: 'b',
        targetDutyIndex: 0,
        targetPerson: '小明',
      );

      expect(repo.atomicBatches, hasLength(1));
      expect(repo.atomicBatches.single.map((r) => r.id), ['a', 'b']);
      expect(repo.singleWriteCount, 0);

      expect(_dutyOf(provider, 'a').people, ['小明']);
      expect(_dutyOf(provider, 'a').personIdsByName, {'小明': 'uid-ming'});
      expect(_dutyOf(provider, 'b').people, ['美玉']);
      expect(_dutyOf(provider, 'b').personIdsByName, {'美玉': 'uid-fang'});
    });

    test('rosters 换成新的 instance，衍生快取才会失效', () async {
      final repo = _repo(
        rosters: [
          _roster(
            id: 'a',
            day: 4,
            duties: [
              _duty(['美玉']),
            ],
          ),
          _roster(
            id: 'b',
            day: 11,
            duties: [
              _duty(['小明']),
            ],
          ),
        ],
      );
      final provider = await _providerWith(repo);
      final before = provider.getRostersByType(ServiceType.sundayService);

      await provider.swapDutyPeople(
        sourceRosterId: 'a',
        sourceDutyIndex: 0,
        sourcePerson: '美玉',
        targetRosterId: 'b',
        targetDutyIndex: 0,
        targetPerson: '小明',
      );

      final after = provider.getRostersByType(ServiceType.sundayService);
      expect(identical(before, after), isFalse);
      expect(after.first.duties.first.people, ['小明']);
    });

    test('写入失败时往上丢，且本地状态不动', () async {
      final repo = _repo(
        rosters: [
          _roster(
            id: 'a',
            day: 4,
            duties: [
              _duty(['美玉']),
            ],
          ),
          _roster(
            id: 'b',
            day: 11,
            duties: [
              _duty(['小明']),
            ],
          ),
        ],
      )..failAtomicWrites = true;
      final provider = await _providerWith(repo);

      await expectLater(
        provider.swapDutyPeople(
          sourceRosterId: 'a',
          sourceDutyIndex: 0,
          sourcePerson: '美玉',
          targetRosterId: 'b',
          targetDutyIndex: 0,
          targetPerson: '小明',
        ),
        throwsA(isA<Exception>()),
      );

      expect(_dutyOf(provider, 'a').people, ['美玉']);
      expect(_dutyOf(provider, 'b').people, ['小明']);
      // 交换失败不该把服事表整个标成错误 —— 错误由 sheet 就地显示。
      expect(provider.error, isNull);
    });

    test('找不到服事表时丢 StateError，不会静默无事发生', () async {
      final repo = _repo(
        rosters: [
          _roster(
            id: 'a',
            day: 4,
            duties: [
              _duty(['美玉']),
            ],
          ),
        ],
      );
      final provider = await _providerWith(repo);

      await expectLater(
        provider.swapDutyPeople(
          sourceRosterId: 'a',
          sourceDutyIndex: 0,
          sourcePerson: '美玉',
          targetRosterId: 'missing',
          targetDutyIndex: 0,
          targetPerson: '小明',
        ),
        throwsA(isA<StateError>()),
      );
      expect(repo.atomicBatches, isEmpty);
    });

    test('服事项目索引超出范围时丢 StateError', () async {
      final repo = _repo(
        rosters: [
          _roster(
            id: 'a',
            day: 4,
            duties: [
              _duty(['美玉']),
            ],
          ),
          _roster(
            id: 'b',
            day: 11,
            duties: [
              _duty(['小明']),
            ],
          ),
        ],
      );
      final provider = await _providerWith(repo);

      await expectLater(
        provider.swapDutyPeople(
          sourceRosterId: 'a',
          sourceDutyIndex: 0,
          sourcePerson: '美玉',
          targetRosterId: 'b',
          targetDutyIndex: 5,
          targetPerson: '小明',
        ),
        throwsA(isA<StateError>()),
      );
      expect(repo.atomicBatches, isEmpty);
    });
  });

  group('交换 sheet', () {
    setUpAll(() async {
      // 卡片标题与候选清单都用 zh_TW 的 DateFormat，没初始化会直接丢
      // LocaleDataException。
      await initializeDateFormatting('zh_TW');
    });

    /// 挂一张展开的服事表卡片，并且已经在编辑模式 —— 交换入口只在编辑模式出现。
    Future<RosterProvider> pumpCard(
      WidgetTester tester,
      InMemoryRosterRepository repo,
    ) async {
      final provider = await _providerWith(repo);
      provider.toggleEditMode();

      // session 要先还原完，UserAdminProvider.getUsers() 才过得了 canEditRoster。
      final session = SessionProvider(SignedInAuthRepository(_kEditor));
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
            ChangeNotifierProvider<RosterProvider>.value(value: provider),
            ChangeNotifierProvider<SessionProvider>.value(value: session),
            ChangeNotifierProvider<UserAdminProvider>.value(
              value: UserAdminProvider(
                SignedInAuthRepository(_kEditor),
                session,
              ),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              // 照 _RosterList 的做法从 provider 读，卡片才会跟著新资料重建 ——
              // 直接把 roster 物件塞进去的话，交换完画面永远是旧的。
              body: Consumer<RosterProvider>(
                builder: (context, p, _) => ListView(
                  children: [
                    RosterCard(
                      key: const ValueKey('a'),
                      roster: p
                          .getRostersByType(ServiceType.sundayService)
                          .first,
                      initiallyExpanded: true,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return provider;
    }

    /// 走使用者真的会走的路径：点服事列开编辑视窗，再按「与其他日期交换」。
    /// ⇄ 不再直接挂在列上 —— 那颗按钮占掉的宽度会把三个名字挤成两行。
    Future<void> openSwapSheet(WidgetTester tester) async {
      await tester.tap(find.text('破冰'));
      await tester.pumpAndSettle();
      expect(find.text('与其他日期交换'), findsOneWidget, reason: '编辑视窗里要有交换入口');
      await tester.tap(find.text('与其他日期交换'));
      await tester.pumpAndSettle();
    }

    testWidgets('选一天按下交换，两笔一次写完并回到卡片上', (tester) async {
      final repo = _repo(
        rosters: [
          _roster(
            id: 'a',
            day: 4,
            duties: [
              _duty(['美玉']),
            ],
          ),
          _roster(
            id: 'b',
            day: 11,
            duties: [
              _duty(['小明']),
            ],
          ),
        ],
      );
      await pumpCard(tester, repo);

      await openSwapSheet(tester);

      expect(find.text('交换服事'), findsOneWidget);
      // 候选清单是「日期 + 那天的人」，1/11 的小明应该在里面。
      expect(find.text('01/11 (日)'), findsOneWidget);

      await tester.tap(find.text('01/11 (日)'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '交换'));
      await tester.pumpAndSettle();

      expect(repo.atomicBatches, hasLength(1));
      expect(find.text('交换服事'), findsNothing);
      // 卡片上的名字换过来了。
      expect(find.text('小明'), findsOneWidget);
    });

    testWidgets('自己那天已经有的人不会出现在候选清单里', (tester) async {
      final repo = _repo(
        rosters: [
          _roster(
            id: 'a',
            day: 4,
            duties: [
              _duty(['美玉', '小明']),
            ],
          ),
          _roster(
            id: 'b',
            day: 11,
            duties: [
              _duty(['小明']),
            ],
          ),
        ],
      );
      await pumpCard(tester, repo);

      await openSwapSheet(tester);

      // 1/11 只排了小明，而小明本来就在 1/4，换过来只会变成同一天两个小明。
      expect(find.text('01/11 (日)'), findsNothing);
      expect(find.text('其他日期没有可以交换的「破冰」'), findsOneWidget);
    });

    // 上面那条的反方向。候选清单是按「来源这天已经有谁」滤的，滤不掉「对方那天
    // 已经有要换过去的人」—— 那种交换会让对方那天出现两个同名，去重之后吃掉
    // 一个，结果是那一天平白少一个人，而且画面上完全看不出来。
    testWidgets('对方那天已经有这个人时，那一天不会出现在候选清单里', (tester) async {
      final repo = _repo(
        rosters: [
          _roster(
            id: 'a',
            day: 4,
            duties: [
              _duty(['美玉']),
            ],
          ),
          _roster(
            id: 'b',
            day: 11,
            duties: [
              _duty(['美玉', '阿德']),
            ],
          ),
        ],
      );
      await pumpCard(tester, repo);

      await openSwapSheet(tester);

      // 拿 1/4 的美玉去换 1/11 的阿德：美玉已经在 1/11 了，换完那天只剩美玉
      // 一个人。
      expect(find.text('01/11 (日)'), findsNothing);
      expect(find.text('其他日期没有可以交换的「破冰」'), findsOneWidget);
    });

    testWidgets('换掉「要换谁」之后，候选清单跟著重算', (tester) async {
      final repo = _repo(
        rosters: [
          _roster(
            id: 'a',
            day: 4,
            duties: [
              _duty(['美玉', '小明']),
            ],
          ),
          _roster(
            id: 'b',
            day: 11,
            duties: [
              _duty(['小明', '阿德']),
            ],
          ),
        ],
      );
      await pumpCard(tester, repo);

      await openSwapSheet(tester);

      // 预设要换的是美玉，她不在 1/11，所以阿德可以选。
      expect(find.text('01/11 (日)'), findsOneWidget);

      // 改成换小明 —— 他已经在 1/11 了，同一个选项就不能再出现。
      await tester.tap(find.widgetWithText(ChoiceChip, '小明'));
      await tester.pumpAndSettle();

      expect(find.text('01/11 (日)'), findsNothing);
      expect(find.text('其他日期没有可以交换的「破冰」'), findsOneWidget);
    });

    testWidgets('选好之后才换「要换谁」，不会拿旧的索引去换错人', (tester) async {
      final repo = _repo(
        rosters: [
          _roster(
            id: 'a',
            day: 4,
            duties: [
              _duty(['美玉', '小明']),
            ],
          ),
          _roster(
            id: 'b',
            day: 11,
            duties: [
              _duty(['阿德']),
            ],
          ),
          _roster(
            id: 'c',
            day: 18,
            duties: [
              _duty(['小美']),
            ],
          ),
        ],
      );
      await pumpCard(tester, repo);

      await openSwapSheet(tester);

      await tester.tap(find.text('01/18 (日)'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('01/04 (日) 美玉'),
        findsOneWidget,
        reason: '选好之后有预览',
      );

      // 换人之后选取要清掉：清单可能重算，同一个索引指到的已经是别人了。
      await tester.tap(find.widgetWithText(ChoiceChip, '小明'));
      await tester.pumpAndSettle();

      expect(find.textContaining('⇄'), findsNothing, reason: '没有选取就不该有预览');
      await tester.tap(find.text('交换'));
      await tester.pumpAndSettle();
      expect(repo.atomicBatches, isEmpty, reason: '没有选取就按不动');
    });

    // 交换会重写这一项的人，带不过去 —— 但也不能就这样把使用者刚勾的东西
    // 静静丢掉。
    testWidgets('编辑视窗有未存的改动时，去交换前先问一声', (tester) async {
      final repo = _repo(
        rosters: [
          _roster(
            id: 'a',
            day: 4,
            duties: [
              _duty(['美玉']),
            ],
          ),
          _roster(
            id: 'b',
            day: 11,
            duties: [
              _duty(['小明']),
            ],
          ),
        ],
      );
      await pumpCard(tester, repo);

      await tester.tap(find.text('破冰'));
      await tester.pumpAndSettle();
      // 勾掉原本的人 —— 这就是还没存的改动。
      await tester.tap(find.widgetWithText(CheckboxListTile, '美玉'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('与其他日期交换'));
      await tester.pumpAndSettle();
      expect(find.text('尚未储存'), findsOneWidget);

      // 选择留下：编辑视窗还在，改动也还在。
      await tester.tap(find.text('留在这里'));
      await tester.pumpAndSettle();
      expect(find.text('交换服事'), findsNothing);
      expect(find.widgetWithText(FilledButton, '储存'), findsOneWidget);

      // 再按一次并确认丢掉，才进交换。
      await tester.tap(find.text('与其他日期交换'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('丢掉并交换'));
      await tester.pumpAndSettle();
      expect(find.text('交换服事'), findsOneWidget);
      // 丢掉的意思是真的没写进去。
      expect(repo.singleWriteCount, 0);
    });

    testWidgets('没改过就按交换，不会多跳一个确认', (tester) async {
      final repo = _repo(
        rosters: [
          _roster(
            id: 'a',
            day: 4,
            duties: [
              _duty(['美玉']),
            ],
          ),
          _roster(
            id: 'b',
            day: 11,
            duties: [
              _duty(['小明']),
            ],
          ),
        ],
      );
      await pumpCard(tester, repo);

      await openSwapSheet(tester);

      expect(find.text('尚未储存'), findsNothing);
      expect(find.text('交换服事'), findsOneWidget);
    });

    // 待定是「还没排人」的占位符，不是使用者刚改的东西 —— 拿它当改动会让
    // 每个空的服事项目按交换都先被问一次。
    testWidgets('还没排人的项目按交换，不会被问有没有未存的改动', (tester) async {
      final repo = _repo(
        rosters: [
          _roster(
            id: 'a',
            day: 4,
            duties: [
              _duty(['待定']),
            ],
          ),
          _roster(
            id: 'b',
            day: 11,
            duties: [
              _duty(['小明']),
            ],
          ),
        ],
      );
      await pumpCard(tester, repo);

      await openSwapSheet(tester);

      expect(find.text('尚未储存'), findsNothing);
      expect(find.text('交换服事'), findsOneWidget);
    });

    testWidgets('写入失败时留在 sheet 上显示错误', (tester) async {
      final repo = _repo(
        rosters: [
          _roster(
            id: 'a',
            day: 4,
            duties: [
              _duty(['美玉']),
            ],
          ),
          _roster(
            id: 'b',
            day: 11,
            duties: [
              _duty(['小明']),
            ],
          ),
        ],
      )..failAtomicWrites = true;
      await pumpCard(tester, repo);

      await openSwapSheet(tester);
      await tester.tap(find.text('01/11 (日)'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '交换'));
      await tester.pumpAndSettle();

      expect(find.text('交换服事'), findsOneWidget);
      expect(find.textContaining('交换失败'), findsOneWidget);
    });
  });
}
