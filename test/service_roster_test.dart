import 'package:flutter_test/flutter_test.dart';

import 'package:church_staff_pwa/core/types/service_type.dart';
import 'package:church_staff_pwa/features/roster/domain/entities/event_option.dart';
import 'package:church_staff_pwa/features/roster/domain/entities/service_roster.dart';

void main() {
  // ── EventOption.fromJson / toJson ──────────────────────────────────────────
  group('EventOption 序列化', () {
    test('fromJson → toJson 来回转换不变', () {
      const original = EventOption(name: '圣餐主日', color: 0xFFF39C12);
      final json = original.toJson();
      final restored = EventOption.fromJson(json);
      expect(restored.name, original.name);
      expect(restored.color, original.color);
    });

    test('fromJson：缺少 color 栏位时使用预设颜色', () {
      final e = EventOption.fromJson({'name': '复活节'});
      expect(e.name, '复活节');
      // 预设色要在色盘里，设定页才点得回来。
      expect(eventColorPalette, contains(e.color));
    });

    test('fromJson：缺少 name 栏位时 name 为空字串', () {
      final e = EventOption.fromJson({'color': 0xFF123456});
      expect(e.name, '');
      expect(e.color, 0xFF123456);
    });

    test('fromJson：name 非 String 时回退空字串', () {
      final e = EventOption.fromJson({'name': 42, 'color': 0xFFF39C12});
      expect(e.name, '');
    });

    test('fromJson：color 非 int 时回退预设颜色', () {
      final e = EventOption.fromJson({'name': '圣诞', 'color': '红色'});
      // 预设色要在色盘里，设定页才点得回来。
      expect(eventColorPalette, contains(e.color));
    });

    test('copyWith 只更新 name 时 color 不变', () {
      const original = EventOption(name: '旧名', color: 0xFF001122);
      final updated = original.copyWith(name: '新名');
      expect(updated.name, '新名');
      expect(updated.color, 0xFF001122);
    });
  });

  // ── RosterEntry ────────────────────────────────────────────────────────────
  group('RosterEntry', () {
    test('copyWith 只更新 role 时其他栏位保持不变', () {
      final original = RosterEntry(
        role: '领会',
        people: const ['A'],
        personIdsByName: const {'A': 'uid-a'},
      );
      final updated = original.copyWith(role: '敬拜主领');
      expect(updated.role, '敬拜主领');
      expect(updated.people, ['A']);
      expect(updated.personIdsByName, {'A': 'uid-a'});
    });
  });

  // ── ServiceRoster ─────────────────────────────────────────────────────────
  group('ServiceRoster', () {
    ServiceRoster makeRoster({
      String id = 'test-id',
      List<String> specialEvents = const [],
      Map<String, int> customEventColors = const {},
      List<RosterEntry>? duties,
    }) {
      return ServiceRoster(
        id: id,
        date: DateTime(2026, 3, 1),
        type: ServiceType.sundayService,
        serviceName: '主日崇拜',
        duties:
            duties ??
            [
              RosterEntry(role: '领会', people: const ['A']),
            ],
        specialEvents: specialEvents,
        customEventColors: customEventColors,
      );
    }

    test('specialEvents 预设为空 List', () {
      final roster = makeRoster();
      expect(roster.specialEvents, isEmpty);
    });

    test('customEventColors 预设为空 Map', () {
      final roster = makeRoster();
      expect(roster.customEventColors, isEmpty);
    });

    test('customEventColors 有值时可正确读取', () {
      final roster = makeRoster(customEventColors: {'复活节': 0xFFFFD700});
      expect(roster.customEventColors['复活节'], 0xFFFFD700);
    });

    test('specialEvents 为空 list 时 copyWith 可加入事件', () {
      final original = makeRoster(specialEvents: const []);
      final updated = original.copyWith(specialEvents: ['圣餐主日']);
      expect(updated.specialEvents, ['圣餐主日']);
      // 原物件不受影响
      expect(original.specialEvents, isEmpty);
    });

    test('copyWith 只更新 customEventColors 时其他栏位不变', () {
      final original = makeRoster(
        specialEvents: const ['圣餐'],
        customEventColors: const {'旧事件': 0xFF000001},
      );
      final updated = original.copyWith(customEventColors: {'新事件': 0xFF000002});
      expect(updated.customEventColors, {'新事件': 0xFF000002});
      expect(updated.specialEvents, ['圣餐']);
      expect(updated.id, original.id);
      expect(updated.serviceName, original.serviceName);
    });

    test('copyWith 对 duties 清空后为空 list', () {
      final roster = makeRoster();
      final updated = roster.copyWith(duties: []);
      expect(updated.duties, isEmpty);
    });
  });
}
