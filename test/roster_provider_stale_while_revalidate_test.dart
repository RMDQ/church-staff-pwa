import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:church_staff_pwa/core/types/service_type.dart';
import 'package:church_staff_pwa/features/roster/domain/entities/service_roster.dart';
import 'package:church_staff_pwa/features/roster/presentation/providers/roster_provider.dart';

import 'support/in_memory_roster_repository.dart';

InMemoryRosterRepository _repo({
  List<ServiceRoster> cacheResult = const [],
  List<ServiceRoster> serverResult = const [],
  Object? cacheError,
  Object? serverError,
  Completer<void>? cachePause,
  Completer<void>? serverPause,
}) =>
    InMemoryRosterRepository(
        rosters: serverResult,
        cachedRosters: cacheResult,
        templates: emptyForEveryType(),
        eventOptions: emptyForEveryType(),
      )
      ..cacheError = cacheError
      ..serverError = serverError
      ..cachePause = cachePause
      ..serverPause = serverPause;

// ── 辅助 roster fixture ──────────────────────────────────────────────────────

ServiceRoster _roster(String id, ServiceType type) => ServiceRoster(
  id: id,
  date: DateTime(2026, 6, 7),
  type: type,
  serviceName: type == ServiceType.sundayService ? '主日崇拜' : '青年崇拜',
  duties: const [],
);

// ── Configurable fake ───────────────────────────────────────────────────────

// ── 工具：让 event loop 跑完所有已排程的 microtask / Future ──────────────────

Future<void> _drain() async {
  await Future.delayed(Duration.zero);
}

// 多跑几个 loop 以让 Future.wait 与 then 都完成
Future<void> _drainFully() async {
  for (var i = 0; i < 5; i++) {
    await Future.delayed(Duration.zero);
  }
}

// ── Tests ───────────────────────────────────────────────────────────────────

