import 'dart:convert';

import 'package:church_staff_pwa/core/config/church_config.dart';
import 'package:church_staff_pwa/core/config/service_catalog.dart';
import 'package:church_staff_pwa/core/types/service_type.dart';
import 'package:church_staff_pwa/features/services/data/service_settings_repository.dart';
import 'package:church_staff_pwa/features/services/presentation/providers/service_catalog_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/church_test_config.dart';
import 'support/in_memory_service_settings.dart';

const _prayer = ServiceDefinition(
  id: 'prayer',
  label: '祷告',
  name: '周三祷告会',
  weekday: 3,
  enabled: true,
);

void main() {
  late ChurchConfig deployed;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    deployed = testChurchConfig();
    ServiceCatalog.resetForTesting(deployed);
  });
  tearDown(() => ServiceCatalog.resetForTesting(deployed));

  test('Firestore 的清单取代部署设定的聚会，其他设定不动', () {
    final services = [...deployed.services, _prayer];
    expect(ServiceCatalog.apply(services), isTrue);
    expect(ServiceType.values.map((t) => t.name), contains('prayer'));
    expect(const ServiceType('prayer').label, '祷告');
    expect(const ServiceType('prayer').weekday, 3);
    expect(ChurchConfig.current.appName, deployed.appName);
    expect(ServiceCatalog.apply(services), isFalse, reason: '同一份清单不算改变');
    expect(ServiceCatalog.apply(null), isTrue, reason: 'null 回到部署设定');
    expect(ServiceType.values.map((t) => t.name), isNot(contains('prayer')));
  });

  test('停用的聚会留在 values，但不在 active', () {
    final first = deployed.services.first;
    ServiceCatalog.apply([first.copyWith(enabled: false), _prayer]);
    expect(ServiceType.values.map((t) => t.name), [first.id, 'prayer']);
    expect(ServiceType.active.map((t) => t.name), ['prayer']);
  });

  test('格式不对的 settings/services 当作没有', () {
    expect(ServiceCatalog.parseDocument({'services': []}), isNull);
    expect(
      ServiceCatalog.parseDocument({
        'services': [
          {
            'id': '1bad',
            'label': 'x',
            'name': 'x',
            'weekday': 3,
            'enabled': true,
          },
        ],
      }),
      isNull,
    );
    expect(
      ServiceCatalog.parseDocument({
        'services': [_prayer.toJson()],
      }),
      [_prayer],
    );
  });

  test('ids 只增不减：旧的、部署设定的、这次的都在', () {
    final ids = ServiceCatalog.knownIds(['old-one'], [_prayer]);
    expect(
      ids,
      containsAll(['old-one', 'prayer', ...deployed.services.map((s) => s.id)]),
    );
  });

  test('启动时先套用本机记下的清单，不等网路', () async {
    SharedPreferences.setMockInitialValues({
      ServiceCatalog.cacheKey: jsonEncode([_prayer.toJson()]),
    });
    await ServiceCatalog.applyCached();
    expect(ServiceType.values.map((t) => t.name), ['prayer']);
  });

  group('ServiceCatalogProvider', () {
    test('登入后读到不同的清单：套用、记下、重新载入一次', () async {
      final reloads = <String>[];
      final repo = InMemoryServiceSettings(
        ServiceSettings(
          services: [...deployed.services, _prayer],
          ids: const [],
        ),
      );
      final provider = ServiceCatalogProvider(
        repo,
        reload: (reason) async {
          reloads.add(reason);
          return true;
        },
      );
      await provider.refresh();
      expect(ServiceType.values.map((t) => t.name), contains('prayer'));
      expect(reloads, hasLength(1));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(ServiceCatalog.cacheKey), contains('prayer'));

      // 重新载入后读到一样的清单，不会再重载。
      await provider.refresh();
      expect(reloads, hasLength(1));
    });

    test('没有 settings/services：沿用部署设定，不重载', () async {
      final reloads = <String>[];
      final provider = ServiceCatalogProvider(
        InMemoryServiceSettings(),
        reload: (reason) async {
          reloads.add(reason);
          return true;
        },
      );
      await provider.refresh();
      expect(reloads, isEmpty);
      expect(ServiceType.values.length, deployed.services.length);
    });

    test('存档写入清单，ids 保留部署设定的聚会', () async {
      final repo = InMemoryServiceSettings();
      final provider = ServiceCatalogProvider(repo, reload: (_) async => false);
      await provider.save([deployed.services.first, _prayer]);
      expect(repo.saves, 1);
      expect(repo.document!.services, [deployed.services.first, _prayer]);
      expect(
        repo.document!.ids,
        containsAll(deployed.services.map((s) => s.id)),
      );
      expect(ServiceType.values.map((t) => t.name), [
        deployed.services.first.id,
        'prayer',
      ]);
    });
  });
}
