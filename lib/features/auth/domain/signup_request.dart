/// 自助注册的申请。待审期间只存在 signup_requests/{uid}，不是正式成员。
class SignupRequest {
  const SignupRequest({
    required this.uid,
    required this.name,
    required this.email,
    this.phone = '',
  });

  final String uid;
  final String name;
  final String email;
  final String phone;

  factory SignupRequest.fromJson(String uid, Map<String, dynamic> json) {
    final name = json['name'];
    final email = json['email'];
    final phone = json['phone'];
    if (name is! String || email is! String) {
      throw const FormatException('signup request');
    }
    return SignupRequest(
      uid: uid,
      name: name,
      email: email,
      phone: phone is String ? phone : '',
    );
  }
}

/// 登入成功，但既没有正式资料也没有待审申请：注册只做到一半，或已被移除。
class SignupIncompleteException implements Exception {
  const SignupIncompleteException();

  final String message = '这个帐号还没有完成注册，或已被移除。请重新注册，或联络管理员';

  @override
  String toString() => message;
}

/// 登入时发现这个帐号还在待审，给使用者的提示。
class SignupPendingException implements Exception {
  const SignupPendingException();

  final String message = '注册申请已提交，等待管理员确认后才能登入';

  @override
  String toString() => message;
}

/// 注册表单的校验。返回 null 表示通过，否则是要显示给使用者的话。
String? validateSignup({
  required String name,
  required String email,
  required String password,
  required bool consented,
}) {
  if (name.trim().isEmpty) return '请输入姓名';
  if (name.trim().length > 100) return '姓名太长了';
  if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email.trim())) {
    return 'Email 格式不正确';
  }
  if (password.length < 8) return '密码至少 8 位';
  if (!consented) return '请先勾选同意条款';
  return null;
}
