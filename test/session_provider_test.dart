import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:church_staff_pwa/features/auth/domain/entities/user.dart';
import 'package:church_staff_pwa/features/auth/domain/repositories/auth_repository.dart';
import 'package:church_staff_pwa/features/auth/presentation/providers/session_provider.dart';

// ── Fake AuthRepository ────────────────────────────────────────────────────

class _FakeAuthRepository implements AuthRepository {
  /// 若不为 null，`login` 回传此 user（模拟成功）。
  /// 若为 null，`login` 回传 null（模拟帐密错误）。
  User? loginResult;

  /// 若不为 null，`login` 会 throw 此例外。
  Object? loginException;

  /// `getCurrentUser` 回传值（模拟 session restore）。
  User? currentUserResult;

  /// 若不为 null，`getCurrentUser` 会 throw 此例外。
  Object? getCurrentUserException;

  /// `getCachedUser` 回传值（模拟快取 user）。
  User? cachedUserResult;

  /// 若 true，`getCurrentUser` 会永不完成（用于测试 optimistic path）。
  bool getCurrentUserBlocks = false;

  bool logoutCalled = false;

  /// 若不为 null，`logout` 会 throw 此例外。
  Object? logoutException;

  /// Every address passed to [sendPasswordResetEmail], in call order.
  final List<String> resetEmails = [];

  /// 若不为 null，`sendPasswordResetEmail` 会 throw 此例外。
  Object? resetException;

  /// Records every user passed to [writeCachedUser] in call order.
  final List<User> writeCachedUserCalls = [];

  /// When non-null, [getCurrentUser] waits for this completer before
  /// returning [currentUserResult].  Allows tests to control exactly when the
  /// background fetch resolves.
  Completer<void>? getCurrentUserCompleter;

  @override
  Future<User?> login(String username, String password) async {
    if (loginException != null) throw loginException!;
    return loginResult;
  }

  @override
  Future<User?> getCurrentUser() async {
    if (getCurrentUserBlocks) {
      // Never completes — simulates a slow/hanging network call.
      await Completer<void>().future;
    }
    if (getCurrentUserCompleter != null) {
      await getCurrentUserCompleter!.future;
    }
    if (getCurrentUserException != null) throw getCurrentUserException!;
    return currentUserResult;
  }

  @override
  Future<User?> getCachedUser() async => cachedUserResult;

  @override
  Future<void> writeCachedUser(User user) async {
    writeCachedUserCalls.add(user);
  }

  @override
  Future<void> logout() async {
    logoutCalled = true;
    if (logoutException != null) throw logoutException!;
  }

  @override
  Future<void> sendPasswordResetEmail(String email) async {
    resetEmails.add(email);
    if (resetException != null) throw resetException!;
  }

  @override
  Future<List<User>> getUsers() async => [];

  @override
  Future<void> addUser(User user, String password) async {}

  @override
  Future<void> updateUser(User user, {String? password}) async {}

  @override
  Future<void> deleteUser(String id) async {}
}

// ── 测试用 User helper ──────────────────────────────────────────────────────

const _userAlpha = User(
  id: 'uid-alpha',
  name: 'Alpha User',
  email: 'alpha@example.com',
  username: 'alpha',
  role: UserRole.admin,
);

const _userBeta = User(
  id: 'uid-beta',
  name: 'Beta User',
  email: 'beta@example.com',
  username: 'beta',
  role: UserRole.staff,
);

// 只被授予行事历 group 的一般同工：权限跟 role 没有关系，这是整个模型的重点。
const _userCalendarEditor = User(
  id: 'uid-cal',
  name: 'Calendar Editor',
  email: 'cal@example.com',
  username: 'cal',
  role: UserRole.staff,
  groups: {UserGroup.calendarEditors},
);

// 反过来的例子：身分是小组长，但没有被授予任何 group。
const _userPlainLeader = User(
  id: 'uid-leader',
  name: 'Leader User',
  email: 'leader@example.com',
  username: 'leader',
  role: UserRole.leader,
);

// ── Tests ──────────────────────────────────────────────────────────────────

