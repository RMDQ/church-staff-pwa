import 'package:flutter_test/flutter_test.dart';
import 'package:church_staff_pwa/core/types/service_type.dart';
import 'package:church_staff_pwa/features/roster/domain/entities/event_option.dart';
import 'package:church_staff_pwa/features/roster/domain/entities/service_roster.dart';
import 'package:church_staff_pwa/features/roster/presentation/providers/roster_provider.dart';

import 'support/in_memory_roster_repository.dart';

/// RosterProvider 对 getRostersByType / eventColorFor 的结果做了快取。
/// 这组测试守的是「资料变了但快取没丢」这个 bug — 那会让画面显示旧资料，
/// 而且不会有任何错误讯息。
InMemoryRosterRepository _repo({
  required List<ServiceRoster> rosters,
  required Map<ServiceType, List<EventOption>> eventOptions,
}) => InMemoryRosterRepository(
  rosters: rosters,
  templates: {
    ServiceType.sundayService: ['领会'],
    ServiceType.youth: ['领会'],
    ServiceType.children: [],
  },
  eventOptions: eventOptions,
);

ServiceRoster _roster({
  required String id,
  required ServiceType type,
  List<String> people = const ['A'],
  List<String> events = const [],
}) {
  return ServiceRoster(
    id: id,
    date: DateTime(2026, 2, 1),
    type: type,
    serviceName: '崇拜',
    duties: [RosterEntry(role: '领会', people: people)],
    specialEvents: events,
  );
}

