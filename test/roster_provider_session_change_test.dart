import 'package:flutter_test/flutter_test.dart';

import 'package:church_staff_pwa/core/types/service_type.dart';
import 'package:church_staff_pwa/features/roster/domain/entities/service_roster.dart';
import 'package:church_staff_pwa/features/roster/presentation/providers/roster_provider.dart';

import 'support/in_memory_roster_repository.dart';

InMemoryRosterRepository _repo() => InMemoryRosterRepository(
  templates: emptyForEveryType(),
  eventOptions: emptyForEveryType(),
);

// ── Fake RosterRepository（记录呼叫次数）──────────────────────────────────

// ── 辅助：等待 provider 的非同步 fetch 跑完 ──────────────────────────────────

Future<void> _drainAsync() async {
  // 给 Future.wait + microtask 至少一个 event loop 完成
  await Future.delayed(Duration.zero);
}

// ── Tests ──────────────────────────────────────────────────────────────────

void main() {
  group('RosterProvider.onSessionChanged', () {
    late InMemoryRosterRepository repo;
    late RosterProvider provider;

    setUp(() {
      repo = _repo();
      provider = RosterProvider(repo);
    });

    test('初始呼叫 onSessionChanged(userId) → fetchInitialData 被触发', () async {
      provider.onSessionChanged('user-A');
      await _drainAsync();

      expect(repo.fetchRostersCallCount, greaterThanOrEqualTo(1));
      expect(repo.fetchTemplatesCallCount, greaterThanOrEqualTo(1));
      expect(repo.fetchEventOptionsCallCount, greaterThanOrEqualTo(1));
    });

    test('相同 userId 重复呼叫 onSessionChanged → fetch 不重复触发', () async {
      provider.onSessionChanged('user-A');
      await _drainAsync();
      repo.resetCounts();

      // 同一个 userId 再呼叫一次
      provider.onSessionChanged('user-A');
      await _drainAsync();

      expect(repo.fetchRostersCallCount, 0);
      expect(repo.fetchTemplatesCallCount, 0);
    });

    test('切换到不同 userId → 重新触发 fetch', () async {
      provider.onSessionChanged('user-A');
      await _drainAsync();
      repo.resetCounts();

      provider.onSessionChanged('user-B');
      await _drainAsync();

      expect(repo.fetchRostersCallCount, greaterThanOrEqualTo(1));
    });

    test('切换帐号时旧的 rosters 先被同步清空，fetch 完成后回填 user-B 资料', () async {
      // user-A 有一笔资料
      repo.rosters = [
        ServiceRoster(
          id: 'r1',
          date: DateTime(2026, 3, 1),
          type: ServiceType.sundayService,
          serviceName: '主日崇拜',
          duties: const [],
        ),
      ];
      provider.onSessionChanged('user-A');
      await _drainAsync();
      expect(provider.rosters, isNotEmpty);

      // user-B 有不同的非空资料
      repo.rosters = [
        ServiceRoster(
          id: 'r2',
          date: DateTime(2026, 3, 8),
          type: ServiceType.youth,
          serviceName: '青年崇拜',
          duties: const [],
        ),
        ServiceRoster(
          id: 'r3',
          date: DateTime(2026, 3, 15),
          type: ServiceType.youth,
          serviceName: '青年崇拜',
          duties: const [],
        ),
      ];

      // 切换帐号后【不 await】，同步确认 cache 已被清空
      provider.onSessionChanged('user-B');
      expect(provider.rosters, isEmpty); // 同步清空，fetch 尚未完成

      // 等待 fetch 完成后，应回填 user-B 的 2 笔资料
      await _drainAsync();
      expect(provider.rosters, hasLength(2));
    });

    test('onSessionChanged(null)（登出）→ cache 清空、不触发 fetch', () async {
      provider.onSessionChanged('user-A');
      await _drainAsync();
      repo.resetCounts();

      provider.onSessionChanged(null);
      await _drainAsync();

      expect(repo.fetchRostersCallCount, 0);
      expect(provider.rosters, isEmpty);
      expect(provider.templates, isEmpty);
    });

    test('登出后 error 被清空', () async {
      provider.onSessionChanged('user-A');
      await _drainAsync();

      provider.onSessionChanged(null);

      expect(provider.error, isNull);
    });

    test('登出后 isEditMode 被重置为 false', () async {
      provider.onSessionChanged('user-A');
      await _drainAsync();
      provider.toggleEditMode();
      expect(provider.isEditMode, true);

      provider.onSessionChanged(null);

      expect(provider.isEditMode, false);
    });

    test('切换帐号后 isEditMode 被重置为 false', () async {
      provider.onSessionChanged('user-A');
      await _drainAsync();
      provider.toggleEditMode();
      expect(provider.isEditMode, true);

      provider.onSessionChanged('user-B');
      await _drainAsync();

      expect(provider.isEditMode, false);
    });

    test('onSessionChanged(null) 后再登入（新 userId）→ 再次触发 fetch', () async {
      provider.onSessionChanged('user-A');
      await _drainAsync();

      provider.onSessionChanged(null);
      await _drainAsync();
      repo.resetCounts();

      provider.onSessionChanged('user-A');
      await _drainAsync();

      // null -> user-A 视为 userId 改变，应重新 fetch
      expect(repo.fetchRostersCallCount, greaterThanOrEqualTo(1));
    });
  });
}
