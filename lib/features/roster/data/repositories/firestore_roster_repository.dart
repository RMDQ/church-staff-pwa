import 'dart:developer';

import 'package:cloud_firestore/cloud_firestore.dart';
import '../../domain/entities/event_option.dart';
import '../../domain/entities/service_roster.dart';
import 'package:church_staff_pwa/core/types/service_type.dart';
import '../../domain/repositories/roster_repository.dart';
import '../../domain/staff_order.dart';
import '../../domain/roster_schedule.dart';
import '../roster_document.dart';
import '../../../../core/time/church_time.dart';

class FirestoreRosterRepository implements RosterRepository {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  CollectionReference get _rostersCollection =>
      _firestore.collection('rosters');
  DocumentReference get _templatesDoc =>
      _firestore.collection('settings').doc('roster_templates');
  DocumentReference get _eventOptionsDoc =>
      _firestore.collection('settings').doc('event_options');

  // 不放在 settings/ 底下：那里只有 admin 能写，而同工排序是各崇拜的编辑
  // 者在选人视窗里拖出来的。一个崇拜一份文件，rules 才能照文件 id 判断是
  // 不是他的牧区（见 firestore.rules 的 staff_orders）。
  CollectionReference get _staffOrdersCollection =>
      _firestore.collection('staff_orders');

  @override
  Future<List<ServiceRoster>> getUpcomingRosters() async {
    // 纯读路径。不执行任何 backfill 写入。
    // backfill 已移至 ensureQuarterRosters()，只由 admin 在进入编辑画面时触发。
    try {
      final now = ChurchTime.now();
      final fetchFrom = ChurchTime.dateOnly(
        now,
      ).subtract(const Duration(days: 7));
      final fetchFromTimestamp = Timestamp.fromDate(fetchFrom);

      final snapshot = await _rostersCollection
          .where('date', isGreaterThanOrEqualTo: fetchFromTimestamp)
          .orderBy('date')
          .get();

      return _filterAndSortRosters(snapshot.docs, now);
    } catch (e, st) {
      // 一定要往上丢：吞掉错误回传空 list 的话，permission-denied 或离线
      // 在画面上会变成「此类别目前没有服事资讯」，使用者看不到错误也没有
      // 重试钮。要不要降级成 cache 资料由 RosterProvider 决定。
      log('Get rosters failed', error: e, stackTrace: st);
      rethrow;
    }
  }

  @override
  Future<List<ServiceRoster>> getUpcomingRostersFromCache() async {
    // 从 IndexedDB 读取。不打网路，约 50-150ms。
    // 若 cache 尚未建立（首次开启），SDK 丢 unavailable / failed-precondition，
    // catch 后回传空 list，让呼叫端降级到 server fetch。
    try {
      final now = ChurchTime.now();
      final fetchFrom = ChurchTime.dateOnly(
        now,
      ).subtract(const Duration(days: 7));
      final fetchFromTimestamp = Timestamp.fromDate(fetchFrom);

      final snapshot = await _rostersCollection
          .where('date', isGreaterThanOrEqualTo: fetchFromTimestamp)
          .orderBy('date')
          .get(const GetOptions(source: Source.cache));

      return _filterAndSortRosters(snapshot.docs, now);
    } on FirebaseException catch (e) {
      if (e.code == 'unavailable' || e.code == 'failed-precondition') {
        // cache-miss 或持久化尚未就绪：视为空
        return const [];
      }
      rethrow;
    }
  }