void main() {
  group('RosterProvider 衍生资料快取', () {
    late InMemoryRosterRepository repository;
    late RosterProvider provider;

    setUp(() async {
      repository = _repo(
        rosters: [
          _roster(id: 'sun-1', type: ServiceType.sundayService),
          _roster(id: 'sun-2', type: ServiceType.sundayService),
          _roster(id: 'youth-1', type: ServiceType.youth),
        ],
        eventOptions: {
          ServiceType.sundayService: const [
            EventOption(name: '圣餐主日', color: 0xFFF39C12),
          ],
          ServiceType.youth: const [
            EventOption(name: '青年之夜', color: 0xFF27AE60),
          ],
          ServiceType.children: const [],
        },
      );
      provider = RosterProvider(repository);
      await provider.fetchInitialData();
    });

    test('依 type 分组结果正确', () {
      expect(
        provider
            .getRostersByType(ServiceType.sundayService)
            .map((r) => r.id)
            .toList(),
        ['sun-1', 'sun-2'],
      );
      expect(
        provider.getRostersByType(ServiceType.youth).map((r) => r.id).toList(),
        ['youth-1'],
      );
      expect(provider.getRostersByType(ServiceType.children), isEmpty);
    });

    test('连续呼叫回传同一个 list instance（没有每次重算）', () {
      final first = provider.getRostersByType(ServiceType.sundayService);
      final second = provider.getRostersByType(ServiceType.sundayService);
      expect(identical(first, second), isTrue);
    });

    test('updateRoster 后分组快取要失效', () async {
      final target = provider
          .getRostersByType(ServiceType.sundayService)
          .firstWhere((r) => r.id == 'sun-1');

      await provider.updateRoster(
        target.copyWith(
          duties: [
            RosterEntry(role: '领会', people: const ['新的人']),
          ],
        ),
      );

      final refreshed = provider
          .getRostersByType(ServiceType.sundayService)
          .firstWhere((r) => r.id == 'sun-1');
      expect(refreshed.duties.first.people, ['新的人']);
    });

    test('updateRosters 批次更新后分组快取要失效', () async {
      final rosters = provider.getRostersByType(ServiceType.sundayService);
      await provider.updateRosters([
        rosters[0].copyWith(
          duties: [
            RosterEntry(role: '领会', people: const ['甲']),
          ],
        ),
        rosters[1].copyWith(
          duties: [
            RosterEntry(role: '领会', people: const ['乙']),
          ],
        ),
      ]);

      final refreshed = provider.getRostersByType(ServiceType.sundayService);
      expect(refreshed[0].duties.first.people, ['甲']);
      expect(refreshed[1].duties.first.people, ['乙']);
    });

    test('重新 fetch 后分组快取要失效', () async {
      // 先读一次把快取灌热 —— 少了这步，测到的只是「从空快取重算」，
      // 就算把 invalidation 整个拿掉测试照样会过。
      expect(
        provider.getRostersByType(ServiceType.sundayService),
        hasLength(2),
      );

      await repository.updateRoster(
        _roster(id: 'sun-3', type: ServiceType.sundayService),
      );
      await provider.fetchRosters();

      expect(
        provider
            .getRostersByType(ServiceType.sundayService)
            .map((r) => r.id)
            .toList(),
        ['sun-1', 'sun-2', 'sun-3'],
      );
    });

    test('登出后分组快取要清空', () {
      // 先读一次把快取灌热，才测得到「清除」而不是「从空快取重算」。
      expect(
        provider.getRostersByType(ServiceType.sundayService),
        hasLength(2),
      );

      // onSessionChanged 以「userId 有没有变」为判断依据，所以要先进入一个
      // session，登出才会真的走到清除路径。
      provider.onSessionChanged('uid-1');
      provider.onSessionChanged(null);
      expect(provider.getRostersByType(ServiceType.sundayService), isEmpty);
    });

    test('updateRoster 后 rosters 的 identity 必须改变', () async {
      // 首页的「本季服事」用 identical(rosters, 上次的 rosters) 判断要不要
      // 重算。就地改写 _allRosters 会让 identity 不变，首页就会一直显示
      // 编辑前的结果 —— 这个测试守的就是那个情况。
      final before = provider.rosters;
      final target = before.firstWhere((r) => r.id == 'sun-1');

      await provider.updateRoster(
        target.copyWith(
          duties: [
            RosterEntry(role: '领会', people: const ['改过的人']),
          ],
        ),
      );

      expect(identical(provider.rosters, before), isFalse);
    });

    test('updateRosters 后 rosters 的 identity 必须改变', () async {
      final before = provider.rosters;

      await provider.updateRosters([
        before.first.copyWith(
          duties: [
            RosterEntry(role: '领会', people: const ['批次改过的人']),
          ],
        ),
      ]);

      expect(identical(provider.rosters, before), isFalse);
    });

    test('displayStrings 收齐姓名/服事项目/事件，并且去重', () {
      final strings = provider.displayStrings;
      for (final expected in ['崇拜', '领会', 'A']) {
        expect(strings, contains(expected));
      }
      // 去重：同一个字串只会出现一次（三笔 roster 的 serviceName 都是「崇拜」）
      expect(strings.toSet().length, strings.length);
    });

    test('displayStrings 连续呼叫回传同一个 instance', () {
      // MainScaffold 用 context.select 订阅这个 getter，比较方式是 ==（对
      // List 就是 identity）。每次都回新 list 的话，任何一次 notifyListeners
      // 都会让 TextWarmup 以为资料换了而整批重新预热。
      final first = provider.displayStrings;
      final second = provider.displayStrings;
      expect(identical(first, second), isTrue);
    });

    test('登出后 displayStrings 要清空', () {
      // 先读一次灌热快取，才测得到「清除」而不是「从空快取重算」。
      expect(provider.displayStrings, isNotEmpty);

      provider.onSessionChanged('uid-1');
      provider.onSessionChanged(null);
      expect(provider.displayStrings, isEmpty);
    });

    test('资料变更后 displayStrings 要跟著失效', () async {
      // 先读一次灌热快取，才测得到失效而不是「从空快取重算」。
      expect(provider.displayStrings, isNot(contains('甲')));

      final target = provider.rosters.firstWhere((r) => r.id == 'sun-1');
      await provider.updateRoster(
        target.copyWith(
          duties: [
            RosterEntry(role: '领会', people: const ['甲']),
          ],
        ),
      );

      expect(provider.displayStrings, contains('甲'));
    });

    test('eventColorFor：本 type 优先，其次跨 type，找不到给灰色', () {
      expect(
        provider.eventColorFor(ServiceType.sundayService, '圣餐主日'),
        0xFFF39C12,
      );
      // 主日没定义「青年之夜」，落到跨 type 查找
      expect(
        provider.eventColorFor(ServiceType.sundayService, '青年之夜'),
        0xFF27AE60,
      );
      expect(
        provider.eventColorFor(ServiceType.sundayService, '不存在的事件'),
        0xFF7F8C8D,
      );
    });

    test('eventColorOf：服事表自己指定的颜色优先于活动清单', () {
      final roster = provider.rosters
          .firstWhere((r) => r.type == ServiceType.sundayService)
          .copyWith(customEventColors: const {'圣餐主日': 0xFF123456});
      expect(provider.eventColorOf(roster, '圣餐主日'), 0xFF123456);
      expect(provider.eventColorOf(roster, '青年之夜'), 0xFF27AE60);
      expect(provider.eventColorOf(roster, '不存在的事件'), fallbackEventColor);
    });

    test('updateEventOptions 后颜色索引要失效', () async {
      // 先查一次把 _eventColorIndex 建起来（含跨 type 查找那条路径），
      // 否则测到的是「索引本来就是 null」而不是「索引被丢掉」。
      expect(
        provider.eventColorFor(ServiceType.sundayService, '青年之夜'),
        0xFF27AE60,
      );

      await provider.updateEventOptions({
        ServiceType.sundayService: const [
          EventOption(name: '圣餐主日', color: 0xFF3498DB),
        ],
        ServiceType.youth: const [],
        ServiceType.children: const [],
      });

      expect(
        provider.eventColorFor(ServiceType.sundayService, '圣餐主日'),
        0xFF3498DB,
      );
      // 青年之夜已被移除 → 回退到灰色
      expect(
        provider.eventColorFor(ServiceType.sundayService, '青年之夜'),
        0xFF7F8C8D,
      );
    });
  });
}
