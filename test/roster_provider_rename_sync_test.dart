import 'package:flutter_test/flutter_test.dart';
import 'package:church_staff_pwa/core/types/service_type.dart';
import 'package:church_staff_pwa/features/roster/domain/entities/event_option.dart';
import 'package:church_staff_pwa/features/roster/domain/entities/service_roster.dart';
import 'package:church_staff_pwa/features/roster/domain/staff_order.dart';
import 'package:church_staff_pwa/features/roster/presentation/providers/roster_provider.dart';

import 'support/in_memory_roster_repository.dart';

void main() {
  group('RosterProvider rename sync', () {
    late InMemoryRosterRepository repository;
    late RosterProvider provider;

    setUp(() async {
      repository = InMemoryRosterRepository(
        rosters: [
          ServiceRoster(
            id: 'sun-1',
            date: DateTime(2026, 2, 1),
            type: ServiceType.sundayService,
            serviceName: '主日崇拜',
            duties: [
              RosterEntry(role: '领会', people: const ['A']),
              RosterEntry(role: '讲员', people: const ['B']),
            ],
            specialEvents: const ['圣餐主日'],
          ),
          ServiceRoster(
            id: 'youth-1',
            date: DateTime(2026, 2, 7),
            type: ServiceType.youth,
            serviceName: '青年崇拜',
            duties: [
              RosterEntry(role: '领会', people: const ['Y']),
            ],
            specialEvents: const ['圣餐主日'],
          ),
        ],
        templates: {
          ServiceType.sundayService: ['领会', '讲员'],
          ServiceType.youth: ['领会'],
          ServiceType.children: const [],
        },
        eventOptions: {
          ServiceType.sundayService: const [
            EventOption(name: '圣餐主日', color: 0xFFF39C12),
          ],
          ServiceType.youth: const [
            EventOption(name: '圣餐主日', color: 0xFFF39C12),
          ],
          ServiceType.children: const [],
        },
      );
      provider = RosterProvider(repository);
      await provider.fetchInitialData();
    });

    test(
      'renaming template role updates existing rosters of same type',
      () async {
        await provider.updateTemplates(
          {
            ServiceType.sundayService: ['敬拜主领', '讲员'],
            ServiceType.youth: ['领会'],
            ServiceType.children: const [],
          },
          renamedRolesByType: {
            ServiceType.sundayService: {'领会': '敬拜主领'},
          },
        );

        final sunday = provider
            .getRostersByType(ServiceType.sundayService)
            .first;
        final youth = provider.getRostersByType(ServiceType.youth).first;

        expect(sunday.duties.map((d) => d.role), ['敬拜主领', '讲员']);
        expect(youth.duties.map((d) => d.role), ['领会']);
      },
    );

    test('renaming event updates existing rosters of same type', () async {
      await provider.updateEventOptions(
        {
          ServiceType.sundayService: const [
            EventOption(name: '圣餐', color: 0xFFF39C12),
          ],
          ServiceType.youth: const [
            EventOption(name: '圣餐主日', color: 0xFFF39C12),
          ],
          ServiceType.children: const [],
        },
        renamedEventsByType: {
          ServiceType.sundayService: {'圣餐主日': '圣餐'},
        },
      );

      final sunday = provider.getRostersByType(ServiceType.sundayService).first;
      final youth = provider.getRostersByType(ServiceType.youth).first;

      expect(sunday.specialEvents, ['圣餐']);
      expect(youth.specialEvents, ['圣餐主日']);
    });
  });

  group('RosterProvider 删除服事项目', () {
    ServiceRoster youth(String id, DateTime date) => ServiceRoster(
      id: id,
      date: date,
      type: ServiceType.youth,
      serviceName: '青年崇拜',
      duties: [
        RosterEntry(role: '领会', people: const ['Y']),
        RosterEntry(role: '报告', people: const ['R']),
      ],
    );

    late InMemoryRosterRepository repository;
    late RosterProvider provider;

    setUp(() async {
      repository = InMemoryRosterRepository(
        rosters: [
          youth('last-week', DateTime(2026, 9, 19)),
          youth('today', DateTime(2026, 9, 26)),
          youth('next-week', DateTime(2026, 10, 3)),
          ServiceRoster(
            id: 'sunday',
            date: DateTime(2026, 9, 27),
            type: ServiceType.sundayService,
            serviceName: '主日崇拜',
            duties: [
              RosterEntry(role: '报告', people: const ['S']),
            ],
          ),
        ],
        templates: {
          ServiceType.sundayService: ['报告'],
          ServiceType.youth: ['领会', '报告'],
          ServiceType.children: const [],
        },
        staffOrders: {
          ServiceType.youth: StaffOrder({
            '领会': ['Y', 'Z'],
            '报告': ['R', 'Q'],
          }),
        },
      );
      provider = RosterProvider(
        repository,
        now: () => DateTime(2026, 9, 26, 10),
      );
      await provider.fetchInitialData();
    });

    List<String> rolesOf(String id) => [
      for (final d in repository.rosters.firstWhere((r) => r.id == id).duties)
        d.role,
    ];

    Future<void> dropYouthReport() => provider.updateTemplates({
      ServiceType.sundayService: ['报告'],
      ServiceType.youth: ['领会'],
      ServiceType.children: const [],
    });

    test('今天以后的服事表拿掉那一项，过去的不动', () async {
      await dropYouthReport();

      expect(rolesOf('last-week'), ['领会', '报告']);
      expect(rolesOf('today'), ['领会']);
      expect(rolesOf('next-week'), ['领会']);
    });

    test('只删那个崇拜的：别的崇拜同名的项目还在', () async {
      await dropYouthReport();

      expect(rolesOf('sunday'), ['报告']);
    });

    test('存著的排序也删掉那一项', () async {
      await dropYouthReport();

      final order = repository.staffOrders[ServiceType.youth]!;
      expect(order.rankingOf('报告'), isEmpty);
      expect(order.rankingOf('领会'), ['Y', 'Z']);
    });

    test('改名不算删除：服事表上的人跟著新名字走', () async {
      await provider.updateTemplates(
        {
          ServiceType.sundayService: ['报告'],
          ServiceType.youth: ['领会', '宣布'],
          ServiceType.children: const [],
        },
        renamedRolesByType: {
          ServiceType.youth: {'报告': '宣布'},
        },
      );

      expect(rolesOf('next-week'), ['领会', '宣布']);
      expect(rolesOf('last-week'), ['领会', '宣布']);
    });
  });

  // 写入失败一律往上丢，不进 error：编辑页一看到 error 就把整页换成错误画面。
  group('RosterProvider 写入失败', () {
    late InMemoryRosterRepository repository;
    late RosterProvider provider;

    ServiceRoster roster(String id, ServiceType type) => ServiceRoster(
      id: id,
      date: DateTime(2026, 2, 1),
      type: type,
      serviceName: '崇拜',
      duties: [
        RosterEntry(role: '领会', people: const ['A']),
      ],
      specialEvents: const ['圣餐主日'],
    );

    setUp(() async {
      repository = InMemoryRosterRepository(
        rosters: [
          roster('sun-1', ServiceType.sundayService),
          roster('youth-1', ServiceType.youth),
        ],
        templates: {
          ServiceType.sundayService: ['领会'],
          ServiceType.youth: ['领会'],
        },
      );
      provider = RosterProvider(repository);
      await provider.fetchInitialData();
    });

    test('updateRoster 失败时丢出来，本地不动，error 仍是 null', () async {
      repository.failRosterIds = {'sun-1'};
      final before = provider.getRostersByType(ServiceType.sundayService).first;

      await expectLater(
        provider.updateRoster(before.copyWith(specialEvents: const [])),
        throwsException,
      );

      expect(provider.error, isNull);
      expect(
        provider
            .getRostersByType(ServiceType.sundayService)
            .first
            .specialEvents,
        ['圣餐主日'],
      );
    });

    test('样板写入失败时丢出来，样板不变', () async {
      repository.failTemplateWrite = StateError('permission-denied');

      await expectLater(
        provider.updateTemplates({
          ServiceType.sundayService: ['敬拜主领'],
        }),
        throwsStateError,
      );

      expect(provider.error, isNull);
      expect(provider.templates[ServiceType.sundayService], ['领会']);
    });

    test('改名同步部分失败：成功的那几天照改，丢 PartialUpdateException', () async {
      repository.failRosterIds = {'youth-1'};

      await expectLater(
        provider.updateEventOptions(
          {
            ServiceType.sundayService: const [
              EventOption(name: '圣餐', color: 0xFFF39C12),
            ],
            ServiceType.youth: const [
              EventOption(name: '圣餐', color: 0xFFF39C12),
            ],
          },
          renamedEventsByType: {
            ServiceType.sundayService: {'圣餐主日': '圣餐'},
            ServiceType.youth: {'圣餐主日': '圣餐'},
          },
        ),
        throwsA(
          isA<PartialUpdateException>()
              .having((e) => e.failureCount, 'failureCount', 1)
              .having((e) => e.successCount, 'successCount', 1),
        ),
      );

      expect(provider.error, isNull);
      expect(repository.eventOptionWrites, 1, reason: '活动清单本身已写入');
      expect(
        provider
            .getRostersByType(ServiceType.sundayService)
            .first
            .specialEvents,
        ['圣餐'],
      );
      expect(provider.getRostersByType(ServiceType.youth).first.specialEvents, [
        '圣餐主日',
      ]);
    });
  });

  group('RosterProvider.addEventOption（汇入结果的「加入活动清单」）', () {
    late InMemoryRosterRepository repository;
    late RosterProvider provider;

    setUp(() async {
      repository = InMemoryRosterRepository(
        rosters: const [],
        templates: const {},
        eventOptions: {
          ServiceType.sundayService: [
            EventOption(name: '圣餐', color: eventColorPalette[0]),
          ],
          ServiceType.youth: [
            EventOption(name: '圣餐', color: eventColorPalette[0]),
          ],
        },
      );
      provider = RosterProvider(repository);
      await provider.fetchInitialData();
    });

    test('加在那个崇拜的清单最后，颜色挑还没用过的', () async {
      final added = await provider.addEventOption(
        ServiceType.sundayService,
        '孩童奉献礼',
      );

      expect(added.color, eventColorPalette[1]);
      final saved = (await repository
          .getEventOptions())[ServiceType.sundayService]!;
      expect(saved.map((o) => o.name), ['圣餐', '孩童奉献礼']);
    });

    test('加完马上查得到颜色，已经汇入的那几天不必重汇', () async {
      await provider.addEventOption(ServiceType.sundayService, '孩童奉献礼');
      expect(
        provider.eventColorFor(ServiceType.sundayService, '孩童奉献礼'),
        eventColorPalette[1],
      );
    });

    test('别的崇拜的清单不受影响', () async {
      await provider.addEventOption(ServiceType.sundayService, '孩童奉献礼');
      final youth = (await repository.getEventOptions())[ServiceType.youth]!;
      expect(youth.map((o) => o.name), ['圣餐']);
    });

    test('已经有同名的就不再写，重按不会多一笔', () async {
      await provider.addEventOption(ServiceType.sundayService, '孩童奉献礼');
      await provider.addEventOption(ServiceType.sundayService, '孩童奉献礼');
      expect(repository.eventOptionWrites, 1);
    });

    test('别台装置在这段期间加的活动不会被盖掉', () async {
      // 这台的快取还停在载入时；另一台装置已经在青崇加了一个活动。
      await repository.updateEventOptions({
        ...await repository.getEventOptions(),
        ServiceType.youth: [
          EventOption(name: '圣餐', color: eventColorPalette[0]),
          EventOption(name: '迎新', color: eventColorPalette[1]),
        ],
      });

      await provider.addEventOption(ServiceType.sundayService, '孩童奉献礼');

      final youth = (await repository.getEventOptions())[ServiceType.youth]!;
      expect(youth.map((o) => o.name), ['圣餐', '迎新']);
    });

    test('别台装置已经加过同名的，就不再写，但这台也看得到颜色', () async {
      await repository.updateEventOptions({
        ...await repository.getEventOptions(),
        ServiceType.sundayService: [
          EventOption(name: '圣餐', color: eventColorPalette[0]),
          EventOption(name: '孩童奉献礼', color: eventColorPalette[4]),
        ],
      });
      final writes = repository.eventOptionWrites;

      final result = await provider.addEventOption(
        ServiceType.sundayService,
        '孩童奉献礼',
      );

      expect(result.color, eventColorPalette[4]);
      expect(repository.eventOptionWrites, writes);
      expect(
        provider.eventColorFor(ServiceType.sundayService, '孩童奉献礼'),
        eventColorPalette[4],
      );
    });

    test('写入失败时丢例外，而且清单维持原样', () async {
      repository.failEventOptionWrite = StateError('permission-denied');
      await expectLater(
        provider.addEventOption(ServiceType.sundayService, '孩童奉献礼'),
        throwsStateError,
      );
      expect(
        provider.eventOptionsFor(ServiceType.sundayService).map((o) => o.name),
        ['圣餐'],
      );
    });
  });
}
