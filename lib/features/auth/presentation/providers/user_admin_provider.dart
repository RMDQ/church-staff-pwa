import 'package:flutter/material.dart';
import '../../domain/entities/user.dart';
import 'package:church_staff_pwa/core/types/service_type.dart';
import '../../domain/repositories/auth_repository.dart';
import 'session_provider.dart';

class UserAdminProvider extends ChangeNotifier {
  final AuthRepository _repository;
  final SessionProvider _session;

  // 同工选择 dialog 每次开启都要列全部使用者，避免重复打 Firestore。
  // 任何 admin 写操作（addUser/updateUser/deleteUser）或登出后会清掉。
  List<User>? _cachedUsers;

  UserAdminProvider(this._repository, this._session) {
    // 当 session currentUser 变成 null（登出），自动清掉 cache。
    _session.addListener(_onSessionChanged);
  }

  void _onSessionChanged() {
    if (_session.currentUser == null && _cachedUsers != null) {
      _cachedUsers = null;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _session.removeListener(_onSessionChanged);
    super.dispose();
  }

  /// 列出所有使用者。
  ///
  /// 这里放宽到 canEditRoster 而非 isAdmin：服事表编辑的人员选择器要靠它列
  /// 名单（roster_edit_screen、roster_card），拿不到名单就编不了服事表。
  /// 绑 roster 而非「任何 group」是刻意的 —— 只有行事历权限的人不需要名单。
  /// 其余的 add/update/delete 全部维持 isAdmin —— 读名单跟改身分是两件事。
  Future<List<User>> getUsers({bool forceRefresh = false}) async {
    if (!_session.canEditRoster) throw Exception('Permission denied');
    if (!forceRefresh && _cachedUsers != null) {
      return _cachedUsers!;
    }
    final users = await _repository.getUsers();
    // 若 fetch 进行中 session 已切换（登出或换帐号），不写入 cache 以免污染新 session。
    if (_session.currentUser == null || !_session.canEditRoster) {
      return users;
    }
    _cachedUsers = users;
    return users;
  }

  Future<void> addUser(
    String name,
    String email,
    String username,
    UserRole role, {
    required String password,
    List<UserZoneInfo> zones = const [],
    Set<UserGroup> groups = const {},
  }) async {
    if (!_session.isAdmin) throw Exception('Permission denied');

    final newUser = User(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      email: email,
      username: username,
      role: role,
      zones: zones,
      groups: groups,
    );
    await _repository.addUser(newUser, password);
    _cachedUsers = null;
    notifyListeners();
  }

  Future<void> updateUser(User user, {String? password}) async {
    if (!_session.isAdmin) throw Exception('Permission denied');
    // 唯一的管理员把自己降级，网站就没有人能管了（规则也挡，见 firestore.rules）。
    if (user.id == _session.currentUser?.id && !user.isAdmin) {
      throw const AccountSafetyException(
        '不能拿掉自己的管理员权限。要换人管理，请先把另一位同工设成管理员，再请他帮你改。',
      );
    }
    await _repository.updateUser(user, password: password);

    // 若是管理员在修改自己的资料，通知 SessionProvider 更新 currentUser。
    _session.refreshCurrentUser(user);

    _cachedUsers = null;
    notifyListeners();
  }

  Future<void> deleteUser(String id) async {
    if (!_session.isAdmin) throw Exception('Permission denied');
    if (id == _session.currentUser?.id) {
      throw const AccountSafetyException('不能删除自己的帐号。要删的话，请另一位管理员帮你删。');
    }
    await _repository.deleteUser(id);
    _cachedUsers = null;
    notifyListeners();
  }

  Future<void> cleanupUserMinistries(
    Map<ServiceType, List<String>> templates,
  ) async {
    if (!_session.isAdmin) throw Exception('Permission denied');

    final users = await _repository.getUsers();
    for (final user in users) {
      bool changed = false;
      final updatedZones = user.zones.map((zone) {
        final allowed = templates[zone.serviceType] ?? const <String>[];
        final filtered = zone.ministries.where(allowed.contains).toList();
        if (filtered.length != zone.ministries.length) {
          changed = true;
        }
        return zone.copyWith(ministries: filtered);
      }).toList();

      if (changed) {
        await _repository.updateUser(user.copyWith(zones: updatedZones));
      }
    }

    _cachedUsers = null;
    notifyListeners();
  }

  Future<void> cleanupUserSmallGroups(
    Map<ServiceType, List<String>> templates,
  ) async {
    if (!_session.isAdmin) throw Exception('Permission denied');

    final users = await _repository.getUsers();
    for (final user in users) {
      bool changed = false;
      final updatedZones = user.zones.map((zone) {
        final allowed = templates[zone.serviceType] ?? const <String>[];
        final filtered = zone.smallGroups.where(allowed.contains).toList();
        if (filtered.length != zone.smallGroups.length) {
          changed = true;
        }
        return zone.copyWith(smallGroups: filtered);
      }).toList();

      if (changed) {
        await _repository.updateUser(user.copyWith(zones: updatedZones));
      }
    }

    _cachedUsers = null;
    notifyListeners();
  }
}

/// 会让网站没有管理员的操作。讯息直接给使用者看。
class AccountSafetyException implements Exception {
  const AccountSafetyException(this.message);

  final String message;

  @override
  String toString() => message;
}