  @override
  Future<void> ensureQuarterRosters(List<ServiceType> allowedTypes) async {
    // 确保本季 + 下季的预定 roster 都已存在于 Firestore（缺的补写）。
    // 只补 allowedTypes 涵盖的聚会别 —— 其余的呼叫者无权写，混进同一个 batch
    // 会让整批被 rules 拒绝。真正的强制点仍在 firestore.rules。
    if (allowedTypes.isEmpty) return;
    try {
      final templates = await getServiceTemplates();
      final now = ChurchTime.now();
      final quarterStartMonth = ((now.month - 1) ~/ 3) * 3 + 1;
      // 包含跨季的同一周与 UTC 偏移，避免更换星期后在同一周产生第二场。
      final fetchFrom = DateTime.utc(
        now.year,
        quarterStartMonth,
        1,
      ).subtract(const Duration(days: 7));
      final snapshot = await _rostersCollection
          .where('date', isGreaterThanOrEqualTo: Timestamp.fromDate(fetchFrom))
          .get();
      final existing = snapshot.docs.map(
        (doc) =>
            rosterFromFirestore(doc.data() as Map<String, dynamic>, doc.id),
      );
      final missing = planQuarterRosters(
        now: now,
        types: allowedTypes,
        templates: templates,
        existing: existing,
      );
      // 每个候选周的七个日期都在 transaction 内读取，避免两个使用不同星期
      // 设定的客户端同时建表。每批最多 140 个读取、20 个写入；先全部读再写。
      for (var start = 0; start < missing.length; start += 20) {
        final chunk = missing.skip(start).take(20).toList();
        final weeks = [
          for (final roster in chunk)
            rosterWeekDocumentIds(roster.type, roster.date),
        ];
        await _firestore.runTransaction((transaction) async {
          final snapshots = await Future.wait(
            weeks
                .expand((ids) => ids)
                .toSet()
                .map((id) => transaction.get(_rostersCollection.doc(id))),
          );
          final occupiedIds = {
            for (final snapshot in snapshots)
              if (snapshot.exists) snapshot.id,
          };
          for (var i = 0; i < chunk.length; i++) {
            if (!weeks[i].any(occupiedIds.contains)) {
              transaction.set(
                _rostersCollection.doc(chunk[i].id),
                rosterToFirestore(chunk[i]),
              );
            }
          }
        });
      }
    } catch (e, st) {
      log('ensureQuarterRosters failed', error: e, stackTrace: st);
      rethrow;
    }
  }

  /// 共用的 snapshot → filter → sort 逻辑（供 getUpcomingRosters 与
  /// getUpcomingRostersFromCache 两个读路径重用）。
  List<ServiceRoster> _filterAndSortRosters(
    List<QueryDocumentSnapshot<Object?>> docs,
    DateTime now,
  ) {
    if (docs.isEmpty) return const [];
    final today = ChurchTime.dateOnly(now);
    final endDate = rosterQuarterEnd(now);

    final rosters = docs
        .map((doc) {
          final data = doc.data() as Map<String, dynamic>;
          return rosterFromFirestore(data, doc.id);
        })
        .where((r) => !r.date.isBefore(today) && !r.date.isAfter(endDate))
        .toList();

    rosters.sort((a, b) {
      final dateCompare = a.date.compareTo(b.date);
      if (dateCompare != 0) return dateCompare;
      return a.type.toString().compareTo(b.type.toString());
    });

    return rosters;
  }

  @override
  Future<void> updateRoster(ServiceRoster roster) async {
    try {
      // 确保将 id 写入 document id
      await _rostersCollection.doc(roster.id).set(rosterToFirestore(roster));
    } catch (e, st) {
      log('Update roster failed', error: e, stackTrace: st);
      throw Exception('更新服事表失败: $e');
    }
  }

  @override
  Future<void> updateRostersAtomically(List<ServiceRoster> rosters) async {
    if (rosters.isEmpty) return;
    try {
      final batch = _firestore.batch();
      for (final roster in rosters) {
        batch.set(_rostersCollection.doc(roster.id), rosterToFirestore(roster));
      }
      await batch.commit();
    } catch (e, st) {
      log('Update rosters atomically failed', error: e, stackTrace: st);
      // 刻意不像 updateRoster 那样包成 Exception('更新服事表失败: $e')：包过之后
      // mapErrorToUserMessage 认不出 FirebaseException 的 code，permission-denied
      // 会变成「操作失败，请稍后再试」，使用者不知道是权限问题还是网路问题。
      rethrow;
    }
  }

  @override
  Future<Map<ServiceType, List<String>>> getServiceTemplates() async {
    try {
      final doc = await _templatesDoc.get();
      if (!doc.exists) {
        // 如果没有设定，预设为空，让使用者自行设定
        return {for (final type in ServiceType.values) type: []};
      }

      final data = doc.data() as Map<String, dynamic>;
      return data.map((key, value) {
        final type = ServiceType.fromName(key);
        return MapEntry(type, List<String>.from(value));
      });
    } catch (e, st) {
      log('Get service templates failed', error: e, stackTrace: st);
      rethrow;
    }
  }

