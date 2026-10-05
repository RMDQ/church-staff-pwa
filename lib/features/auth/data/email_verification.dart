import 'package:firebase_auth/firebase_auth.dart' show FirebaseAuth;

/// 邮箱验证状态。打卡前必须验证，所以这里提供重新发送与刷新。
class EmailVerification {
  EmailVerification({FirebaseAuth? auth}) : _auth = auth;

  final FirebaseAuth? _auth;

  FirebaseAuth get _client => _auth ?? FirebaseAuth.instance;

  /// 没有登录账号、或读不到 Firebase 时视为已验证，不在这里挡住别人
  /// （打卡接口会再检查一次）。
  bool get isVerified {
    try {
      return _client.currentUser?.emailVerified ?? true;
    } catch (_) {
      return true;
    }
  }

  /// 重新寄一封验证信。
  Future<void> resend() async {
    await _client.currentUser?.sendEmailVerification();
  }

  /// 向服务器重新读取验证状态，点了邮件里的链接之后用。
  Future<bool> refresh() async {
    try {
      await _client.currentUser?.reload();
    } catch (_) {
      // 读不到就保持原来的判断，下一次再试。
    }
    return isVerified;
  }
}
