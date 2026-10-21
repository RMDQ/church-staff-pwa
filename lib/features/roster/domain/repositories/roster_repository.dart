import '../entities/event_option.dart';
import '../entities/service_roster.dart';
import 'package:church_staff_pwa/core/types/service_type.dart';
import '../staff_order.dart';

abstract class RosterRepository {
  Future<List<ServiceRoster>> getUpcomingRosters();

  /// 从本地 IndexedDB cache 读取，不打网路。
  /// 若 cache 尚未建立（首次开启或 cache 已清除），回传空 list。
  Future<List<ServiceRoster>> getUpcomingRostersFromCache();

  /// 确保「本季 + 下季」的预定 roster 都在 Firestore 内（missing 的补写），
  /// 范围限制在 [allowedTypes] 这几个聚会别。
  ///
  /// [allowedTypes] 是必填而不是预设全部：batch 是原子的，只要里面混进一笔呼叫
  /// 者无权写入的聚会别，整批都会被 rules 打回，连他自己那本也补不出来。
  Future<void> ensureQuarterRosters(List<ServiceType> allowedTypes);

  Future<void> updateRoster(ServiceRoster roster);

  /// 以单一 batch 写入多笔服事表：全部成功，或全部不写。
  ///
  /// 服事交换一定要走这里。两笔各写各的话，一边成功一边失败会留下「一个人被
  /// 排两天、另一个人的那天空著」—— 而那正是交换本身要避免的状态。
  ///
  /// JSON 汇入刻意不走这里：那边宁可部分成功，把失败的日期报出来让人重试，
  /// 也不要因为其中一天坏掉就整季都不写（见 [ServiceRoster] 的批次汇入路径）。
  Future<void> updateRostersAtomically(List<ServiceRoster> rosters);
  Future<Map<ServiceType, List<String>>> getServiceTemplates();
  Future<void> updateServiceTemplates(Map<ServiceType, List<String>> templates);
  Future<Map<ServiceType, List<EventOption>>> getEventOptions();
  Future<void> updateEventOptions(Map<ServiceType, List<EventOption>> options);

  /// 每个崇拜存过的同工排序。没存过的崇拜不在回传的 Map 里。
  Future<Map<ServiceType, StaffOrder>> getStaffOrders();

  /// 改 [type] 的同工排序里的几个服事项目：有值的换成新的排序，null 的
  /// 拿掉。没提到的服事项目不动（见 [StaffOrder.changesTo]）。
  Future<void> updateStaffRankings(
    ServiceType type,
    Map<String, List<String>?> changes,
  );
}