void main() {
  group('SessionProvider', () {
    late _FakeAuthRepository repo;

    setUp(() {
      repo = _FakeAuthRepository();
    });

    // 等 _restoreSession Phase 1 完成（isRestoring 变 false）的辅助方法。
    //
    // 无 cache 路径需要两个连续 async hop（getCachedUser + getCurrentUser），
    // 所以等多个 microtask cycle 直到 isRestoring 变 false。
    Future<SessionProvider> createAndWait({User? currentUser}) async {
      repo.currentUserResult = currentUser;
      final provider = SessionProvider(repo);
      // pump microtasks until isRestoring is false (up to a reasonable limit)
      for (var i = 0; i < 10 && provider.isRestoring; i++) {
        await Future.microtask(() {});
      }
      return provider;
    }

    // ── sendPasswordReset ────────────────────────────────────────────────

    test('sendPasswordReset 成功回传 null，且不动登入的 isLoading／error', () async {
      final provider = await createAndWait();
      final result = await provider.sendPasswordReset('a@example.com');
      expect(result, isNull);
      expect(repo.resetEmails, ['a@example.com']);
      expect(provider.isLoading, false);
      expect(provider.error, isNull);
    });

    test('sendPasswordReset 失败回传讯息，不写进登入错误', () async {
      repo.resetException = Exception('boom');
      final provider = await createAndWait();
      final result = await provider.sendPasswordReset('a@example.com');
      expect(result, '无法寄出重设信，请稍后再试');
      expect(provider.error, isNull);
    });

    // ── _restoreSession ──────────────────────────────────────────────────

    test('constructor 触发 _restoreSession；完成后 isRestoring 变 false', () async {
      final provider = await createAndWait();
      expect(provider.isRestoring, false);
    });

    test('_restoreSession 成功时 currentUser 对应 repository 回传值', () async {
      final provider = await createAndWait(currentUser: _userAlpha);
      expect(provider.currentUser, _userAlpha);
      expect(provider.isAuthenticated, true);
    });

    test('_restoreSession：repository 回传 null 时 currentUser 为 null', () async {
      final provider = await createAndWait();
      expect(provider.currentUser, isNull);
      expect(provider.isAuthenticated, false);
    });

    // ── login 成功 ────────────────────────────────────────────────────────

    test(
      'login 成功 → isAuthenticated true、currentUser 不为 null、error 为 null',
      () async {
        repo.loginResult = _userAlpha;
        final provider = await createAndWait();

        final result = await provider.login('alpha', 'password123');

        expect(result, true);
        expect(provider.isAuthenticated, true);
        expect(provider.currentUser, _userAlpha);
        expect(provider.error, isNull);
      },
    );

    test('login 成功后 isLoading 回到 false', () async {
      repo.loginResult = _userAlpha;
      final provider = await createAndWait();
      await provider.login('alpha', 'pass');
      expect(provider.isLoading, false);
    });

    // ── login 失败（repository 回传 null）────────────────────────────────

    test('login 失败（repository 回传 null）→ error 为「帐号或密码错误」', () async {
      repo.loginResult = null;
      final provider = await createAndWait();

      final result = await provider.login('wrong', 'wrongpass');

      expect(result, false);
      expect(provider.error, '帐号或密码错误');
      expect(provider.isAuthenticated, false);
    });

    test('login 失败后 isLoading 回到 false', () async {
      repo.loginResult = null;
      final provider = await createAndWait();
      await provider.login('wrong', 'wrong');
      expect(provider.isLoading, false);
    });

    // ── login 抛出例外 ────────────────────────────────────────────────────

    test('login 抛 Exception → error 含「登入失败:」前缀', () async {
      repo.loginException = Exception('Network error');
      final provider = await createAndWait();

      final result = await provider.login('user', 'pass');

      expect(result, false);
      expect(provider.error, startsWith('登入失败:'));
      expect(provider.isAuthenticated, false);
    });

    test('login 抛例外后 isLoading 回到 false', () async {
      repo.loginException = Exception('timeout');
      final provider = await createAndWait();
      await provider.login('u', 'p');
      expect(provider.isLoading, false);
    });

    // ── logout ────────────────────────────────────────────────────────────

    test('logout → currentUser 为 null', () async {
      final provider = await createAndWait(currentUser: _userAlpha);
      await provider.logout();
      expect(provider.currentUser, isNull);
      expect(provider.isAuthenticated, false);
    });

    test('logout → 呼叫了 repository.logout', () async {
      final provider = await createAndWait(currentUser: _userAlpha);
      await provider.logout();
      expect(repo.logoutCalled, true);
    });

    test('logout 后 isLoading 回到 false', () async {
      final provider = await createAndWait(currentUser: _userAlpha);
      await provider.logout();
      expect(provider.isLoading, false);
    });

    test('logout 后 isRestoring 为 false', () async {
      final provider = await createAndWait(currentUser: _userAlpha);
      await provider.logout();
      expect(provider.isRestoring, false);
    });

    test('logout 失败时保留登入状态并回报错误，且不卡在 isLoading', () async {
      // 登出失败却清掉 currentUser 的话，App 会跳回登入画面、使用者以为已经
      // 登出，但 Firebase Auth session 还活著 —— 共用装置上下一个人重开就直接
      // 进到前一个人的帐号。所以失败时必须维持登入状态。
      final provider = await createAndWait(currentUser: _userAlpha);
      repo.logoutException = Exception('signOut failed');

      await provider.logout();

      expect(provider.currentUser, isNotNull);
      expect(provider.isAuthenticated, true);
      expect(provider.isLoading, false);
      expect(provider.error, isNotNull);
    });

    test('clearError 清掉登出失败留下的错误，避免残留到登入画面', () async {
      final provider = await createAndWait(currentUser: _userAlpha);
      repo.logoutException = Exception('signOut failed');
      await provider.logout();
      expect(provider.error, isNotNull);

      provider.clearError();

      expect(provider.error, isNull);
    });

    // ── refreshCurrentUser ────────────────────────────────────────────────

    test('refreshCurrentUser：id 相符时更新 currentUser', () async {
      final provider = await createAndWait(currentUser: _userAlpha);
      final updatedAlpha = _userAlpha.copyWith(name: 'Alpha Updated');
      provider.refreshCurrentUser(updatedAlpha);
      expect(provider.currentUser?.name, 'Alpha Updated');
    });

    test('refreshCurrentUser：id 不符时 currentUser 不变', () async {
      final provider = await createAndWait(currentUser: _userAlpha);
      provider.refreshCurrentUser(_userBeta);
      // _userBeta.id != _userAlpha.id，不应更新
      expect(provider.currentUser, _userAlpha);
    });

    test('refreshCurrentUser：currentUser 为 null 时呼叫不崩溃', () async {
      final provider = await createAndWait(); // currentUser = null
      expect(() => provider.refreshCurrentUser(_userAlpha), returnsNormally);
      expect(provider.currentUser, isNull);
    });

    // ── isAdmin ───────────────────────────────────────────────────────────

    test('isAdmin：user role 为 admin 时回传 true', () async {
      final provider = await createAndWait(currentUser: _userAlpha);
      expect(provider.isAdmin, true);
    });

    test('isAdmin：user role 非 admin 时回传 false', () async {
      final provider = await createAndWait(currentUser: _userBeta);
      expect(provider.isAdmin, false);
    });

    test('isAdmin：未登入时回传 false', () async {
      final provider = await createAndWait();
      expect(provider.isAdmin, false);
    });

    // ── 编辑权限（group）────────────────────────────────────────────────
    //
    // 这组测试钉的是「权限不看 role」：小组长没有 group 就不能编，同工有
    // group 就能编。把 canEditCalendar 写回 role 判断会整组变红。

    test('admin 隐含所有 group', () async {
      final provider = await createAndWait(currentUser: _userAlpha);
      expect(provider.canEditRoster, true);
      expect(provider.canEditCalendar, true);
    });

    test('被授予行事历 group 的同工可以编行事历，但不能编服事表', () async {
      final provider = await createAndWait(currentUser: _userCalendarEditor);
      expect(provider.canEditCalendar, true);
      expect(provider.canEditRoster, false);
      expect(provider.isAdmin, false);
    });

    test('身分是小组长但没有任何 group：两项都不能编', () async {
      final provider = await createAndWait(currentUser: _userPlainLeader);
      expect(provider.canEditCalendar, false);
      expect(provider.canEditRoster, false);
    });

    test('未登入时两项都是 false', () async {
      final provider = await createAndWait();
      expect(provider.canEditCalendar, false);
      expect(provider.canEditRoster, false);
    });

    // ── Level 2: getCachedUser optimistic path ─────────────────────────────

    test('cache 有资料 → isRestoring 立刻变 false，currentUser 为 cached user'
        '（即使 getCurrentUser 永不完成）', () async {
      // Arrange: cache 有 alpha；getCurrentUser 永远卡住不回来
      repo.cachedUserResult = _userAlpha;
      repo.getCurrentUserBlocks = true;

      final provider = SessionProvider(repo);

      // Phase 1 只需要 getCachedUser() 的 async hop（trivial），
      // pump 直到 isRestoring 变 false（Phase 2 永不完成，不会干扰）。
      for (var i = 0; i < 10 && provider.isRestoring; i++) {
        await Future.microtask(() {});
      }

      // Phase 1 应已完成：isRestoring = false，currentUser = cached
      expect(provider.isRestoring, false);
      expect(provider.currentUser, _userAlpha);
    });

    // 等背景 Phase 2 完成的辅助：pump microtask 直到 currentUser 更新或达上限。
    Future<void> pumpUntilPhase2Done(
      SessionProvider provider,
      User? expected,
    ) async {
      for (var i = 0; i < 10; i++) {
        await Future.microtask(() {});
        if (provider.currentUser == expected) break;
      }
    }

    test('背景 fetch 成功（同 id）→ currentUser 更新为 fresh user', () async {
      // Arrange: cache 有 alpha；background getCurrentUser 也回传 alpha（可有栏位更新）
      final freshAlpha = _userAlpha.copyWith(name: 'Alpha Fresh');
      repo.cachedUserResult = _userAlpha;
      repo.currentUserResult = freshAlpha;

      final provider = SessionProvider(repo);

      // 等 Phase 1（cache read）完成
      for (var i = 0; i < 10 && provider.isRestoring; i++) {
        await Future.microtask(() {});
      }
      expect(provider.currentUser, _userAlpha); // 先是 cached

      // 等 Phase 2（background getCurrentUser）完成
      await pumpUntilPhase2Done(provider, freshAlpha);

      expect(provider.currentUser, freshAlpha);
    });

    test('背景 fetch 回 null → currentUser 变 null（session 失效）', () async {
      // Arrange: cache 有 alpha；background fetch 回 null（帐号被删）
      repo.cachedUserResult = _userAlpha;
      repo.currentUserResult = null;

      final provider = SessionProvider(repo);

      // Phase 1
      for (var i = 0; i < 10 && provider.isRestoring; i++) {
        await Future.microtask(() {});
      }
      expect(provider.currentUser, _userAlpha);

      // Phase 2
      await pumpUntilPhase2Done(provider, null);

      expect(provider.currentUser, isNull);
      expect(provider.isAuthenticated, false);
    });

    test('背景 fetch throw → 保留 cached user，不爆 error、不登出', () async {
      // Arrange: cache 有 alpha；background fetch 抛例外（例如网路断线）
      repo.cachedUserResult = _userAlpha;
      repo.getCurrentUserException = Exception('network error');

      final provider = SessionProvider(repo);

      // Phase 1
      for (var i = 0; i < 10 && provider.isRestoring; i++) {
        await Future.microtask(() {});
      }
      expect(provider.currentUser, _userAlpha);

      // Phase 2 (background throws, should be swallowed)
      // pump a few microtasks to let the background Future run and throw
      for (var i = 0; i < 5; i++) {
        await Future.microtask(() {});
      }

      // Cached user must still be present; error field must be null
      expect(provider.currentUser, _userAlpha);
      expect(provider.error, isNull);
      expect(provider.isAuthenticated, true);
    });

    // ── user-switch race (#1 / #4) ────────────────────────────────────────

    test(
      '背景 fetch 进行中 logout → late-arriving fresh 不覆盖 null（expectedId guard）',
      () async {
        // Arrange: cache 有 alpha；background fetch 用 Completer 卡住。
        final completer = Completer<void>();
        repo.cachedUserResult = _userAlpha;
        repo.getCurrentUserCompleter = completer;
        // fresh result that will eventually come back — should be discarded
        repo.currentUserResult = _userAlpha.copyWith(name: 'Alpha Stale Fresh');

        final provider = SessionProvider(repo);

        // Phase 1 完成
        for (var i = 0; i < 10 && provider.isRestoring; i++) {
          await Future.microtask(() {});
        }
        expect(provider.currentUser, _userAlpha);

        // 使用者在 background fetch 完成前登出
        await provider.logout();
        expect(provider.currentUser, isNull);

        // 放行 background fetch（late-arriving）
        completer.complete();
        // pump 让背景 Future 执行完毕
        for (var i = 0; i < 10; i++) {
          await Future.microtask(() {});
        }

        // late-arriving fetch 不应把 currentUser 从 null 改回 alpha
        expect(provider.currentUser, isNull);
        expect(provider.isAuthenticated, false);
      },
    );

    test('背景 fetch 进行中切换帐号（login B）→ late-arriving A fresh 不覆盖 B', () async {
      // Arrange: cache 有 alpha；background fetch 用 Completer 卡住。
      final completer = Completer<void>();
      repo.cachedUserResult = _userAlpha;
      repo.getCurrentUserCompleter = completer;
      repo.currentUserResult = _userAlpha.copyWith(name: 'Alpha Stale Fresh');

      final provider = SessionProvider(repo);

      // Phase 1 完成
      for (var i = 0; i < 10 && provider.isRestoring; i++) {
        await Future.microtask(() {});
      }
      expect(provider.currentUser, _userAlpha);

      // 帐号切换：先登出，再登入 beta
      await provider.logout();
      // 停止卡住后的 getCurrentUser 直接回传（不再卡）
      repo.getCurrentUserCompleter = null;
      repo.loginResult = _userBeta;
      await provider.login('beta', 'pass');
      expect(provider.currentUser, _userBeta);

      // 放行原本卡住的 alpha background fetch
      completer.complete();
      for (var i = 0; i < 10; i++) {
        await Future.microtask(() {});
      }

      // currentUser 应仍是 beta，不被 alpha stale data 覆盖
      expect(provider.currentUser, _userBeta);
      expect(provider.currentUser?.id, 'uid-beta');
    });

    test('背景 fetch 进行中切换帐号 → stale A 的 writeCachedUser 不被呼叫', () async {
      // Arrange: cache 有 alpha；background fetch 用 Completer 卡住。
      final completer = Completer<void>();
      repo.cachedUserResult = _userAlpha;
      repo.getCurrentUserCompleter = completer;
      repo.currentUserResult = _userAlpha.copyWith(name: 'Alpha Stale Fresh');

      final provider = SessionProvider(repo);

      // Phase 1 完成
      for (var i = 0; i < 10 && provider.isRestoring; i++) {
        await Future.microtask(() {});
      }

      // 登出，切换到 beta
      await provider.logout();
      repo.getCurrentUserCompleter = null;
      repo.loginResult = _userBeta;
      await provider.login('beta', 'pass');

      // 清除 login 产生的 writeCachedUser 纪录（login 直接写 cache 是正确的）
      // 注意：login 走 repository.login → _cachedUserStorage.write 那条，
      // 不走 writeCachedUser，所以 writeCachedUserCalls 此时应仍为空。
      expect(repo.writeCachedUserCalls, isEmpty);

      // 放行 stale alpha fetch
      completer.complete();
      for (var i = 0; i < 10; i++) {
        await Future.microtask(() {});
      }

      // stale alpha 的 writeCachedUser 不应被呼叫（guard 挡住了）
      expect(repo.writeCachedUserCalls, isEmpty);
    });

    test('背景 fetch 正常完成（无切换）→ writeCachedUser 被呼叫一次且带 fresh user', () async {
      // Arrange: cache 有 alpha；background fetch 正常回传 freshAlpha
      final freshAlpha = _userAlpha.copyWith(name: 'Alpha Fresh');
      repo.cachedUserResult = _userAlpha;
      repo.currentUserResult = freshAlpha;

      final provider = SessionProvider(repo);

      // Phase 1
      for (var i = 0; i < 10 && provider.isRestoring; i++) {
        await Future.microtask(() {});
      }

      // Phase 2
      await pumpUntilPhase2Done(provider, freshAlpha);

      expect(provider.currentUser, freshAlpha);
      // writeCachedUser 应被呼叫一次，带 freshAlpha
      expect(repo.writeCachedUserCalls.length, 1);
      expect(repo.writeCachedUserCalls.first, freshAlpha);
    });
  });
}
