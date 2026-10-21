import 'package:church_staff_pwa/core/types/service_type.dart';
import 'package:church_staff_pwa/features/auth/domain/entities/user.dart';
import 'package:church_staff_pwa/features/auth/domain/repositories/auth_repository.dart';
import 'package:church_staff_pwa/features/auth/presentation/providers/session_provider.dart';
import 'package:church_staff_pwa/features/auth/presentation/screens/profile_screen.dart';
import 'package:church_staff_pwa/features/auth/presentation/screens/user_management_screen.dart';
import 'package:church_staff_pwa/features/roster/presentation/providers/roster_provider.dart';
import 'package:church_staff_pwa/features/roster/presentation/screens/roster_edit_screen.dart';
import 'package:church_staff_pwa/features/roster/presentation/screens/roster_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/in_memory_roster_repository.dart';

/// 权限的三个强制点里，UI 只是最外层的一层 —— 真正挡住写入的是
/// `firestore.rules` 与 `worker/authorize.js`。但入口显不显示决定使用者
/// 会不会撞到一个按了必定失败的按钮，所以这里把「谁看得到什么」钉住。

User _user({
  required UserRole role,
  Set<UserGroup> groups = const {},
  List<UserZoneInfo> zones = const [],
}) => User(
  id: 'u1',
  name: '测试者',
  email: 'a@b.c',
  username: 'tester',
  role: role,
  groups: groups,
  zones: zones,
);

class FakeAuthRepository implements AuthRepository {
  final User? user;
  FakeAuthRepository(this.user);

  @override
  Future<User?> getCachedUser() async => user;

  @override
  Future<User?> getCurrentUser() async => user;

  @override
  Future<void> writeCachedUser(User user) async {}

  @override
  Future<User?> login(String username, String password) async => user;

  @override
  Future<void> logout() async {}

  @override
  Future<void> sendPasswordResetEmail(String email) async {}

  @override
  Future<List<User>> getUsers() async => const [];

  @override
  Future<void> addUser(User user, String password) async {}

  @override
  Future<void> updateUser(User user, {String? password}) async {}

  @override
  Future<void> deleteUser(String id) async {}
}

/// 进入 RosterEditScreen，回报它有没有把人踢出去。
///
/// **Session 必须先还原完毕再挂画面。** SessionProvider 是非同步还原的，而
/// `ChangeNotifierProvider.create` 是 lazy 的 —— 直接在同一棵树里 create 的话
/// provider 要到第一次 build 才被建出来，还原的 microtask 来不及在同一帧的
/// post-frame callback 之前跑完，于是 initState 看到的永远是「没有权限」，
/// 每个测试都被踢出去一次，权限判断等于完全没被测到（把 canEditRoster 改回
/// isAdmin 也不会有任何测试变红）。所以先把 provider 挂在一棵空树上 settle
/// 完，再用 `.value` 挂到真正的画面上。
///
/// 用空的 allowedTypes 进场：画面走 EmptyState 那条早退路径，不必准备
/// TabController 与 roster 资料，但 AppBar 的 actions 照样建出来。
Future<int> _pumpRosterEdit(WidgetTester tester, {required User user}) async {
  final session = SessionProvider(FakeAuthRepository(user));
  final rosters = RosterProvider(InMemoryRosterRepository());

  await tester.pumpWidget(
    ChangeNotifierProvider<SessionProvider>.value(
      value: session,
      child: const MaterialApp(home: SizedBox.shrink()),
    ),
  );
  await tester.pumpAndSettle();
  expect(
    session.isRestoring,
    isFalse,
    reason: 'session 没还原完就挂画面的话，底下的权限断言全都测不到东西',
  );

  var exitCalls = 0;
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SessionProvider>.value(value: session),
        ChangeNotifierProvider<RosterProvider>.value(value: rosters),
      ],
      child: MaterialApp(
        home: RosterEditScreen(
          onExit: () => exitCalls++,
          tabController: null,
          allowedTypes: const [],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return exitCalls;
}

/// 挂上唯读的服事表画面，回报 TabBar 上出现哪几个聚会别。
///
/// 会显示哪些分页是这支测试的重点：它是「只属于青崇／儿主的人却看得到主日」
/// 这个 bug 的回归点。session 一样要先还原完再挂画面（理由见 [_pumpRosterEdit]）。
Future<List<String>> _pumpRosterTabs(
  WidgetTester tester, {
  required User user,
}) async {
  final session = SessionProvider(FakeAuthRepository(user));
  final rosters = RosterProvider(InMemoryRosterRepository());

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
      ],
      child: const MaterialApp(home: RosterScreen()),
    ),
  );
  await tester.pumpAndSettle();

  return tester
      .widgetList<Tab>(find.byType(Tab))
      .map((tab) => (tab.text ?? ''))
      .toList();
}

