import 'package:church_staff_pwa/core/types/service_type.dart';

import '../../auth/domain/entities/user.dart';

/// 服事表上代表「还没排到人」的占位字串。
///
/// 它是占位不是人，所以不能跟真名并存 —— 选人的 dialog、交换、汇入都照这个
/// 规则处理。放在 domain 而不是某个 provider 上，是因为读写服事表的每一层都
/// 要认得它。
const String placeholderPerson = '待定';

/// 某一个崇拜的同工名单：回答「表上这个名字是谁」与「他能不能排这个服事」。
///
/// 以前这两个问题在汇入、选人、交换各算一次，各自决定要不要 trim、同名时
/// 取哪个 uid。收在这里之后规则只有一份。
class StaffDirectory {
  /// 直接给名单。正式流程用 [StaffDirectory.fromUsers]；这个给测试跟
  /// 已经有名单、没有 [User] 物件的呼叫端。
  StaffDirectory({
    required List<String> names,
    Map<String, String> idByName = const {},
    Map<String, Set<String>> namesByRole = const {},
  }) : _names = List.unmodifiable(names),
       _nameSet = names.toSet(),
       _idByName = Map.unmodifiable(idByName),
       _namesByRole = Map.unmodifiable(namesByRole);

  /// [type] 这个崇拜的名单。名字都 trim 过，空白的名字不算。
  ///
  /// 同名同姓的人**不带 uid**：两位都叫王大明时，挑哪一位都是猜，猜错的话
  /// 提醒发给另一个人，而且没有任何迹象。不带 uid 时首页的「我的服事」会
  /// 退回姓名比对，两位都看得到 —— 多一个人看到，好过对的人看不到。
  factory StaffDirectory.fromUsers(List<User> users, ServiceType type) {
    final names = <String>[];
    final idByName = <String, String>{};
    final duplicates = <String>{};
    final namesByRole = <String, Set<String>>{};
    for (final user in users) {
      final name = user.name.trim();
      if (name.isEmpty) continue;
      if (names.contains(name)) duplicates.add(name);
      names.add(name);
      final uid = user.id.trim();
      if (uid.isNotEmpty) idByName.putIfAbsent(name, () => uid);
      for (final zone in user.zones) {
        if (zone.serviceType != type) continue;
        for (final ministry in zone.ministries) {
          final role = ministry.trim();
          if (role.isEmpty) continue;
          namesByRole.putIfAbsent(role, () => <String>{}).add(name);
        }
      }
    }
    return StaffDirectory(
      names: names,
      idByName: {
        for (final entry in idByName.entries)
          if (!duplicates.contains(entry.key)) entry.key: entry.value,
      },
      namesByRole: namesByRole,
    );
  }

  final List<String> _names;
  final Set<String> _nameSet;

  bool _isDuplicate(String name) =>
      _names.indexOf(name) != _names.lastIndexOf(name);
  final Map<String, String> _idByName;
  final Map<String, Set<String>> _namesByRole;

  /// 名单上所有人（所有崇拜），顺序照原本的名单。同名同姓的会出现两次。
  List<String> get names => _names;

  /// 名字 → uid。同名同姓的名字不在里面（见 [StaffDirectory.fromUsers]）。
  Map<String, String> get idByName => _idByName;

  bool contains(String name) => _nameSet.contains(name.trim());

  String? idOf(String name) => _idByName[name.trim()];

  /// 这些名字里查得到 uid 的那几个。
  Map<String, String> idsOf(Iterable<String> names) => {
    for (final name in names) name: ?idOf(name),
  };

  /// 这个人在这个崇拜的服事设定里有没有 [role]。
  bool canServe(String name, String role) =>
      _namesByRole[role.trim()]?.contains(name.trim()) ?? false;

  /// 服事设定里有 [role] 的人，依名字排序。
  List<String> namesForRole(String role) =>
      (_namesByRole[role.trim()]?.toList() ?? <String>[])..sort();

