import 'package:church_staff_pwa/core/types/service_type.dart';

import 'entities/service_roster.dart';
import 'staff_directory.dart';

/// 一个服事项目由前到后的同工。选人视窗拖完送出的就是这个。
class StaffRanking {
  const StaffRanking(this.role, this.names);

  final String role;
  final List<String> names;
}

/// 一个崇拜里，每个服事项目的同工排序：主要的人排前面。
///
/// 顺序是「人」的属性，不是「某一天」的属性。以前每一天各存一份顺序，交换
/// 是就地换掉那个位置上的人 —— 主要同工换到别天就排到第二个，换进来的人
/// 反而跑到第一个。现在每一天的名字一律照这份排，交换、汇入、勾选都不必
/// 再管位置。
///
/// 服事表的图片本身就照这个顺序排，所以汇入时直接从图片学（见
/// [StaffOrder.learnFrom]）；在选人视窗拖曳则是调整这一份。
class StaffOrder {
  StaffOrder([Map<String, List<String>> rankingsByRole = const {}])
    : _byRole = Map.unmodifiable({
        for (final entry in rankingsByRole.entries)
          if (entry.key.trim().isNotEmpty)
            entry.key.trim(): List<String>.unmodifiable(
              _cleanNames(entry.value),
            ),
      });

  final Map<String, List<String>> _byRole;

  /// 有排过顺序的服事项目 → 由前到后的名字。
  Map<String, List<String>> get rankingsByRole => _byRole;

  bool get isEmpty => _byRole.isEmpty;

  /// [role] 的排序。没排过就是空的。
  List<String> rankingOf(String role) => _byRole[role.trim()] ?? const [];

  /// 把 [people] 照 [role] 的排序排好。
  ///
  /// 排序里没有的人（例如外请讲员）接在后面，彼此维持原本的先后。只有一个
  /// 人、或全部都不在排序里时原样回传同一个 List，呼叫端可以用 `identical`
  /// 知道什么都没变。
  List<String> sort(String role, List<String> people) {
    if (people.length < 2) return people;
    final ranking = rankingOf(role);
    if (ranking.isEmpty) return people;
    final rank = {for (var i = 0; i < ranking.length; i++) ranking[i]: i};
    final indexed = [
      for (var i = 0; i < people.length; i++) (name: people[i], at: i),
    ];
    // 不在排序里的人排在所有排过的人之后，自己人之间照原本位置 —— 用原
    // 位置当第二键，Dart 的 sort 不保证稳定。
    indexed.sort((a, b) {
      final ra = rank[a.name.trim()] ?? ranking.length;
      final rb = rank[b.name.trim()] ?? ranking.length;
      if (ra != rb) return ra.compareTo(rb);
      return a.at.compareTo(b.at);
    });
    var changed = false;
    for (var i = 0; i < indexed.length; i++) {
      if (indexed[i].at != i) {
        changed = true;
        break;
      }
    }
    if (!changed) return people;
    return [for (final entry in indexed) entry.name];
  }

  /// 照这份排序排好 [roster] 里每一项服事的人。没有任何改变时回传同一个
  /// 物件。
  ServiceRoster applyTo(ServiceRoster roster) {
    if (isEmpty) return roster;
    var changed = false;
    final duties = [
      for (final duty in roster.duties)
        () {
          final sorted = sort(duty.role, duty.people);
          if (identical(sorted, duty.people)) return duty;
          changed = true;
          return duty.copyWith(people: sorted);
        }(),
    ];
    return changed ? roster.copyWith(duties: duties) : roster;
  }

  /// 换掉 [role] 的排序。[ranking] 是空的就等于拿掉这一项。
  StaffOrder withRanking(String role, List<String> ranking) {
    final key = role.trim();
    final next = Map<String, List<String>>.of(_byRole);
    final cleaned = _cleanNames(ranking);
    if (cleaned.isEmpty) {
      next.remove(key);
    } else {
      next[key] = cleaned;
    }
    return StaffOrder(next);
  }

