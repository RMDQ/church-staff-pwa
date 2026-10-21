import 'package:church_staff_pwa/features/auth/domain/entities/user.dart';
import 'package:church_staff_pwa/features/auth/domain/repositories/auth_repository.dart';

/// 测试共用的 [AuthRepository]：[user] 已经登入，什么都不写。
///
/// 给只需要「有人登入」的 widget 测试 —— SessionProvider 要还原出一个使用者，
/// UserAdminProvider.getUsers() 才过得了权限检查。要模拟登入失败、阻塞或计数
/// 的测试各自有自己的 fake（session_provider_test、user_admin_provider_test）。
class SignedInAuthRepository implements AuthRepository {
  SignedInAuthRepository(this.user, {List<User>? users})
    : users = users ?? [?user];

  final User? user;

  /// [getUsers] 回传的同工名单。预设只有登入的那个人。
  final List<User> users;

  /// 每次 [sendPasswordResetEmail] 收到的 Email，依呼叫顺序。
  final List<String> resetEmails = [];

  /// 不为 null 时 [sendPasswordResetEmail] 会丢出这个例外。
  Object? resetException;

  @override
  Future<User?> getCachedUser() async => user;
  @override
  Future<User?> getCurrentUser() async => user;
  @override
  Future<void> writeCachedUser(User user) async {}
  @override
  Future<User?> login(String username, String password) async => user;
  @override
  Future<void> logout() async {}
  @override
  Future<void> sendPasswordResetEmail(String email) async {
    resetEmails.add(email);
    if (resetException != null) throw resetException!;
  }

  @override
  Future<List<User>> getUsers() async => users;
  @override
  Future<void> addUser(User user, String password) async {}
  @override
  Future<void> updateUser(User user, {String? password}) async {}
  @override
  Future<void> deleteUser(String id) async {}
}