  @override
  Future<void> updateServiceTemplates(
    Map<ServiceType, List<String>> templates,
  ) async {
    try {
      final data = templates.map((key, value) {
        return MapEntry(key.name, value);
      });
      await _templatesDoc.set(data, SetOptions(merge: true));
    } catch (e, st) {
      log('Update service templates failed', error: e, stackTrace: st);
      throw Exception('更新样板失败: $e');
    }
  }

  @override
  Future<Map<ServiceType, List<EventOption>>> getEventOptions() async {
    try {
      final doc = await _eventOptionsDoc.get();
      if (!doc.exists) {
        return _defaultEventOptions();
      }

      final data = doc.data() as Map<String, dynamic>;
      final Map<ServiceType, List<EventOption>> result = {};
      for (final type in ServiceType.values) {
        final key = type.name;
        final rawList = data[key];
        if (rawList is List) {
          result[type] = _parseEventOptionsList(rawList);
        } else {
          result[type] = const <EventOption>[];
        }
      }
      return result;
    } catch (e, st) {
      log('Get event options failed', error: e, stackTrace: st);
      rethrow;
    }
  }

  @override
  Future<void> updateEventOptions(
    Map<ServiceType, List<EventOption>> options,
  ) async {
    try {
      final data = options.map((key, value) {
        final cleaned = value
            .map((e) => e.copyWith(name: e.name.trim()))
            .where((e) => e.name.isNotEmpty)
            .map((e) => e.toJson())
            .toList();
        return MapEntry(key.name, cleaned);
      });
      await _eventOptionsDoc.set(data, SetOptions(merge: true));
    } catch (e, st) {
      log('Update event options failed', error: e, stackTrace: st);
      throw Exception('更新事件选项失败: $e');
    }
  }

  Map<ServiceType, List<EventOption>> _defaultEventOptions() {
    return {for (final type in ServiceType.values) type: const <EventOption>[]};
  }

  List<EventOption> _parseEventOptionsList(List<dynamic> items) {
    return items
        .map((item) {
          if (item is String) {
            return EventOption(name: item, color: 0xFFD97706);
          }
          if (item is Map) {
            return EventOption.fromJson(Map<String, dynamic>.from(item));
          }
          return const EventOption(name: '', color: 0xFFD97706);
        })
        .where((e) => e.name.trim().isNotEmpty)
        .toList();
  }

  @override
  Future<Map<ServiceType, StaffOrder>> getStaffOrders() async {
    try {
      final snapshot = await _staffOrdersCollection.get();
      final result = <ServiceType, StaffOrder>{};
      for (final doc in snapshot.docs) {
        final type = ServiceType.values
            .where((e) => e.name == doc.id)
            .firstOrNull;
        if (type == null) continue;
        result[type] = StaffOrder.fromJson(doc.data() as Map<String, dynamic>);
      }
      return result;
    } catch (e, st) {
      log('Get staff orders failed', error: e, stackTrace: st);
      rethrow;
    }
  }

  @override
  Future<void> updateStaffRankings(
    ServiceType type,
    Map<String, List<String>?> changes,
  ) async {
    if (changes.isEmpty) return;
    try {
      // merge 写入巢状 map 只动提到的 key：别人刚改过的其他服事项目不会被
      // 这台装置手上那份旧的盖回去。用 set 而不是 update，文件还不存在时
      // 才建得出来；key 不经过栏位路径解析，服事项目名称有「.」也没关系。
      await _staffOrdersCollection.doc(type.name).set({
        'roles': {
          for (final entry in changes.entries)
            entry.key: entry.value ?? FieldValue.delete(),
        },
      }, SetOptions(merge: true));
    } catch (e, st) {
      log('Update staff order failed', error: e, stackTrace: st);
      // 不包成 Exception：包过之后 mapErrorToUserMessage 认不出
      // permission-denied（见 updateRostersAtomically）。
      rethrow;
    }
  }
}