/// 个人页不需要 PushNotificationService 才能 build（它只在按钮的 handler 里被
/// read），所以这里只给 SessionProvider。版本资讯那个 FutureBuilder 会因为
/// flutter_test 挡掉对外 HTTP 而失败，这对这组断言没有影响。
Future<void> _pumpProfile(WidgetTester tester, {required User user}) async {
  await tester.pumpWidget(
    ChangeNotifierProvider(
      create: (_) => SessionProvider(FakeAuthRepository(user)),
      child: const MaterialApp(home: ProfileScreen()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

Map<String, dynamic> _json(Object? groups) => {
  'id': 'u1',
  'name': '测试者',
  'email': 'a@b.c',
  'username': 'tester',
  'role': 'staff',
  'zones': <dynamic>[],
  // null 代表整个栏位不存在 —— 那是所有既有帐号的形状。
  'groups': ?groups,
};

void main() {
  // hasValidGroups() 只挡得住经过 App 的写入。Firebase console 手改、Admin SDK
  // 脚本、迁移程式都绕得过去，而 fromJson 是整份名单共用的解析路径 —— 这里抛
  // 例外的话，倒的不是那一个人，是所有人的帐号管理与人员选择器。
  group('User.fromJson 解析 groups', () {
    test('没有 groups 栏位（所有既有帐号的形状）', () {
      expect(User.fromJson(_json(null)).groups, isEmpty);
    });

    test('认得的名称照顺序解析出来', () {
      final user = User.fromJson(_json(['calendar-editors', 'roster-editors']));
      expect(user.groups, {UserGroup.rosterEditors, UserGroup.calendarEditors});
    });

    test('认不得的名称丢掉，认得的留著', () {
      final user = User.fromJson(_json(['finance-editors', 'roster-editors']));
      expect(user.groups, {UserGroup.rosterEditors});
    });

    test('groups 是字串而不是阵列：当成没有权限，不抛例外', () {
      expect(User.fromJson(_json('roster-editors')).groups, isEmpty);
    });

    test('groups 是 map：当成没有权限，不抛例外', () {
      expect(User.fromJson(_json({'roster-editors': true})).groups, isEmpty);
    });

    test('阵列里混进非字串：丢掉那一个，不影响其他人', () {
      final user = User.fromJson(_json([42, 'roster-editors', null]));
      expect(user.groups, {UserGroup.rosterEditors});
    });

    // 坏掉的权限栏位不该连带让这个人的身分也读不出来。
    test('groups 坏掉时其余栏位仍然解析得出来', () {
      final user = User.fromJson(_json('坏资料'));
      expect(user.name, '测试者');
      expect(user.role, UserRole.staff);
    });
  });

  group('个人页的权限标签', () {
    testWidgets('被授予的 group 显示成标签', (tester) async {
      await _pumpProfile(
        tester,
        user: _user(role: UserRole.staff, groups: {UserGroup.calendarEditors}),
      );

      expect(find.text('同工'), findsOneWidget);
      expect(find.text('行事历编辑'), findsOneWidget);
      expect(find.text('服事表编辑'), findsNothing);
    });

    testWidgets('没有 group 的人只看到角色标签', (tester) async {
      await _pumpProfile(tester, user: _user(role: UserRole.leader));

      expect(find.text('小组长'), findsOneWidget);
      expect(find.text('行事历编辑'), findsNothing);
      expect(find.text('服事表编辑'), findsNothing);
    });

    // 管理员隐含全部，列出来反而像是只被指定了那几项。
    testWidgets('管理员不列出 group 标签', (tester) async {
      await _pumpProfile(
        tester,
        user: _user(role: UserRole.admin, groups: {UserGroup.rosterEditors}),
      );

      expect(find.text('管理员'), findsOneWidget);
      expect(find.text('服事表编辑'), findsNothing);
    });
  });

  group('使用者列表副标', () {
    test('没有任何 group 的人只显示角色与牧区', () {
      final subtitle = userListSubtitle(_user(role: UserRole.leader), '主日');
      expect(subtitle, '小组长 | 主日');
    });

    // 角色与牧区都是身分，排在一起；编辑权是另一回事，接在最后。
    test('编辑权排在身分（角色＋牧区）后面', () {
      final subtitle = userListSubtitle(
        _user(role: UserRole.staff, groups: {UserGroup.calendarEditors}),
        '主日',
      );
      expect(subtitle, '同工 | 主日 | 可编辑：行事历');
    });

    // 最长的情况：三个牧区都有。标签都是两个字，所以权限还是排得进去。
    test('多个牧区时编辑权仍在最后', () {
      final subtitle = userListSubtitle(
        _user(role: UserRole.staff, groups: {UserGroup.rosterEditors}),
        '主日, 青崇, 儿主',
      );
      expect(subtitle, '同工 | 主日, 青崇, 儿主 | 可编辑：服事表');
    });

    test('两个 group 依 UserGroup 宣告顺序排列', () {
      final subtitle = userListSubtitle(
        _user(
          role: UserRole.staff,
          groups: {UserGroup.calendarEditors, UserGroup.rosterEditors},
        ),
        '',
      );
      expect(subtitle, '同工 | 可编辑：服事表、行事历');
    });

    // 管理员隐含全部，逐项列出反而像是「只被指定了这几项」。
    test('管理员不列出 group，即使文件里有', () {
      final subtitle = userListSubtitle(
        _user(role: UserRole.admin, groups: {UserGroup.rosterEditors}),
        '主日',
      );
      expect(subtitle, '管理员 | 主日');
    });

    test('没有牧区时不会留下多余的分隔线', () {
      expect(userListSubtitle(_user(role: UserRole.member), ''), '组员');
    });
  });

  group('服事表编辑模式的设定按钮', () {
    // settings 的写入权在 firestore.rules 里是 admin only，所以非 admin 看到
    // 这两颗只会按下去然后失败。
    testWidgets('管理员看得到两颗设定按钮', (tester) async {
      final exits = await _pumpRosterEdit(
        tester,
        user: _user(role: UserRole.admin),
      );

      expect(exits, 0);
      expect(find.byIcon(Icons.palette_outlined), findsOneWidget);
      expect(find.byIcon(Icons.list_alt_outlined), findsOneWidget);
    });

    testWidgets('服事表编辑者进得来，但看不到设定按钮', (tester) async {
      final exits = await _pumpRosterEdit(
        tester,
        user: _user(role: UserRole.staff, groups: {UserGroup.rosterEditors}),
      );

      expect(exits, 0, reason: '有 roster-editors 就不该被挡在编辑模式外');
      expect(find.byIcon(Icons.palette_outlined), findsNothing);
      expect(find.byIcon(Icons.list_alt_outlined), findsNothing);
      expect(find.byTooltip('切换至检视模式'), findsOneWidget);
    });
  });

  // 编辑权（group）跟牧区（zones）是两个轴：group 决定「能不能改」，牧区决定
  // 「能改哪一本」。曾经给了 roster-editors 就整组聚会别全开 —— 只属于青崇／
  // 儿主的人因此看得到主日。
  group('服事表的聚会别范围', () {
    test('一般人只拿到自己的牧区', () {
      final user = _user(
        role: UserRole.member,
        zones: const [UserZoneInfo(serviceType: ServiceType.youth)],
      );
      expect(user.allowedRosterTypes, [ServiceType.youth]);
    });

    test('服事表编辑者一样只拿到自己的牧区', () {
      final user = _user(
        role: UserRole.staff,
        groups: {UserGroup.rosterEditors},
        zones: const [
          UserZoneInfo(serviceType: ServiceType.youth),
          UserZoneInfo(serviceType: ServiceType.children),
        ],
      );
      expect(user.allowedRosterTypes, [
        ServiceType.youth,
        ServiceType.children,
      ]);
      expect(
        user.allowedRosterTypes,
        isNot(contains(ServiceType.sundayService)),
      );
    });

    // admin 等同 root：一个牧区都没有也拿得到全部。
    test('管理员没有任何牧区也拿得到全部', () {
      expect(
        _user(role: UserRole.admin).allowedRosterTypes,
        ServiceType.values,
      );
    });

    test('没有牧区的编辑者拿到空的', () {
      final user = _user(
        role: UserRole.staff,
        groups: {UserGroup.rosterEditors},
      );
      expect(user.allowedRosterTypes, isEmpty);
    });

    // zoneTypes 是写进 Firestore 给 firestore.rules 用的投影。顺序跟著
    // ServiceType.values，否则同样的内容换个顺序就是一笔多余的写入。
    test('toJson 带出 zoneTypes，顺序固定', () {
      final user = _user(
        role: UserRole.staff,
        zones: const [
          UserZoneInfo(serviceType: ServiceType.children),
          UserZoneInfo(serviceType: ServiceType.sundayService),
        ],
      );
      expect(user.toJson()['zoneTypes'], ['sundayService', 'children']);
    });

    test('没有牧区时 zoneTypes 是空阵列', () {
      expect(_user(role: UserRole.member).toJson()['zoneTypes'], isEmpty);
    });
  });

  group('服事表分页只出现自己的牧区', () {
    testWidgets('只属于青崇与儿主的编辑者看不到主日', (tester) async {
      final tabs = await _pumpRosterTabs(
        tester,
        user: _user(
          role: UserRole.staff,
          groups: {UserGroup.rosterEditors},
          zones: const [
            UserZoneInfo(serviceType: ServiceType.youth),
            UserZoneInfo(serviceType: ServiceType.children),
          ],
        ),
      );

      expect(tabs, ['青崇', '儿主']);
    });

    testWidgets('管理员看得到全部', (tester) async {
      final tabs = await _pumpRosterTabs(
        tester,
        user: _user(role: UserRole.admin),
      );

      expect(tabs, ['主日', '青崇', '儿主']);
    });

    testWidgets('没有牧区的编辑者看到的是空状态，不是全部', (tester) async {
      final tabs = await _pumpRosterTabs(
        tester,
        user: _user(role: UserRole.staff, groups: {UserGroup.rosterEditors}),
      );

      expect(tabs, isEmpty);
      expect(find.text('尚未设置可查看的牧区'), findsOneWidget);
    });
  });

  group('进入编辑模式的权限闸', () {
    // 钉的是 roster_edit_screen initState 的守卫本身。把它改回 isAdmin，
    // 「服事表编辑者进得来」那条会红。
    testWidgets('只有行事历 group 的人会被踢出去', (tester) async {
      final exits = await _pumpRosterEdit(
        tester,
        user: _user(role: UserRole.staff, groups: {UserGroup.calendarEditors}),
      );

      expect(exits, 1);
      expect(find.text('没有权限进入编辑模式'), findsOneWidget);
    });

    testWidgets('没有任何 group 的小组长会被踢出去', (tester) async {
      final exits = await _pumpRosterEdit(
        tester,
        user: _user(role: UserRole.leader),
      );

      expect(exits, 1);
    });
  });
}
