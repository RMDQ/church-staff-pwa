import 'dart:async';

import 'package:church_staff_pwa/core/types/service_type.dart';
import 'package:church_staff_pwa/features/roster/domain/entities/event_option.dart';
import 'package:church_staff_pwa/features/roster/domain/entities/service_roster.dart';
import 'package:church_staff_pwa/features/roster/domain/repositories/roster_repository.dart';
import 'package:church_staff_pwa/features/roster/domain/staff_order.dart';

/// 测试共用的 [RosterRepository]：资料放在记忆体里，读写照实做。
///
/// 以前每个测试档各写一份私有 fake，九份各自决定「写入要不要真的存」「失败
/// 怎么丢」—— 同一个 provider 行为在不同档案里测的其实是不同的假设。要故意
/// 失败、暂停或计数的，设下面对应的栏位；用不到的测试什么都不必设。
class InMemoryRosterRepository implements RosterRepository {
  InMemoryRosterRepository({
    List<ServiceRoster> rosters = const [],
    List<ServiceRoster> cachedRosters = const [],
    Map<ServiceType, List<String>> templates = const {},
    Map<ServiceType, List<EventOption>> eventOptions = const {},
    Map<ServiceType, StaffOrder> staffOrders = const {},
  }) : rosters = List.of(rosters),
       cachedRosters = List.of(cachedRosters),
       templates = Map.of(templates),
       eventOptions = Map.of(eventOptions),
       staffOrders = Map.of(staffOrders);

  /// 伺服器上的服事表。写入会改到这里。
  List<ServiceRoster> rosters;

  /// 本地快取（IndexedDB）里的服事表。预设是空的，也就是 cache miss。
  List<ServiceRoster> cachedRosters;

  Map<ServiceType, List<String>> templates;
  Map<ServiceType, List<EventOption>> eventOptions;
  Map<ServiceType, StaffOrder> staffOrders;

  // ── 故意出事 ──────────────────────────────────────────────────────────

  /// 读伺服器／读快取时丢这个。
  Object? serverError;
  Object? cacheError;

  /// 设了就等它完成才回，让测试控制读取落地的时机。
  Completer<void>? serverPause;
  Completer<void>? cachePause;

  /// 写这几张服事表时失败（单笔与 batch 都算）。
  Set<String> failRosterIds = {};

  /// batch 整批失败。
  bool failAtomicWrites = false;

  /// 写样板／活动清单时丢这个。
  Object? failTemplateWrite;
  Object? failEventOptionWrite;
  Object? failStaffOrderWrite;

  /// 读同工排序时丢这个（例如 rules 还没部署）。
  Object? failStaffOrderRead;

  // ── 纪录 ──────────────────────────────────────────────────────────────

  int fetchRostersCallCount = 0;
  int fetchTemplatesCallCount = 0;
  int fetchEventOptionsCallCount = 0;

  int ensureCallCount = 0;
  List<ServiceType> ensureTypes = const [];

  /// 单笔 [updateRoster] 的次数。交换不该用到这条路。
  int singleWriteCount = 0;

  /// 每次 [updateRostersAtomically] 收到的批次。
  final List<List<ServiceRoster>> atomicBatches = [];

  int eventOptionWrites = 0;
  int staffOrderWrites = 0;

  void resetCounts() {
    fetchRostersCallCount = 0;
    fetchTemplatesCallCount = 0;
    fetchEventOptionsCallCount = 0;
  }

  // ── RosterRepository ──────────────────────────────────────────────────

  @override
  Future<List<ServiceRoster>> getUpcomingRosters() async {
    fetchRostersCallCount++;
    if (serverPause case final pause?) await pause.future;
    if (serverError case final error?) throw error;
    return List.of(rosters);
  }

  @override
  Future<List<ServiceRoster>> getUpcomingRostersFromCache() async {
    if (cachePause case final pause?) await pause.future;
    if (cacheError case final error?) throw error;
    return List.of(cachedRosters);
  }

  @override
  Future<void> ensureQuarterRosters(List<ServiceType> allowedTypes) async {
    ensureCallCount++;
    ensureTypes = allowedTypes;
  }

  @override
  Future<void> updateRoster(ServiceRoster roster) async {
    singleWriteCount++;
    if (failRosterIds.contains(roster.id)) {
      throw Exception('Firestore write failed for ${roster.id}');
    }
    _store(roster);
  }

  @override
  Future<void> updateRostersAtomically(List<ServiceRoster> batch) async {
    if (failAtomicWrites || batch.any((r) => failRosterIds.contains(r.id))) {
      throw Exception('batch commit failed');
    }
    atomicBatches.add(List.of(batch));
    batch.forEach(_store);
  }

  @override
  Future<Map<ServiceType, List<String>>> getServiceTemplates() async {
    fetchTemplatesCallCount++;
    return Map.of(templates);
  }

  @override
  Future<void> updateServiceTemplates(
    Map<ServiceType, List<String>> templates,
  ) async {
    if (failTemplateWrite case final error?) throw error;
    this.templates = Map.of(templates);
  }

  @override
  Future<Map<ServiceType, List<EventOption>>> getEventOptions() async {
    fetchEventOptionsCallCount++;
    return Map.of(eventOptions);
  }

  @override
  Future<void> updateEventOptions(
    Map<ServiceType, List<EventOption>> options,
  ) async {
    if (failEventOptionWrite case final error?) throw error;
    eventOptionWrites++;
    eventOptions = Map.of(options);
  }

  @override
  Future<Map<ServiceType, StaffOrder>> getStaffOrders() async {
    if (failStaffOrderRead case final error?) throw error;
    return Map.of(staffOrders);
  }

  /// 照 Firestore 的 merge 写入做：只动 [changes] 提到的服事项目。
  @override
  Future<void> updateStaffRankings(
    ServiceType type,
    Map<String, List<String>?> changes,
  ) async {
    if (failStaffOrderWrite case final error?) throw error;
    staffOrderWrites++;
    staffOrders[type] = (staffOrders[type] ?? StaffOrder()).withChanges(
      changes,
    );
  }

  void _store(ServiceRoster roster) {
    final index = rosters.indexWhere((r) => r.id == roster.id);
    if (index == -1) {
      rosters.add(roster);
    } else {
      rosters[index] = roster;
    }
  }
}

/// 三个崇拜都有、但都是空的样板或活动清单 —— 「载入过，只是还没设定」。
Map<ServiceType, List<T>> emptyForEveryType<T>() => {
  for (final type in ServiceType.values) type: <T>[],
};
