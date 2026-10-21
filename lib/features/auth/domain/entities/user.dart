import 'package:church_staff_pwa/core/types/service_type.dart';

/// 身分，不是权限。
///
/// 编辑权限走 [UserGroup]，不看这个栏位 —— 唯一的例外是 [UserRole.admin]，
/// 它等同 root，隐含所有 group。这样「他是谁」跟「他能改什么」可以各自变动：
/// 不是每个小组长都要能编服事表，也不是每个能编行事历的人都是小组长。
enum UserRole {
  admin,
  leader,
  staff,
  member;

  String get label {
    switch (this) {
      case UserRole.admin:
        return '管理员';
      case UserRole.leader:
        return '小组长';
      case UserRole.staff:
        return '同工';
      case UserRole.member:
        return '组员';
    }
  }
}

/// 编辑权限，比照 Linux 的 group：一个人可以同时属于多个，彼此正交 —— 可以只
/// 给行事历不给服事表。管理员等同 root，不必列在任何 group 里就拥有全部。
///
/// 存进 Firestore 的是 [name]（字串），所以这些字串是资料格式的一部分，改名
/// 等于要迁移资料。三个强制点共用同一组名称：这里、`firestore.rules` 的
/// `inGroup()`、`worker/authorize.js` 的 `ACTIONS`。
enum UserGroup {
  rosterEditors('roster-editors', '服事表编辑', '服事表'),
  calendarEditors('calendar-editors', '行事历编辑', '行事历');

  const UserGroup(this.name, this.label, this.shortLabel);

  /// 写进 Firestore 的值。
  final String name;

  /// 勾选框用的完整名称。
  final String label;

  /// 使用者列表的副标只有一行，会被 ellipsis 切掉，所以那里用短名。
  final String shortLabel;

  static UserGroup? byName(String name) {
    for (final group in UserGroup.values) {
      if (group.name == name) return group;
    }
    return null;
  }
}

class UserZoneInfo {
  final ServiceType serviceType;
  final List<String> smallGroups;
  final List<String> ministries;

  const UserZoneInfo({
    required this.serviceType,
    this.smallGroups = const [],
    this.ministries = const [],
  });

  factory UserZoneInfo.fromJson(Map<String, dynamic> json) {
    return UserZoneInfo(
      serviceType: ServiceType.fromName(json['serviceType'] as String? ?? ''),
      smallGroups: List<String>.from(json['smallGroups'] ?? []),
      ministries: List<String>.from(json['ministries'] ?? []),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'serviceType': serviceType.name,
      'smallGroups': smallGroups,
      'ministries': ministries,
    };
  }

  UserZoneInfo copyWith({
    ServiceType? serviceType,
    List<String>? smallGroups,
    List<String>? ministries,
  }) {
    return UserZoneInfo(
      serviceType: serviceType ?? this.serviceType,
      smallGroups: smallGroups ?? this.smallGroups,
      ministries: ministries ?? this.ministries,
    );
  }
}

class User {
  final String id;
  final String name;
  final String email;
  final String username;
  final UserRole role;
  final List<UserZoneInfo> zones;

  /// 这个人被授予的编辑 group。admin 不需要列在里面就拥有全部。
  final Set<UserGroup> groups;

  const User({
    required this.id,
    required this.name,
    required this.email,
    required this.username,
    required this.role,
    this.zones = const [],
    this.groups = const {},
  });

  bool get isAdmin => role == UserRole.admin;

  /// admin 等同 root：隐含所有 group，不必个别授予。
  ///
  /// UI 用这个决定显不显示编辑入口，真正的强制点在 `firestore.rules` 与
  /// `worker/authorize.js` —— 前端挡不住直接打 Firestore 的人。
  bool inGroup(UserGroup group) => isAdmin || groups.contains(group);

  bool get canEditRoster => inGroup(UserGroup.rosterEditors);
  bool get canEditCalendar => inGroup(UserGroup.calendarEditors);