  /// 把 [newer] 排过的服事项目并进来：[newer] 提到的人照它的先后，没提到
  /// 的人留在原位。
  ///
  /// 「留在原位」而不是「排到最后」：主要同工这一季请假、不在这次的图片上，
  /// 不代表他不再是主要同工 —— 挤到最后的话，他回来那天就排在新人后面。
  ///
  /// 做法是把 [newer] 也有的那几个人原本占的位置，照 [newer] 的顺序重新填
  /// 一次；只有 [newer] 有的人插在 [newer] 里他前一位的后面（他是第一位时插
  /// 在后面第一个认得的人前面）。
  StaffOrder mergedWith(StaffOrder newer) {
    final next = Map<String, List<String>>.of(_byRole);
    for (final entry in newer._byRole.entries) {
      next[entry.key] = _merge(next[entry.key] ?? const [], entry.value);
    }
    return StaffOrder(next);
  }

  static List<String> _merge(List<String> base, List<String> newer) {
    final baseSet = base.toSet();
    final newerSet = newer.toSet();
    final known = newer.where(baseSet.contains).iterator;
    final result = [
      for (final name in base)
        if (newerSet.contains(name)) (known..moveNext()).current else name,
    ];
    for (var i = 0; i < newer.length; i++) {
      final name = newer[i];
      if (baseSet.contains(name)) continue;
      if (i > 0) {
        result.insert(result.indexOf(newer[i - 1]) + 1, name);
        continue;
      }
      final following = newer.skip(1).where(baseSet.contains).firstOrNull;
      if (following == null) {
        result.add(name);
      } else {
        result.insert(result.indexOf(following), name);
      }
    }
    return result;
  }

  /// 只留 [keep] 认得的人。汇入时用来把外请讲员这类名单外的名字拿掉 ——
  /// 他们在图片上排第几只是那一次的事，写进固定排序的话，之后新加入的同工
  /// 都会排在他们后面。
  StaffOrder where(bool Function(String name) keep) => StaffOrder({
    for (final entry in _byRole.entries)
      entry.key: entry.value.where(keep).toList(),
  });

  /// 变成 [next] 要改哪些服事项目：有变的给新的排序，拿掉的给 null。
  ///
  /// 写回 Firestore 只写这几项，不整份覆写 —— 这台装置手上的排序可能是旧的
  /// （别人刚改过别项），也可能根本没读到，整份写回会把别人的改动盖掉。
  Map<String, List<String>?> changesTo(StaffOrder next) {
    final changes = <String, List<String>?>{};
    for (final entry in next._byRole.entries) {
      if (!_sameNames(_byRole[entry.key], entry.value)) {
        changes[entry.key] = entry.value;
      }
    }
    for (final role in _byRole.keys) {
      if (!next._byRole.containsKey(role)) changes[role] = null;
    }
    return changes;
  }

  /// 套上 [changesTo] 算出来的改动。
  StaffOrder withChanges(Map<String, List<String>?> changes) {
    final next = Map<String, List<String>>.of(_byRole);
    for (final entry in changes.entries) {
      final ranking = entry.value;
      if (ranking == null) {
        next.remove(entry.key);
      } else {
        next[entry.key] = ranking;
      }
    }
    return StaffOrder(next);
  }

  /// 服事项目改名时，排序跟著搬过去。
  StaffOrder withRolesRenamed(Map<String, String> renamed) {
    if (renamed.isEmpty) return this;
    final next = <String, List<String>>{};
    for (final entry in _byRole.entries) {
      next[renamed[entry.key] ?? entry.key] = entry.value;
    }
    return StaffOrder(next);
  }