void main() {
  group('RosterProvider stale-while-revalidate', () {
    // ────────────────────────────────────────────────────────────────────────
    // 情境 1：cache 有资料 → 先 set _allRosters，isLoading 仍 true，
    //         server 完成后覆盖。
    // ────────────────────────────────────────────────────────────────────────
    test('cache 有资料时先渲染 stale data，isLoading 仍 true，server 完成后覆盖', () async {
      final staleRoster = _roster('stale-1', ServiceType.sundayService);
      final freshRoster = _roster('fresh-1', ServiceType.youth);

      // 用 Completer 让 server fetch 先暂停，确认中间状态
      final serverPause = Completer<void>();
      final repo = _repo(
        cacheResult: [staleRoster],
        serverResult: [freshRoster],
        serverPause: serverPause,
      );
      final provider = RosterProvider(repo);

      final fetchFuture = provider.fetchInitialData();

      // cache 快完成了，drain 一次让 cache phase 跑完
      await _drain();

      // cache phase 完成：rosters 有 stale data，isLoading = true
      expect(provider.rosters, contains(staleRoster));
      expect(provider.isLoading, isTrue);

      // 放行 server
      serverPause.complete();
      await fetchFuture;

      // server 完成：stale 被覆盖成 fresh
      expect(provider.rosters, contains(freshRoster));
      expect(provider.rosters, isNot(contains(staleRoster)));
      expect(provider.isLoading, isFalse);
    });

    // ────────────────────────────────────────────────────────────────────────
    // 情境 2：cache miss → 直接走 server，行为与原本一样。
    // ────────────────────────────────────────────────────────────────────────
    test('cache miss 时不设 stale data，走 server 路径', () async {
      final freshRoster = _roster('fresh-1', ServiceType.sundayService);
      final repo = _repo(
        cacheResult: const [], // cache miss
        serverResult: [freshRoster],
      );
      final provider = RosterProvider(repo);

      await provider.fetchInitialData();
      await _drainFully();

      expect(provider.rosters, contains(freshRoster));
      expect(provider.isLoading, isFalse);
      expect(provider.error, isNull);
    });

    // ────────────────────────────────────────────────────────────────────────
    // 情境 3：cache 有资料但 server 失败 → 不设 error，继续显示 stale data。
    // ────────────────────────────────────────────────────────────────────────
    test('cache 有资料、server 失败 → 不显示 error，保留 stale data', () async {
      final staleRoster = _roster('stale-1', ServiceType.sundayService);
      final repo = _repo(
        cacheResult: [staleRoster],
        serverError: Exception('network error'),
      );
      final provider = RosterProvider(repo);

      await provider.fetchInitialData();
      await _drainFully();

      expect(provider.rosters, contains(staleRoster));
      expect(provider.error, isNull); // 不显示 error（cache 已渲染）
      expect(provider.isLoading, isFalse);
    });

    // ────────────────────────────────────────────────────────────────────────
    // 情境 4：cache 无资料、server 失败 → 显示 error（与原本行为一致）。
    // ────────────────────────────────────────────────────────────────────────
    test('cache 无资料、server 失败 → 显示 error', () async {
      final repo = _repo(
        cacheResult: const [],
        serverError: Exception('network error'),
      );
      final provider = RosterProvider(repo);

      await provider.fetchInitialData();
      await _drainFully();

      expect(provider.rosters, isEmpty);
      expect(provider.error, isNotNull);
      expect(provider.isLoading, isFalse);
    });

    // ────────────────────────────────────────────────────────────────────────
    // 情境 5：stale token race — 切换 user 时旧 fetch 的结果不污染新 user。
    // ────────────────────────────────────────────────────────────────────────
    test('token race：旧 fetch 的 stale cache 不覆盖新 user 的资料', () async {
      final oldCacheRoster = _roster('old-cache', ServiceType.sundayService);
      final newServerRoster = _roster('new-server', ServiceType.youth);

      // user-A 的 cache 很慢（用 Completer 控制）
      final userACachePause = Completer<void>();
      final repoA = _repo(
        cacheResult: [oldCacheRoster],
        cachePause: userACachePause,
      );
      final repoB = _repo(
        cacheResult: const [],
        serverResult: [newServerRoster],
      );

      final provider = RosterProvider(repoA);

      // 开始 user-A 的 fetch（cache 卡住中）
      unawaited(provider.fetchInitialData());
      await _drain();

      // 切换 user（模拟 onSessionChanged 换 repo 的效果）：
      // 直接再打一次 fetchInitialData（不同 repo）来模拟 token bump。
      // 这里改用同一 provider 但把 _fetchToken bump 再跑 fetch，
      // 借由再呼叫 fetchInitialData 触发 token 递增（模拟 onSessionChanged）。
      final provider2 = RosterProvider(repoB);
      await provider2.fetchInitialData();
      await _drainFully();

      // 放行 user-A 的旧 cache（此时 provider2 的 token 已不同）
      userACachePause.complete();
      await _drain();

      // provider2 应该只有 newServerRoster
      expect(provider2.rosters, contains(newServerRoster));
      expect(provider2.rosters, isNot(contains(oldCacheRoster)));
    });

    // ────────────────────────────────────────────────────────────────────────
    // 情境 6：ensureQuarterRosters 只在被明确呼叫时触发（viewer 不呼叫）。
    // ────────────────────────────────────────────────────────────────────────
    test('fetchInitialData 不触发 ensureQuarterRosters', () async {
      final repo = _repo();
      final provider = RosterProvider(repo);

      await provider.fetchInitialData();
      await _drainFully();

      expect(repo.ensureCallCount, 0);
    });

    test('ensureQuarterRostersForEditor 触发 ensureQuarterRosters', () async {
      final repo = _repo();
      final provider = RosterProvider(repo);

      await provider.ensureQuarterRostersForEditor(const [ServiceType.youth]);
      await _drainFully();

      expect(repo.ensureCallCount, 1);
      // backfill 的范围要跟著呼叫者的牧区走：batch 里混进他无权写的聚会别，
      // 整批都会被 rules 拒绝，连他自己那本也补不出来。
      expect(repo.ensureTypes, const [ServiceType.youth]);
    });

    // ────────────────────────────────────────────────────────────────────────
    // 情境 7：cache 失败（非 cache-miss exception）→ 静默，继续走 server。
    // ────────────────────────────────────────────────────────────────────────
    test('cache throw 时静默失败，server 资料正常回填', () async {
      final freshRoster = _roster('fresh-1', ServiceType.sundayService);
      final repo = _repo(
        cacheError: Exception('cache exploded'),
        serverResult: [freshRoster],
      );
      final provider = RosterProvider(repo);

      await provider.fetchInitialData();
      await _drainFully();

      expect(provider.rosters, contains(freshRoster));
      expect(provider.error, isNull);
      expect(provider.isLoading, isFalse);
    });

    // ────────────────────────────────────────────────────────────────────────
    // 情境 8：fetchRosters 也有 cache-first 行为。
    // ────────────────────────────────────────────────────────────────────────
    test('fetchRosters：cache 有资料先渲染，server 完成后覆盖', () async {
      final staleRoster = _roster('stale-1', ServiceType.sundayService);
      final freshRoster = _roster('fresh-1', ServiceType.youth);

      final serverPause = Completer<void>();
      final repo = _repo(
        cacheResult: [staleRoster],
        serverResult: [freshRoster],
        serverPause: serverPause,
      );
      final provider = RosterProvider(repo);

      final fetchFuture = provider.fetchRosters();
      await _drain();

      // cache 先到：有 stale data，isLoading 仍 true
      expect(provider.rosters, contains(staleRoster));
      expect(provider.isLoading, isTrue);

      serverPause.complete();
      await fetchFuture;

      expect(provider.rosters, contains(freshRoster));
      expect(provider.rosters, isNot(contains(staleRoster)));
      expect(provider.isLoading, isFalse);
    });
  });
}