  /// [zones] 摊平成聚会别清单，也就是写进 Firestore 的 `zoneTypes` 栏位。
  ///
  /// 为什么要冗余存一份：`firestore.rules` 没有回圈也没有 map/filter，读不进
  /// `zones`（一个 map 的 list）里的 serviceType。规则要挡住「改别的牧区的服事
  /// 表」就得有一个纯字串阵列可以 `in`。来源仍然只有 zones 一个 —— 这里每次由
  /// zones 重算，不接受外部传入，两边不会漂移。
  ///
  /// 顺序跟著 [ServiceType.values]，理由同 groups：否则同样的内容换个顺序就是
  /// 一笔没有实质变化的 Firestore 写入。
  List<ServiceType> get zoneTypes => [
    for (final type in ServiceType.values)
      if (zones.any((zone) => zone.serviceType == type)) type,
    // 保留未知 ID 供管理员修正设定，不能默默改成其他牧区或丢失原资料。
    ...(zones
        .map((zone) => zone.serviceType)
        .toSet()
        .where((type) => !ServiceType.values.contains(type))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name))),
  ];

  /// 服事表看得到、也改得动哪些聚会别。
  ///
  /// admin 等同 root，拿全部；其他人一律只有自己的牧区 —— 有 roster-editors 也
  /// 不例外。编辑权决定「能不能改」，牧区决定「能改哪一本」，两者相乘。
  /// 服事表分页：停用的聚会不再出现（资料还在，见 ServiceType.active）。
  List<ServiceType> get allowedRosterTypes => isAdmin
      ? ServiceType.active
      : zoneTypes.where(ServiceType.active.contains).toList();

  /// 认不得的东西一律丢掉，绝不抛例外。
  ///
  /// `hasValidGroups()` 只挡得住经过 App 的写入 —— Firebase console 手改、
  /// Admin SDK 脚本、迁移程式都绕得过去。而 [User.fromJson] 是整份名单共用的
  /// 解析路径（`getUsers()` 对整个 snapshot 逐笔 map），所以一份格式坏掉的
  /// 文件若在这里抛 `_TypeError`，倒的不是那一个人，是所有人的帐号管理与服事
  /// 表人员选择器 —— 连管理员要去修那个栏位的画面都打不开。
  ///
  /// 隔壁的 role 也是同样的取舍（`orElse: () => UserRole.member`）。
  static Set<UserGroup> _parseGroups(dynamic raw) {
    if (raw is! List) return const {};
    return raw
        .map((e) => e is String ? UserGroup.byName(e) : null)
        .nonNulls
        .toSet();
  }

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'] as String,
      name: json['name'] as String,
      email: json['email'] as String? ?? '',
      username: json['username'] as String,
      role: UserRole.values.firstWhere(
        (e) => e.name == json['role'],
        orElse: () => UserRole.member,
      ),
      zones:
          (json['zones'] as List<dynamic>?)
              ?.map((e) => UserZoneInfo.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      groups: _parseGroups(json['groups']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'email': email,
      'username': username,
      'role': role.name,
      'zones': zones.map((e) => e.toJson()).toList(),
      // zones 的投影，给 firestore.rules 用。见 [zoneTypes]。
      'zoneTypes': [for (final type in zoneTypes) type.name],
      // 顺序固定，否则每次存档都会产生一笔没有实质变化的 Firestore 写入。
      'groups': [
        for (final group in UserGroup.values)
          if (groups.contains(group)) group.name,
      ],
    };
  }

  User copyWith({
    String? id,
    String? name,
    String? email,
    String? username,
    UserRole? role,
    List<UserZoneInfo>? zones,
    Set<UserGroup>? groups,
  }) {
    return User(
      id: id ?? this.id,
      name: name ?? this.name,
      email: email ?? this.email,
      username: username ?? this.username,
      role: role ?? this.role,
      zones: zones ?? this.zones,
      groups: groups ?? this.groups,
    );
  }
}