  /// 表上写的 [raw] 是名单上的谁，排在 [role] 合不合他的设定。
  ///
  /// 三层：全名、名单上唯一一位的字尾（表上常省略姓氏）、差一个字的提示。
  /// 前两层会改写成名单上的全名；第三层**不改**，只附上候选。
  NameMatchResult resolve(String raw, String role) {
    final name = raw.trim();
    if (name.isEmpty || name == placeholderPerson) {
      return const NameMatchResult.matched(placeholderPerson);
    }
    if (_nameSet.contains(name)) {
      // 名单上有两位以上叫这个名字：是谁由人决定，跟字尾对到两位一样处理。
      if (_isDuplicate(name)) return NameMatchResult.other(name);
      return canServe(name, role)
          ? NameMatchResult.matched(name)
          : NameMatchResult.roleMismatch(name);
    }
    final matches = _names
        .where((full) => full.length > name.length && full.endsWith(name))
        .toList();
    if (matches.length == 1) {
      final full = matches.first;
      return canServe(full, role)
          ? NameMatchResult.matched(full)
          : NameMatchResult.roleMismatch(full);
    }
    if (matches.length > 1) {
      return NameMatchResult.other(name);
    }
    // 前两层都是精确比对，错一个字就是查无此人 —— 而中文名字的罕用字正是 OCR
    // 最容易认错的地方。这一层不改结果，只把名单里差一个字的那几位附上去，让
    // 管理者自己判断是不是某位的别写法。为什么不自动接，见 [NameMatchResult]
    // 的 suggestions。
    return NameMatchResult.notInList(
      name,
      suggestions: _nearMatches(name, _names),
    );
  }
}

enum NameMatchStatus { matched, notInList, roleMismatch, other }

class NameMatchResult {
  final NameMatchStatus status;
  final String name;

  /// 名单里跟这个名字只差一个字的那几位 —— **只是提示，没有套用**。
  ///
  /// 只会跟 [NameMatchStatus.notInList] 一起出现：名字照表上原文写进服事表，
  /// uid 一个都不带，这几个候选只是列给人看的。
  ///
  /// 不自动接回去是量过之后的决定：名单内部互相拼错一个字时，唯一对到「别的
  /// 真人」的情况是 0 次；会落进这一层的几乎都是**还没有帐号的人**（新同工、
  /// 外来讲员），而他们的名字常常跟某个真人只差一个字（「陈志豪」对上名单里
  /// 的「陈志明」）。自动接的话那个人的服事会被记到别人头上、连上别人的 uid，
  /// 提醒发给错的人，而原本那个名字从表上消失。提示看得到就够了。
  final List<String> suggestions;

  const NameMatchResult(this.status, this.name, {this.suggestions = const []});
  const NameMatchResult.matched(this.name)
    : status = NameMatchStatus.matched,
      suggestions = const [];
  const NameMatchResult.notInList(this.name, {this.suggestions = const []})
    : status = NameMatchStatus.notInList;
  const NameMatchResult.roleMismatch(this.name)
    : status = NameMatchStatus.roleMismatch,
      suggestions = const [];
  const NameMatchResult.other(this.name)
    : status = NameMatchStatus.other,
      suggestions = const [];
}

/// 少于这么多个字就不给形近字提示。
///
/// 一个字的输入会对上半本名单，那种提示没有意义。两个字的照样比 —— 结果只是
/// 提示不会套用，所以「小明」顺便对上「刘美玉」的代价只是多一行字，而漏掉
/// 「雅亭」对上「黄雅婷」才是真的可惜。
const int _minNearMatchRunes = 2;

/// [a] 与 [b] 等长、而且逐位比对刚好只差一个字时回 true。
///
/// 位置对位置，不做插入／删除 —— 形近字是替换，长度不变。改成编辑距离会
/// 让「王大明」对上「王大明峰」这种真的不同的名字。
bool _differsByOneRune(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    if (a[i] == b[i]) continue;
    diff++;
    if (diff > 1) return false;
  }
  return diff == 1;
}

/// 名单里跟 [name] 只差一个字的全名。
///
/// 规则刻意收得很紧，因为猜错的代价是把服事排到另一个真人身上：
///
/// - 只准差一个字，而且输入至少要有 [_minNearMatchRunes] 个字。
/// - 表上写的常是去掉姓氏的简称，所以比的是名单那位的**同长度尾段**。
/// - 回传全部候选，让呼叫端在「不唯一」时退回「不确定是哪一位」，不挑。
///
/// 用 runes 而不是 String 的字元索引：罕用字有些落在 BMP 之外（例如 CJK
/// 扩充 B 区），那些字在 Dart 的 String 里是两个 code unit，逐 code unit
/// 比会把一个字算成两个位置。而罕用字正是这一层要救的东西。
List<String> _nearMatches(String name, List<String> userNames) {
  final target = name.runes.toList();
  if (target.length < _minNearMatchRunes) return const [];
  final matches = <String>[];
  for (final full in userNames) {
    final runes = full.runes.toList();
    if (runes.length < target.length) continue;
    final tail = runes.sublist(runes.length - target.length);
    if (_differsByOneRune(target, tail)) matches.add(full);
  }
  return matches;
}