  /// 从现有的服事表学出排序：每个人在那一项服事里平均排第几。
  ///
  /// 平均而不是「最后一次」：图片偶尔会把两个人的先后写反，一次例外不该
  /// 盖掉其他几周的共识。平均一样时照先出现的排（[rosters] 由早到晚给）。
  ///
  /// 只有一个人的那几天不算：没有别人可以比，放进来只会把大家的平均都往
  /// 0 拉，让「总是一个人上」的服事项目也排出一份没有意义的顺序。
  static StaffOrder learnFrom(Iterable<ServiceRoster> rosters) {
    final totals = <String, Map<String, ({int sum, int count, int first})>>{};
    var seen = 0;
    for (final roster in rosters) {
      for (final duty in roster.duties) {
        final people = _cleanNames(duty.people);
        if (people.length < 2) continue;
        final byName = totals.putIfAbsent(duty.role.trim(), () => {});
        for (var i = 0; i < people.length; i++) {
          final prev = byName[people[i]];
          byName[people[i]] = (
            sum: (prev?.sum ?? 0) + i,
            count: (prev?.count ?? 0) + 1,
            first: prev?.first ?? seen,
          );
          seen++;
        }
      }
    }
    return StaffOrder({
      for (final entry in totals.entries)
        entry.key:
            (entry.value.entries.toList()..sort((a, b) {
                  final avgA = a.value.sum / a.value.count;
                  final avgB = b.value.sum / b.value.count;
                  if (avgA != avgB) return avgA.compareTo(avgB);
                  return a.value.first.compareTo(b.value.first);
                }))
                .map((e) => e.key)
                .toList(),
    });
  }

  factory StaffOrder.fromJson(Map<String, dynamic> json) {
    final roles = json['roles'];
    if (roles is! Map) return StaffOrder();
    return StaffOrder({
      for (final entry in roles.entries)
        if (entry.key is String && entry.value is List)
          entry.key as String: [
            for (final name in entry.value as List)
              if (name is String) name,
          ],
    });
  }

  Map<String, dynamic> toJson() => {'roles': _byRole};

  @override
  bool operator ==(Object other) {
    if (other is! StaffOrder) return false;
    if (other._byRole.length != _byRole.length) return false;
    for (final entry in _byRole.entries) {
      if (!_sameNames(other._byRole[entry.key], entry.value)) return false;
    }
    return true;
  }

  static bool _sameNames(List<String>? a, List<String> b) {
    if (a == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(
    _byRole.entries.map((e) => Object.hash(e.key, Object.hashAll(e.value))),
  );

  /// trim、去掉空白与「待定」、去重，保留先后。
  static List<String> _cleanNames(Iterable<String> names) {
    final result = <String>[];
    for (final raw in names) {
      final name = raw.trim();
      if (name.isEmpty || name == placeholderPerson) continue;
      if (result.contains(name)) continue;
      result.add(name);
    }
    return result;
  }
}

/// 每个崇拜实际采用的同工排序。
///
/// 存下来的（有人拖过、或汇入时从图片学的）优先；没存过的服事项目退回从
/// 现有服事表学出来的顺序，所以这个功能上线前的资料一样排得好。
class StaffOrderBook {
  StaffOrderBook({
    Map<ServiceType, StaffOrder> stored = const {},
    Map<ServiceType, StaffOrder> learned = const {},
  }) : _stored = stored,
       _learned = learned;

  final Map<ServiceType, StaffOrder> _stored;
  final Map<ServiceType, StaffOrder> _learned;
  final Map<ServiceType, StaffOrder> _effective = {};

  /// [type] 存在 Firestore 上的那份（就这台装置所知）。
  StaffOrder storedFor(ServiceType type) => _stored[type] ?? StaffOrder();

  /// [type] 实际拿来排的那份。
  StaffOrder effectiveFor(ServiceType type) => _effective[type] ??=
      (_learned[type] ?? StaffOrder()).mergedWith(storedFor(type));

  /// 照 [roster] 那个崇拜的排序排好。
  ServiceRoster sort(ServiceRoster roster) =>
      effectiveFor(roster.type).applyTo(roster);

  /// 从 [rosters] 重新学一次。只给「从外面读进来」的资料用：本机写入前已经
  /// 照排序排好，拿来重学只会得到一样的东西。
  StaffOrderBook relearnedFrom(Iterable<ServiceRoster> rosters) =>
      StaffOrderBook(
        stored: _stored,
        learned: {
          for (final type in ServiceType.values)
            type: StaffOrder.learnFrom(rosters.where((r) => r.type == type)),
        },
      );

  StaffOrderBook withStored(Map<ServiceType, StaffOrder> stored) =>
      StaffOrderBook(stored: stored, learned: _learned);

  StaffOrderBook withStoredFor(ServiceType type, StaffOrder order) =>
      withStored({..._stored, type: order});
}
