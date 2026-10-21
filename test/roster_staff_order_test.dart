import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:church_staff_pwa/core/types/service_type.dart';
import 'package:church_staff_pwa/features/auth/domain/entities/user.dart';
import 'package:church_staff_pwa/features/auth/presentation/providers/session_provider.dart';
import 'package:church_staff_pwa/features/auth/presentation/providers/user_admin_provider.dart';
import 'package:church_staff_pwa/features/roster/domain/entities/service_roster.dart';
import 'package:church_staff_pwa/features/roster/domain/roster_import.dart';
import 'package:church_staff_pwa/features/roster/domain/staff_order.dart';
import 'package:church_staff_pwa/features/roster/presentation/providers/roster_provider.dart';
import 'package:church_staff_pwa/features/roster/presentation/widgets/roster_card.dart';

import 'support/in_memory_roster_repository.dart';
import 'support/signed_in_auth_repository.dart';

/// 同工排序：每一天的名字照「这个服事项目谁是主要同工」排，而不是照那一天
/// 当初怎么存。
///
/// 以前每一天各存一份顺序，交换是就地顶替 —— 主要同工换到别天就排到第二个。
/// 这组测试守的是：不管名字是汇入、勾选还是交换进来的，排出来都一样。

const _type = ServiceType.sundayService;

ServiceRoster _roster(String id, int day, Map<String, List<String>> duties) {
  return ServiceRoster(
    id: id,
    date: DateTime(2026, 1, day),
    type: _type,
    serviceName: '主日崇拜',
    duties: [
      for (final entry in duties.entries)
        RosterEntry(role: entry.key, people: entry.value),
    ],
  );
}

List<String> _peopleOf(RosterProvider provider, String id, [int duty = 0]) =>
    provider.rosters.firstWhere((r) => r.id == id).duties[duty].people;

RosterImportReady _importReady(
  List<ServiceRoster> updates,
  StaffOrder staffOrder,
) => RosterImportReady(
  updates: updates,
  staffOrder: staffOrder,
  summary: RosterImportSummary(
    updated: updates.length,
    missingDates: const [],
    notInRosterNames: const [],
    roleMismatchDetails: const {},
    otherNames: const [],
    nearMatchSuggestions: const {},
    notInEventCatalog: const [],
  ),
);

Future<RosterProvider> _loaded(InMemoryRosterRepository repo) async {
  final provider = RosterProvider(repo);
  await provider.fetchInitialData();
  return provider;
}

