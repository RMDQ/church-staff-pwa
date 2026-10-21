import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:church_staff_pwa/core/types/service_type.dart';
import 'package:church_staff_pwa/features/auth/domain/entities/user.dart';
import 'package:church_staff_pwa/features/roster/domain/roster_import.dart';
import 'package:church_staff_pwa/features/roster/presentation/screens/roster_import_summary.dart';

User _user({List<UserZoneInfo> zones = const []}) => User(
  id: 'u1',
  name: '王大明',
  email: 'a@b.c',
  username: 'daming',
  role: UserRole.staff,
  zones: zones,
);

List<String> _ministriesFor(User user, ServiceType type) =>
    user.zones.firstWhere((z) => z.serviceType == type).ministries;

void main() {
  group('addMinistriesToUser', () {
    test('该崇拜还没有任何设定时，开一笔新的', () {
      final updated = addMinistriesToUser(_user(), ServiceType.youth, ['招待']);
      expect(_ministriesFor(updated, ServiceType.youth), ['招待']);
    });

    test('补上新服事时不覆盖既有的，顺序也不动', () {
      final before = _user(
        zones: const [
          UserZoneInfo(
            serviceType: ServiceType.youth,
            ministries: ['司琴', '领诗'],
          ),
        ],
      );
      final updated = addMinistriesToUser(before, ServiceType.youth, ['招待']);
      expect(_ministriesFor(updated, ServiceType.youth), ['司琴', '领诗', '招待']);
    });

    test('已经有的服事不会重复加一次', () {
      final before = _user(
        zones: const [
          UserZoneInfo(serviceType: ServiceType.youth, ministries: ['司琴']),
        ],
      );
      final updated = addMinistriesToUser(before, ServiceType.youth, [
        '司琴',
        '招待',
      ]);
      expect(_ministriesFor(updated, ServiceType.youth), ['司琴', '招待']);
    });

    test('不会动到他在其他崇拜的设定', () {
      final before = _user(
        zones: const [
          UserZoneInfo(
            serviceType: ServiceType.sundayService,
            ministries: ['司琴'],
            smallGroups: ['一组'],
          ),
          UserZoneInfo(serviceType: ServiceType.youth, ministries: ['领诗']),
        ],
      );
      final updated = addMinistriesToUser(before, ServiceType.youth, ['招待']);

      expect(_ministriesFor(updated, ServiceType.sundayService), ['司琴']);
      expect(
        updated.zones
            .firstWhere((z) => z.serviceType == ServiceType.sundayService)
            .smallGroups,
        ['一组'],
        reason: '补服事不该影响小组设定',
      );
      expect(_ministriesFor(updated, ServiceType.youth), ['领诗', '招待']);
    });

    test('不会就地改动传进来的 user', () {
      final before = _user(
        zones: const [
          UserZoneInfo(serviceType: ServiceType.youth, ministries: ['领诗']),
        ],
      );
      addMinistriesToUser(before, ServiceType.youth, ['招待']);
      expect(_ministriesFor(before, ServiceType.youth), ['领诗']);
    });

    test('其他栏位原封不动带过去', () {
      final updated = addMinistriesToUser(_user(), ServiceType.youth, ['招待']);
      expect(updated.id, 'u1');
      expect(updated.name, '王大明');
      expect(updated.username, 'daming');
      expect(updated.role, UserRole.staff);
    });
  });

  group('RosterImportSummary.hasIssues', () {
    RosterImportSummary summary({
      List<String> missingDates = const [],
      List<String> notInRoster = const [],
      Map<String, List<String>> mismatch = const {},
      List<String> other = const [],
      Map<String, List<String>> nearMatched = const {},
      List<String> notInCatalog = const [],
    }) => RosterImportSummary(
      updated: 3,
      missingDates: missingDates,
      notInRosterNames: notInRoster,
      roleMismatchDetails: mismatch,
      otherNames: other,
      nearMatchSuggestions: nearMatched,
      notInEventCatalog: notInCatalog,
    );

    test('全部干净时为 false', () {
      expect(summary().hasIssues, isFalse);
    });

    test('任何一类非空都为 true', () {
      expect(summary(missingDates: ['2026-01-04']).hasIssues, isTrue);
      expect(summary(notInRoster: ['雅婷']).hasIssues, isTrue);
      expect(
        summary(
          mismatch: {
            '王大明': ['招待'],
          },
        ).hasIssues,
        isTrue,
      );
      expect(summary(other: ['志明']).hasIssues, isTrue);
      expect(summary(notInCatalog: ['遇火重生营会']).hasIssues, isTrue);
    });

    // 提示本身不是一类问题 —— 有提示就一定有「名单里没有这个人」，那一类才是
    // 开视窗的理由。提示自己也算一类的话，同一件事会被算两次。
    test('只有形近字提示、没有对不到的人时，不算问题', () {
      expect(
        summary(
          nearMatched: {
            '陈志豪': ['陈志明'],
          },
        ).hasIssues,
        isFalse,
      );
    });

    test('提示跟著「名单里没有这个人」一起出现时照样算问题', () {
      final s = summary(
        notInRoster: ['陈志豪'],
        nearMatched: {
          '陈志豪': ['陈志明'],
        },
      );
      expect(s.hasIssues, isTrue);
      expect(s.hasUnmatchedNames, isTrue);
    });
  });

  group('汇入结果视窗', () {
    Future<void> pump(
      WidgetTester tester,
      RosterImportSummary summary, {
      AddMinistryToUser? onAddMinistry,
      AddEventOption? onAddEvent,
      // 补设定写的是 users/{uid}，那是 admin only。服事表编辑者进得来汇入
      // 流程，所以 onAddMinistry 可以是 null。
      bool canFix = true,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RosterImportSummaryDialog(
              summary: summary,
              type: ServiceType.youth,
              onAddMinistry: canFix
                  ? (onAddMinistry ?? (name, roles) async => Future.value())
                  : null,
              onAddEvent: canFix
                  ? (onAddEvent ?? (name) async => Future.value())
                  : null,
            ),
          ),
        ),
      );
    }

    RosterImportSummary mismatchOnly() => const RosterImportSummary(
      updated: 13,
      missingDates: [],
      notInRosterNames: [],
      roleMismatchDetails: {
        '王大明': ['招待'],
      },
      otherNames: [],
      nearMatchSuggestions: {},
      notInEventCatalog: [],
    );

    // 没有权限的人看到一颗按下去必定失败的按钮，比看不到还糟：他会一直重试，
    // 而错误讯息只会是泛用的「操作失败，请稍后再试」。
    testWidgets('没有补设定权限时不给按钮，改说要找谁', (tester) async {
      await pump(tester, mismatchOnly(), canFix: false);

      expect(find.text('新增服事至同工'), findsNothing);
      expect(find.text('只有管理员能补进他的服事设定。'), findsOneWidget);
      // 名字还是要列出来 —— 汇入结果不能因为没权限就少报一项。
      expect(find.textContaining('王大明'), findsWidgets);
    });

    testWidgets('有补设定权限时不会冒出那句提示', (tester) async {
      await pump(tester, mismatchOnly());

      expect(find.text('新增服事至同工'), findsOneWidget);
      expect(find.text('只有管理员能补进他的服事设定。'), findsNothing);
    });

    testWidgets('未设定该服事的人有「新增服事至同工」按钮，按下去带著正确的姓名与服事', (tester) async {
      String? gotName;
      List<String>? gotRoles;
      await pump(
        tester,
        mismatchOnly(),
        onAddMinistry: (name, roles) async {
          gotName = name;
          gotRoles = roles;
        },
      );

      await tester.tap(find.text('新增服事至同工'));
      await tester.pumpAndSettle();

      expect(gotName, '王大明');
      expect(gotRoles, ['招待']);
      expect(find.text('已新增'), findsOneWidget);
      expect(find.text('新增服事至同工'), findsNothing, reason: '成功后不该还能再按一次');
    });

    testWidgets('一个人有多个服事时拆成独立的列，各自一颗按钮', (tester) async {
      // 同一个人被排到两项时，可能只有其中一项该补进设定（另一项是临时支援）。
      final calls = <List<String>>[];
      await pump(
        tester,
        const RosterImportSummary(
          updated: 1,
          missingDates: [],
          notInRosterNames: [],
          roleMismatchDetails: {
            '李小华': ['司琴', '领诗'],
          },
          otherNames: [],
          nearMatchSuggestions: {},
          notInEventCatalog: [],
        ),
        onAddMinistry: (name, roles) async => calls.add(roles),
      );

      expect(find.text('・李小华：司琴'), findsOneWidget);
      expect(find.text('・李小华：领诗'), findsOneWidget);
      expect(find.text('新增服事至同工'), findsNWidgets(2));

      // 只按第一颗：另一项不该被一起加进去，按钮也还要在。
      await tester.tap(find.text('新增服事至同工').first);
      await tester.pumpAndSettle();

      expect(calls, [
        ['司琴'],
      ]);
      expect(find.text('已新增'), findsOneWidget);
      expect(find.text('新增服事至同工'), findsOneWidget);
    });

    testWidgets('同一个人的两颗按钮连按不会互相覆盖', (tester) async {
      // 每次新增都是「读出这个人 → 加一项 → 整份写回」。两笔并行的话都会读到
      // 修改前的资料，后写的会盖掉先写的 —— 画面显示两行都成功，实际只进去
      // 一项。这里用一个共享的假资料库把重叠直接测出来。
      final saved = <String>[];
      final gates = <Completer<void>>[];

      await pump(
        tester,
        const RosterImportSummary(
          updated: 1,
          missingDates: [],
          notInRosterNames: [],
          roleMismatchDetails: {
            '李小华': ['司琴', '领诗'],
          },
          otherNames: [],
          nearMatchSuggestions: {},
          notInEventCatalog: [],
        ),
        onAddMinistry: (name, roles) async {
          final snapshot = List<String>.from(saved); // 读
          final gate = Completer<void>();
          gates.add(gate);
          await gate.future; // 模拟网路来回
          saved
            ..clear()
            ..addAll([...snapshot, ...roles]); // 整份写回
        },
      );

      // 这里不能用 pumpAndSettle：等待中的那一列有 CircularProgressIndicator，
      // 动画一直排新的 frame，settle 永远等不到。
      await tester.tap(find.text('新增服事至同工').first);
      await tester.pump();
      await tester.tap(find.text('新增服事至同工').last);
      await tester.pump();

      expect(gates, hasLength(1), reason: '第二笔必须排队，不能跟第一笔同时读资料');

      gates.first.complete();
      await tester.pump();
      await tester.pump();
      expect(gates, hasLength(2), reason: '第一笔写完之后第二笔才开始读');

      gates.last.complete();
      await tester.pump();
      await tester.pump();

      expect(saved, ['司琴', '领诗'], reason: '两项都要留下来，后写的不能盖掉先写的');
      expect(find.text('已新增'), findsNWidgets(2));
    });

    testWidgets('排队中有一笔失败，不会把后面那笔一起卡死', (tester) async {
      final done = <String>[];
      await pump(
        tester,
        const RosterImportSummary(
          updated: 1,
          missingDates: [],
          notInRosterNames: [],
          roleMismatchDetails: {
            '李小华': ['司琴', '领诗'],
          },
          otherNames: [],
          nearMatchSuggestions: {},
          notInEventCatalog: [],
        ),
        onAddMinistry: (name, roles) async {
          if (roles.single == '司琴') throw Exception('boom');
          done.add(roles.single);
        },
      );

      await tester.tap(find.text('新增服事至同工').first);
      await tester.pump();
      await tester.tap(find.text('新增服事至同工').last);
      await tester.pumpAndSettle();

      expect(done, ['领诗']);
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('已新增'), findsOneWidget);
    });

    testWidgets('补设定失败时显示原因并可重试', (tester) async {
      var attempts = 0;
      await pump(
        tester,
        mismatchOnly(),
        onAddMinistry: (name, roles) async {
          attempts++;
          if (attempts == 1) throw Exception('boom');
        },
      );

      await tester.tap(find.text('新增服事至同工'));
      await tester.pumpAndSettle();
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('已新增'), findsNothing);

      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(find.text('已新增'), findsOneWidget);
    });

    testWidgets('不在名单与同名多人只列出来，没有一键按钮', (tester) async {
      await pump(
        tester,
        const RosterImportSummary(
          updated: 13,
          missingDates: [],
          notInRosterNames: ['雅婷'],
          roleMismatchDetails: {},
          otherNames: ['志明'],
          nearMatchSuggestions: {},
          notInEventCatalog: [],
        ),
      );

      expect(find.text('・雅婷'), findsOneWidget);
      expect(find.text('・志明'), findsOneWidget);
      expect(find.text('新增服事至同工'), findsNothing);
    });

    testWidgets('没有具体服事可补时不显示按钮（按了也只是重写同一份资料）', (tester) async {
      await pump(
        tester,
        const RosterImportSummary(
          updated: 1,
          missingDates: [],
          notInRosterNames: [],
          roleMismatchDetails: {'王大明': []},
          otherNames: [],
          nearMatchSuggestions: {},
          notInEventCatalog: [],
        ),
      );

      expect(find.text('・王大明'), findsOneWidget);
      expect(find.text('新增服事至同工'), findsNothing);
    });

    testWidgets('开头就说明这些人已经汇入了，而且只说一次', (tester) async {
      // 这句话是这次改动的重点：名字没有被丢掉。每个区块各讲一遍会变成杂讯。
      await pump(
        tester,
        const RosterImportSummary(
          updated: 13,
          missingDates: [],
          notInRosterNames: ['雅婷'],
          roleMismatchDetails: {
            '王大明': ['招待'],
          },
          otherNames: ['志明'],
          nearMatchSuggestions: {},
          notInEventCatalog: [],
        ),
      );
      expect(find.text('已更新 13 笔服事表'), findsOneWidget);
      expect(find.text('下面的名字都已经排进表里了。'), findsOneWidget);
    });

    RosterImportSummary eventsOnly() => const RosterImportSummary(
      updated: 13,
      missingDates: [],
      notInRosterNames: [],
      roleMismatchDetails: {},
      otherNames: [],
      nearMatchSuggestions: {},
      notInEventCatalog: ['孩童奉献礼', '感恩聚餐'],
    );

    testWidgets('没有颜色的活动可以直接加进活动清单', (tester) async {
      final added = <String>[];
      await pump(
        tester,
        eventsOnly(),
        onAddEvent: (name) async => added.add(name),
      );

      await tester.tap(find.text('加入活动清单').first);
      await tester.pumpAndSettle();

      expect(added, ['孩童奉献礼']);
      expect(find.text('已加入'), findsOneWidget);
      // 另一个还没按，按钮还在。
      expect(find.text('加入活动清单'), findsOneWidget);
    });

    testWidgets('连按两个活动，第二个等第一个写完才开始', (tester) async {
      // 活动清单是整份写回去的，同时写的话后面那笔会把前面的盖掉。
      final first = Completer<void>();
      final started = <String>[];
      await pump(
        tester,
        eventsOnly(),
        onAddEvent: (name) {
          started.add(name);
          return name == '孩童奉献礼' ? first.future : Future.value();
        },
      );

      await tester.tap(find.text('加入活动清单').at(0));
      await tester.pump();
      await tester.tap(find.text('加入活动清单').at(0));
      await tester.pump();
      expect(started, ['孩童奉献礼']);

      first.complete();
      await tester.pumpAndSettle();
      expect(started, ['孩童奉献礼', '感恩聚餐']);
      expect(find.text('已加入'), findsNWidgets(2));
    });

    testWidgets('加入失败时那一列显示原因并可以重试', (tester) async {
      await pump(
        tester,
        eventsOnly(),
        onAddEvent: (name) async => throw const ImportFixException('写入被拒绝'),
      );

      await tester.tap(find.text('加入活动清单').first);
      await tester.pumpAndSettle();

      expect(find.text('写入被拒绝'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });

    testWidgets('不是管理员就不给按钮，并讲清楚谁能加', (tester) async {
      await pump(tester, eventsOnly(), canFix: false);
      expect(find.text('加入活动清单'), findsNothing);
      expect(find.text('只有管理员能加进活动清单。'), findsOneWidget);
      // 活动名称本身还是要列出来。
      expect(find.textContaining('孩童奉献礼'), findsOneWidget);
    });

    testWidgets('外来讲员一行带过，不放进名单里没有这个人', (tester) async {
      await pump(
        tester,
        const RosterImportSummary(
          updated: 13,
          missingDates: [],
          notInRosterNames: ['黄雅婷'],
          roleMismatchDetails: {},
          otherNames: [],
          nearMatchSuggestions: {},
          notInEventCatalog: [],
          guestSpeakerNames: ['周慕恩', '林牧师'],
        ),
      );
      expect(find.text('外来讲员：周慕恩、林牧师'), findsOneWidget);
      expect(find.text('・黄雅婷'), findsOneWidget);
    });

    test('只有外来讲员时，snackbar 上也看得到他们', () {
      // hasIssues 为 false 就不开视窗，只剩 snackbar 这一个地方能讲。
      const summary = RosterImportSummary(
        updated: 13,
        missingDates: [],
        notInRosterNames: [],
        roleMismatchDetails: {},
        otherNames: [],
        nearMatchSuggestions: {},
        notInEventCatalog: [],
        guestSpeakerNames: ['周慕恩', '林牧师'],
      );
      expect(importResultMessage(summary), '已更新 13 笔服事表。外来讲员：周慕恩、林牧师');
    });

    test('没有外来讲员时 snackbar 照旧', () {
      const summary = RosterImportSummary(
        updated: 13,
        missingDates: [],
        notInRosterNames: [],
        roleMismatchDetails: {},
        otherNames: [],
        nearMatchSuggestions: {},
        notInEventCatalog: [],
      );
      expect(importResultMessage(summary), '已更新 13 笔服事表');
    });

    test('只有外来讲员时不算有问题', () {
      const summary = RosterImportSummary(
        updated: 13,
        missingDates: [],
        notInRosterNames: [],
        roleMismatchDetails: {},
        otherNames: [],
        nearMatchSuggestions: {},
        notInEventCatalog: [],
        guestSpeakerNames: ['周慕恩'],
      );
      expect(summary.hasIssues, isFalse);
    });

    for (final canFix in [true, false]) {
      testWidgets('文案不叫使用者去做事（${canFix ? '管理员' : '非管理员'}）', (tester) async {
        // 临时支援的人一年可能就来一次，把他们设成固定班底反而弄脏名单。
        // 要不要补设定是管理者当下的判断，画面只陈述事实，不下指令。
        await pump(
          tester,
          const RosterImportSummary(
            updated: 13,
            missingDates: ['2026-10-03'],
            notInRosterNames: ['雅婷'],
            roleMismatchDetails: {
              '王大明': ['招待'],
            },
            otherNames: ['志明'],
            nearMatchSuggestions: {},
            notInEventCatalog: ['遇火重生营会'],
            guestSpeakerNames: ['周慕恩'],
          ),
          canFix: canFix,
        );

        final copy = tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data ?? '')
            // 按钮本身是动作，不算祈使文案
            .where((s) => s != '新增服事至同工' && s != '加入活动清单')
            .join('\n');
        for (final imperative in ['请', '需要', '要补', '应该', '记得']) {
          expect(
            copy.contains(imperative),
            isFalse,
            reason: '文案里出现了「$imperative」，变成在派工作：\n$copy',
          );
        }
      });
    }

    testWidgets('名单里有很像的，附在那个名字后面，但没有换掉它', (tester) async {
      // 陈志豪还没建帐号，而名单里有陈志明 —— 只差最后一个字。自动换过去
      // 等于把他的服事记到陈志明头上、连上陈志明的 uid，提醒发给错的人。
      await pump(
        tester,
        const RosterImportSummary(
          updated: 13,
          missingDates: [],
          notInRosterNames: ['陈志豪'],
          roleMismatchDetails: {},
          otherNames: [],
          nearMatchSuggestions: {
            '陈志豪': ['陈志明'],
          },
          notInEventCatalog: [],
        ),
      );
      expect(find.text('・陈志豪（名单里有很像的：陈志明）'), findsOneWidget);
    });

    testWidgets('很像的有好几位就全部列出来，不挑一个', (tester) async {
      await pump(
        tester,
        const RosterImportSummary(
          updated: 13,
          missingDates: [],
          notInRosterNames: ['佳芸'],
          roleMismatchDetails: {},
          otherNames: [],
          nearMatchSuggestions: {
            '佳芸': ['陈佳蓉', '林淑芸'],
          },
          notInEventCatalog: [],
        ),
      );
      expect(find.text('・佳芸（名单里有很像的：陈佳蓉、林淑芸）'), findsOneWidget);
    });

    testWidgets('没有很像的就只列名字，不留一个空括号', (tester) async {
      await pump(
        tester,
        const RosterImportSummary(
          updated: 13,
          missingDates: [],
          notInRosterNames: ['阿宝'],
          roleMismatchDetails: {},
          otherNames: [],
          nearMatchSuggestions: {'阿宝': []},
          notInEventCatalog: [],
        ),
      );
      expect(find.text('・阿宝'), findsOneWidget);
    });

    /// 完整比对整句，不用 textContaining 抓片段。
    ///
    /// 这条原本写成 `find.textContaining('下面的人')`，但画面上的字是
    /// 「下面的名字都已经排进表里了。」—— 两者没有子字串关系，所以不管那句
    /// 有没有显示都是绿的，等于什么都没保护。
    const promise = '下面的名字都已经排进表里了。';

    testWidgets('只有日期或活动的问题时，不会冒出那句安抚', (tester) async {
      await pump(
        tester,
        const RosterImportSummary(
          updated: 12,
          missingDates: ['2026-10-03'],
          notInRosterNames: [],
          roleMismatchDetails: {},
          otherNames: [],
          nearMatchSuggestions: {},
          notInEventCatalog: ['遇火重生营会'],
        ),
      );
      expect(find.text(promise), findsNothing);
    });

    testWidgets('有日期没汇入时不敢说「都排进去了」', (tester) async {
      // 未匹配的名单是整份 JSON 的统计，但找不到的日期那几笔根本没写进去，
      // 名字照样会出现在清单上。这时那句话可能是假的。
      await pump(
        tester,
        const RosterImportSummary(
          updated: 12,
          missingDates: ['2026-01-11'],
          notInRosterNames: ['陈访客'],
          roleMismatchDetails: {},
          otherNames: [],
          nearMatchSuggestions: {},
          notInEventCatalog: [],
        ),
      );
      expect(find.text('・陈访客'), findsOneWidget);
      expect(find.text(promise), findsNothing);
    });

    testWidgets('一笔都没更新时更不能说「都排进去了」', (tester) async {
      await pump(
        tester,
        const RosterImportSummary(
          updated: 0,
          missingDates: [],
          notInRosterNames: ['陈访客'],
          roleMismatchDetails: {},
          otherNames: [],
          nearMatchSuggestions: {},
          notInEventCatalog: [],
        ),
      );
      expect(find.text('已更新 0 笔服事表'), findsOneWidget);
      expect(find.text(promise), findsNothing);
    });

    testWidgets('同名多人那一段要讲明没有对到帐号', (tester) async {
      await pump(
        tester,
        const RosterImportSummary(
          updated: 1,
          missingDates: [],
          notInRosterNames: [],
          roleMismatchDetails: {},
          otherNames: ['大明'],
          nearMatchSuggestions: {},
          notInEventCatalog: [],
        ),
      );
      expect(find.text('这一格没有对到帐号，两位都不会在自己的首页看到。'), findsOneWidget);
    });

    testWidgets('ImportFixException 的讯息原文显示，不被压成泛用字串', (tester) async {
      // 「有 2 位同工都叫王大明」这种讯息是唯一有用的资讯，被
      // mapErrorToUserMessage 换成「操作失败，请稍后再试」的话，使用者只会
      // 一直按重试，永远不知道要去帐号管理处理。
      await pump(
        tester,
        mismatchOnly(),
        onAddMinistry: (name, roles) async {
          throw const ImportFixException('有 2 位同工都叫「王大明」，请到帐号管理手动设定');
        },
      );

      await tester.tap(find.text('新增服事至同工'));
      await tester.pumpAndSettle();

      expect(find.text('有 2 位同工都叫「王大明」，请到帐号管理手动设定'), findsOneWidget);
      expect(find.textContaining('操作失败'), findsNothing);
    });

    testWidgets('写入卡住时会逾时，不会整份永远转圈', (tester) async {
      // PWA 断线时 Firestore 的写入 future 不会 resolve。没有逾时的话伫列
      // 的 Completer 永远不 complete，后面每一列都卡在等待、连错误都没有。
      var started = 0;
      await pump(
        tester,
        const RosterImportSummary(
          updated: 1,
          missingDates: [],
          notInRosterNames: [],
          roleMismatchDetails: {
            '李小华': ['司琴', '领诗'],
          },
          otherNames: [],
          nearMatchSuggestions: {},
          notInEventCatalog: [],
        ),
        onAddMinistry: (name, roles) {
          started++;
          if (roles.single == '司琴') return Completer<void>().future; // 永不完成
          return Future<void>.value();
        },
      );

      await tester.tap(find.text('新增服事至同工').first);
      await tester.pump();
      await tester.tap(find.text('新增服事至同工').last);
      await tester.pump();
      expect(started, 1, reason: '第二笔还在排队');

      await tester.pump(fixTimeout + const Duration(seconds: 1));
      await tester.pumpAndSettle();

      expect(started, 2, reason: '第一笔逾时之后伫列要放行，第二笔才跑得到');
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('已新增'), findsOneWidget);
    });

    testWidgets('不出现工程术语', (tester) async {
      // 使用者是同工不是工程师。uid / JSON / Firestore 这种字出现在画面上
      // 就是 bug —— 第一版真的写了「没有帐号就没有 uid」。
      await pump(
        tester,
        const RosterImportSummary(
          updated: 13,
          missingDates: ['2026-10-03'],
          notInRosterNames: ['雅婷'],
          roleMismatchDetails: {
            '王大明': ['招待'],
          },
          otherNames: ['志明'],
          nearMatchSuggestions: {},
          notInEventCatalog: ['遇火重生营会'],
        ),
      );

      final shown = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .join('\n');
      for (final jargon in ['uid', 'UID', 'JSON', 'Firestore', 'null', 'id']) {
        expect(
          shown.contains(jargon),
          isFalse,
          reason: '画面上出现了「$jargon」：\n$shown',
        );
      }
    });
  });
}