void main() {
  group('StaffOrder.sort', () {
    final order = StaffOrder({
      '招待': ['志豪', '美玉', '小明'],
    });

    test('照排序排，不看原本的先后', () {
      expect(order.sort('招待', ['小明', '志豪']), ['志豪', '小明']);
    });

    test('排序里没有的人接在后面，彼此维持原本的先后', () {
      expect(order.sort('招待', ['外请乙', '小明', '外请甲', '志豪']), [
        '志豪',
        '小明',
        '外请乙',
        '外请甲',
      ]);
    });

    test('已经排好时回传同一个 List', () {
      final people = ['志豪', '小明'];
      expect(identical(order.sort('招待', people), people), isTrue);
    });

    test('没排过的服事项目原样回传', () {
      final people = ['小明', '志豪'];
      expect(identical(order.sort('司琴', people), people), isTrue);
    });

    test('名字前后有空白也认得', () {
      expect(order.sort('招待', ['小明 ', ' 志豪']), [' 志豪', '小明 ']);
    });
  });

  group('StaffOrder.learnFrom', () {
    test('照平均位置排：一次写反不会盖掉其他几周', () {
      final learned = StaffOrder.learnFrom([
        _roster('1', 4, {
          'Vocal': ['雅婷', '阿华'],
        }),
        _roster('2', 11, {
          'Vocal': ['阿华', '雅婷'],
        }),
        _roster('3', 18, {
          'Vocal': ['阿华', '雅婷'],
        }),
      ]);
      expect(learned.rankingOf('Vocal'), ['阿华', '雅婷']);
    });

    test('没有直接同一天过的人也排得出前后', () {
      // 图片上的招待：负责人每次都写第一个，其他人两两出现。
      final learned = StaffOrder.learnFrom([
        _roster('1', 4, {
          '招待': ['志豪', '美玉', '小明'],
        }),
        _roster('2', 11, {
          '招待': ['美玉', '阿德'],
        }),
        _roster('3', 18, {
          '招待': ['志豪', '阿德'],
        }),
      ]);
      final ranking = learned.rankingOf('招待');
      expect(ranking.first, '志豪');
      expect(ranking.indexOf('美玉'), lessThan(ranking.indexOf('小明')));
    });

    test('只有一个人或待定的那几天不算', () {
      final learned = StaffOrder.learnFrom([
        _roster('1', 4, {
          '司琴': ['美玉'],
          '鼓': ['待定'],
        }),
      ]);
      expect(learned.isEmpty, isTrue);
    });
  });

  group('StaffOrder 的组合', () {
    test('mergedWith：新的照新的排，没提到的人留在原位', () {
      // 主要同工甲这一季请假、不在图片上。挤到最后的话他回来那天就排在新人
      // 后面。
      final stored = StaffOrder({
        '招待': ['志豪', '美玉', '小明', '阿德'],
        '司琴': ['雅婷', '阿华'],
      });
      final next = stored.mergedWith(
        StaffOrder({
          '招待': ['阿德', '美玉', '小明'],
        }),
      );
      expect(next.rankingOf('招待'), ['志豪', '阿德', '美玉', '小明']);
      expect(next.rankingOf('司琴'), ['雅婷', '阿华']);
    });

    test('mergedWith：新面孔插在图片上他前一位的后面', () {
      final stored = StaffOrder({
        '招待': ['志豪', '美玉', '小明'],
      });
      final next = stored.mergedWith(
        StaffOrder({
          '招待': ['美玉', '新人', '小明'],
        }),
      );
      expect(next.rankingOf('招待'), ['志豪', '美玉', '新人', '小明']);
    });

    test('mergedWith：新面孔排第一时插在后面第一个认得的人前面', () {
      final stored = StaffOrder({
        '招待': ['志豪', '美玉', '小明'],
      });
      final next = stored.mergedWith(
        StaffOrder({
          '招待': ['新人', '小明'],
        }),
      );
      expect(next.rankingOf('招待'), ['志豪', '美玉', '新人', '小明']);
    });

    test('mergedWith：原本没排过的服事项目直接照新的', () {
      final next = StaffOrder().mergedWith(
        StaffOrder({
          '招待': ['美玉', '小明'],
        }),
      );
      expect(next.rankingOf('招待'), ['美玉', '小明']);
    });

    test('changesTo 只列有变的服事项目，拿掉的给 null', () {
      final before = StaffOrder({
        '招待': ['美玉', '小明'],
        '司琴': ['雅婷'],
        '鼓': ['阿华'],
      });
      final after = StaffOrder({
        '招待': ['小明', '美玉'],
        '司琴': ['雅婷'],
        '敬拜': ['阿德'],
      });
      final changes = before.changesTo(after);
      expect(changes, {
        '招待': ['小明', '美玉'],
        '敬拜': ['阿德'],
        '鼓': null,
      });
      expect(before.withChanges(changes), after);
    });

    test('where 只留认得的人', () {
      final order = StaffOrder({
        '讲道': ['外请甲', '志豪'],
      }).where((name) => name != '外请甲');
      expect(order.rankingOf('讲道'), ['志豪']);
    });

    test('withRolesRenamed 把排序搬到新名字', () {
      final renamed = StaffOrder({
        '招待': ['美玉', '小明'],
      }).withRolesRenamed({'招待': '接待'});
      expect(renamed.rankingOf('招待'), isEmpty);
      expect(renamed.rankingOf('接待'), ['美玉', '小明']);
    });

    test('toJson / fromJson 来回一样', () {
      final order = StaffOrder({
        '招待': ['美玉', '小明'],
      });
      expect(StaffOrder.fromJson(order.toJson()), order);
    });

    test('fromJson 丢掉不是字串的东西与待定', () {
      final order = StaffOrder.fromJson({
        'roles': {
          '招待': ['美玉', 3, '待定', '小明'],
          '坏掉': 'not a list',
        },
      });
      expect(order.rankingOf('招待'), ['美玉', '小明']);
      expect(order.rankingOf('坏掉'), isEmpty);
    });
  });

  group('RosterProvider', () {
    test('读进来的服事表照存著的排序排', () async {
      final repo = InMemoryRosterRepository(
        rosters: [
          _roster('a', 4, {
            '招待': ['小明', '志豪'],
          }),
        ],
        staffOrders: {
          _type: StaffOrder({
            '招待': ['志豪', '小明'],
          }),
        },
      );
      final provider = await _loaded(repo);

      expect(_peopleOf(provider, 'a'), ['志豪', '小明']);
    });

    test('没存过排序时照服事表上多数的先后排', () async {
      // 这个功能上线前的资料没有排序可读，照图片汇进来的顺序学。
      final repo = InMemoryRosterRepository(
        rosters: [
          _roster('a', 4, {
            'Vocal': ['雅婷', '阿华'],
          }),
          _roster('b', 11, {
            'Vocal': ['阿华', '雅婷'],
          }),
          _roster('c', 18, {
            'Vocal': ['阿华', '雅婷'],
          }),
        ],
      );
      final provider = await _loaded(repo);

      expect(_peopleOf(provider, 'a'), ['阿华', '雅婷']);
    });

    test('交换之后主要同工还是排第一个', () async {
      // 1/4 的志豪（主要）跟 1/11 排第二的阿德交换。就地顶替的话志豪到了
      // 1/11 会排在美玉后面，阿德则跑到 1/4 的第一个。
      final repo = InMemoryRosterRepository(
        rosters: [
          _roster('a', 4, {
            '招待': ['志豪', '小明'],
          }),
          _roster('b', 11, {
            '招待': ['美玉', '阿德'],
          }),
        ],
        staffOrders: {
          _type: StaffOrder({
            '招待': ['志豪', '美玉', '小明', '阿德'],
          }),
        },
      );
      final provider = await _loaded(repo);

      await provider.swapDutyPeople(
        sourceRosterId: 'a',
        sourceDutyIndex: 0,
        sourcePerson: '志豪',
        targetRosterId: 'b',
        targetDutyIndex: 0,
        targetPerson: '阿德',
      );

      expect(_peopleOf(provider, 'a'), ['小明', '阿德']);
      expect(_peopleOf(provider, 'b'), ['志豪', '美玉']);
      // 写进去的也是排好的，不是只有画面上排。
      final written = repo.atomicBatches.single;
      expect(written.firstWhere((r) => r.id == 'b').duties.first.people, [
        '志豪',
        '美玉',
      ]);
    });

    test('updateRoster 写进去之前先排好', () async {
      final repo = InMemoryRosterRepository(
        rosters: [
          _roster('a', 4, {
            '招待': ['志豪'],
          }),
        ],
        staffOrders: {
          _type: StaffOrder({
            '招待': ['志豪', '美玉', '小明'],
          }),
        },
      );
      final provider = await _loaded(repo);

      await provider.updateRoster(
        _roster('a', 4, {
          '招待': ['小明', '志豪'],
        }),
      );

      expect(repo.rosters.single.duties.first.people, ['志豪', '小明']);
      expect(_peopleOf(provider, 'a'), ['志豪', '小明']);
    });

    test('updateStaffRanking 重排每一天并存起来', () async {
      final repo = InMemoryRosterRepository(
        rosters: [
          _roster('a', 4, {
            '招待': ['志豪', '小明'],
          }),
          _roster('b', 11, {
            '招待': ['志豪', '美玉'],
          }),
        ],
        staffOrders: {
          _type: StaffOrder({
            '招待': ['志豪', '美玉', '小明'],
          }),
        },
      );
      final provider = await _loaded(repo);

      await provider.updateStaffRanking(
        _type,
        const StaffRanking('招待', ['小明', '美玉', '志豪']),
      );

      expect(_peopleOf(provider, 'a'), ['小明', '志豪']);
      expect(_peopleOf(provider, 'b'), ['美玉', '志豪']);
      expect(repo.staffOrders[_type]!.rankingOf('招待'), ['小明', '美玉', '志豪']);
    });

    test('updateStaffRanking 失败时往上丢，画面不动', () async {
      final repo = InMemoryRosterRepository(
        rosters: [
          _roster('a', 4, {
            '招待': ['志豪', '小明'],
          }),
        ],
        staffOrders: {
          _type: StaffOrder({
            '招待': ['志豪', '小明'],
          }),
        },
      );
      final provider = await _loaded(repo);
      repo.failStaffOrderWrite = Exception('permission-denied');

      await expectLater(
        provider.updateStaffRanking(
          _type,
          const StaffRanking('招待', ['小明', '志豪']),
        ),
        throwsException,
      );
      expect(_peopleOf(provider, 'a'), ['志豪', '小明']);
      expect(provider.staffOrderFor(_type).rankingOf('招待'), ['志豪', '小明']);
    });

    test('读不到排序时拖一次，不会把其他服事项目存过的排序删掉', () async {
      // 例如 rules 还没部署、或载入那一下刚好断线：本机以为什么都没存过。
      final repo = InMemoryRosterRepository(
        rosters: [
          _roster('a', 4, {
            '招待': ['志豪', '小明'],
          }),
        ],
        staffOrders: {
          _type: StaffOrder({
            '敬拜': ['雅婷', '阿华'],
            '招待': ['志豪', '小明'],
          }),
        },
      )..failStaffOrderRead = Exception('unavailable');
      final provider = await _loaded(repo);

      await provider.updateStaffRanking(
        _type,
        const StaffRanking('招待', ['小明', '志豪']),
      );

      expect(repo.staffOrders[_type]!.rankingOf('敬拜'), ['雅婷', '阿华']);
      expect(repo.staffOrders[_type]!.rankingOf('招待'), ['小明', '志豪']);
    });

    test('updateRoster 带排序：排序存失败时这一天也不写', () async {
      final repo = InMemoryRosterRepository(
        rosters: [
          _roster('a', 4, {
            '招待': ['志豪'],
          }),
        ],
      )..failStaffOrderWrite = Exception('permission-denied');
      final provider = await _loaded(repo);

      await expectLater(
        provider.updateRoster(
          _roster('a', 4, {
            '招待': ['志豪', '小明'],
          }),
          ranking: const StaffRanking('招待', ['小明', '志豪']),
        ),
        throwsException,
      );
      expect(repo.singleWriteCount, 0);
      expect(_peopleOf(provider, 'a'), ['志豪']);
    });

    test('applyRosterImport：图片上的人照图片排，没出现的主要同工留在原位', () async {
      final repo = InMemoryRosterRepository(
        rosters: [
          _roster('a', 4, {
            '招待': ['志豪'],
          }),
        ],
        staffOrders: {
          _type: StaffOrder({
            '招待': ['志豪', '小明', '美玉'],
          }),
        },
      );
      final provider = await _loaded(repo);

      await provider.applyRosterImport(
        _type,
        _importReady(
          [
            _roster('a', 4, {
              '招待': ['美玉', '小明'],
            }),
          ],
          StaffOrder({
            '招待': ['美玉', '小明'],
          }),
        ),
      );

      expect(repo.staffOrders[_type]!.rankingOf('招待'), ['志豪', '美玉', '小明']);
      expect(_peopleOf(provider, 'a'), ['美玉', '小明']);
      expect(repo.rosters.single.duties.first.people, ['美玉', '小明']);
    });

    test('applyRosterImport：排序没变就不写排序', () async {
      final repo = InMemoryRosterRepository(
        rosters: [
          _roster('a', 4, {
            '招待': ['志豪'],
          }),
        ],
        staffOrders: {
          _type: StaffOrder({
            '招待': ['志豪', '小明'],
          }),
        },
      );
      final provider = await _loaded(repo);

      await provider.applyRosterImport(
        _type,
        _importReady(
          [
            _roster('a', 4, {
              '招待': ['志豪', '小明'],
            }),
          ],
          StaffOrder({
            '招待': ['志豪', '小明'],
          }),
        ),
      );
      expect(repo.staffOrderWrites, 0);
    });

    test('applyRosterImport：排序写失败时一张服事表都不写', () async {
      final repo = InMemoryRosterRepository(
        rosters: [
          _roster('a', 4, {
            '招待': ['志豪'],
          }),
        ],
      )..failStaffOrderWrite = Exception('permission-denied');
      final provider = await _loaded(repo);

      await expectLater(
        provider.applyRosterImport(
          _type,
          _importReady(
            [
              _roster('a', 4, {
                '招待': ['美玉', '小明'],
              }),
            ],
            StaffOrder({
              '招待': ['美玉', '小明'],
            }),
          ),
        ),
        throwsException,
      );
      expect(repo.singleWriteCount, 0);
      expect(_peopleOf(provider, 'a'), ['志豪']);
    });

    test('服事项目改名时排序跟著搬', () async {
      final repo = InMemoryRosterRepository(
        rosters: [
          _roster('a', 4, {
            '招待': ['小明', '志豪'],
          }),
        ],
        templates: {
          _type: ['招待'],
        },
        staffOrders: {
          _type: StaffOrder({
            '招待': ['志豪', '小明'],
          }),
        },
      );
      final provider = await _loaded(repo);

      await provider.updateTemplates(
        {
          _type: ['接待'],
        },
        renamedRolesByType: {
          _type: {'招待': '接待'},
        },
      );

      expect(repo.staffOrders[_type]!.rankingOf('接待'), ['志豪', '小明']);
      expect(_peopleOf(provider, 'a'), ['志豪', '小明']);
    });
  });

  group('选人视窗', () {
    setUpAll(() => initializeDateFormatting('zh_TW'));

    testWidgets('拖曳顺序后储存：存成整个服事项目的排序', (tester) async {
      final repo = InMemoryRosterRepository(
        rosters: [
          _roster('a', 4, {
            '招待': ['志豪', '小明'],
          }),
          _roster('b', 11, {
            '招待': ['志豪', '美玉'],
          }),
        ],
        templates: {
          _type: ['招待'],
        },
        staffOrders: {
          _type: StaffOrder({
            '招待': ['志豪', '美玉', '小明'],
          }),
        },
      );
      final provider = await _pumpCard(tester, repo);

      await tester.tap(find.text('招待'));
      await tester.pumpAndSettle();
      expect(find.text('选择同工（拖曳排序会套用到每一周）'), findsOneWidget);

      // 把小明拖到最上面（待定的上面就是顶，待定本身拖不动）。
      final sheet = find.byType(ReorderableListView);
      await _drag(tester, sheet, '小明', '志豪');
      final options = tester
          .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
          .map((t) => (t.title as Text).data)
          .toList();
      expect(options, ['待定', '小明', '志豪', '美玉'], reason: '拖曳没生效');

      await tester.tap(find.widgetWithText(FilledButton, '储存'));
      await tester.pumpAndSettle();

      expect(repo.staffOrders[_type]!.rankingOf('招待').first, '小明');
      // 另一天没打开过，也照新的排序重排。
      expect(_peopleOf(provider, 'a'), ['小明', '志豪']);
      expect(_peopleOf(provider, 'b').first, '志豪');
      expect(
        repo.staffOrders[_type]!.rankingOf('招待').indexOf('志豪'),
        lessThan(repo.staffOrders[_type]!.rankingOf('招待').indexOf('美玉')),
      );
    });

    testWidgets('名单外的人拖不动，也不会写进排序', (tester) async {
      final repo = InMemoryRosterRepository(
        rosters: [
          _roster('a', 4, {
            '招待': ['志豪', '外请甲'],
          }),
        ],
        templates: {
          _type: ['招待'],
        },
        staffOrders: {
          _type: StaffOrder({
            '招待': ['志豪', '美玉', '小明'],
          }),
        },
      );
      await _pumpCard(tester, repo);

      await tester.tap(find.text('招待'));
      await tester.pumpAndSettle();
      final sheet = find.byType(ReorderableListView);
      List<String?> options() => tester
          .widgetList<CheckboxListTile>(
            find.descendant(of: sheet, matching: find.byType(CheckboxListTile)),
          )
          .map((t) => (t.title as Text).data)
          .toList();
      final before = options();
      expect(before.last, '外请甲');

      await _drag(tester, sheet, '外请甲', '志豪');
      expect(options(), before, reason: '外请甲不该被拖动');

      // 拖一个名单上的人，排序才会写；写进去的也不含外请甲。
      await _drag(tester, sheet, '小明', '志豪');
      await tester.tap(find.widgetWithText(FilledButton, '储存'));
      await tester.pumpAndSettle();

      final ranking = repo.staffOrders[_type]!.rankingOf('招待');
      expect(ranking.first, '小明');
      expect(ranking, isNot(contains('外请甲')));
    });

    testWidgets('只改勾选、没拖过就不写排序', (tester) async {
      final repo = InMemoryRosterRepository(
        rosters: [
          _roster('a', 4, {
            '招待': ['志豪', '小明'],
          }),
        ],
        templates: {
          _type: ['招待'],
        },
        staffOrders: {
          _type: StaffOrder({
            '招待': ['志豪', '美玉', '小明'],
          }),
        },
      );
      await _pumpCard(tester, repo);

      await tester.tap(find.text('招待'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(ReorderableListView),
          matching: find.text('小明'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '储存'));
      await tester.pumpAndSettle();

      expect(repo.staffOrderWrites, 0);
      expect(repo.rosters.single.duties.first.people, ['志豪']);
    });

    testWidgets('没有同工可选时，说明要去哪里勾参与服事', (tester) async {
      final repo = InMemoryRosterRepository(
        rosters: [
          _roster('a', 4, {
            '招待': ['志豪'],
            '司琴': [],
          }),
        ],
        templates: {
          _type: ['招待', '司琴'],
        },
      );
      await _pumpCard(tester, repo);

      await tester.tap(find.text('司琴'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('还没有同工可排「司琴」。请到「我的」→「帐号管理」编辑同工'),
        findsOneWidget,
      );
      expect(find.textContaining('勾选「司琴」'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('招待'));
      await tester.pumpAndSettle();
      expect(find.textContaining('还没有同工可排'), findsNothing);
    });
  });
}

const _kEditor = User(
  id: 'u1',
  name: '编辑者',
  email: 'a@b.c',
  username: 'editor',
  role: UserRole.admin,
  groups: {},
  zones: [],
);

User _staff(String id, String name) => User(
  id: id,
  name: name,
  email: '$id@example.com',
  username: id,
  role: UserRole.staff,
  zones: const [
    UserZoneInfo(serviceType: _type, ministries: ['招待']),
  ],
);

/// 志豪、美玉、小明在同工名单上；外请甲不在。
SignedInAuthRepository _auth() => SignedInAuthRepository(
  _kEditor,
  users: [
    _kEditor,
    _staff('u-hao', '志豪'),
    _staff('u-yu', '美玉'),
    _staff('u-ming', '小明'),
  ],
);

/// 在 [sheet] 里长按 [name] 拖到 [onto] 的上方。
Future<void> _drag(
  WidgetTester tester,
  Finder sheet,
  String name,
  String onto,
) async {
  final from = tester.getCenter(
    find.descendant(of: sheet, matching: find.text(name)),
  );
  final to =
      tester.getCenter(find.descendant(of: sheet, matching: find.text(onto))) -
      const Offset(0, 20);
  final gesture = await tester.startGesture(from);
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
  for (var i = 1; i <= 10; i++) {
    await gesture.moveTo(Offset.lerp(from, to, i / 10)!);
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

/// 挂第一天那张卡片，已经在编辑模式。
Future<RosterProvider> _pumpCard(
  WidgetTester tester,
  InMemoryRosterRepository repo,
) async {
  final provider = await _loaded(repo);
  provider.toggleEditMode();

  // session 要先还原完，UserAdminProvider.getUsers() 才过得了 canEditRoster。
  final session = SessionProvider(_auth());
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
          value: UserAdminProvider(_auth(), session),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Consumer<RosterProvider>(
            builder: (context, p, _) => ListView(
              children: [
                RosterCard(
                  key: const ValueKey('a'),
                  roster: p.getRostersByType(_type).first,
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
