import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart'
    show FirebaseAuth, FirebaseAuthException, UserCredential;

import '../domain/entities/user.dart';
import '../domain/signup_request.dart';

/// 同意条款的版本。条款改了就加一个新的值，旧的同意记录保留。
const String signupConsentVersion = '2026-10';

/// 注册失败，message 直接显示给使用者。
class SignupException implements Exception {
  const SignupException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 自助注册与管理员审核。
///
/// 注册只会得到一个待审申请，不会得到正式成员身份。管理员通过后才建立
/// users/{uid}，之后该成员才能登入、看见服事表、打卡。
class SignupRepository {
  // 不在构造时读取 Firebase 实例：预览和测试可以直接子类化，不需要初始化 Firebase。
  SignupRepository({FirebaseAuth? auth, FirebaseFirestore? firestore})
    : _auth = auth,
      _firestore = firestore;

  final FirebaseAuth? _auth;
  final FirebaseFirestore? _firestore;

  FirebaseAuth get _authClient => _auth ?? FirebaseAuth.instance;
  FirebaseFirestore get _db => _firestore ?? FirebaseFirestore.instance;

  CollectionReference get _requests => _db.collection('signup_requests');
  CollectionReference get _users => _db.collection('users');

  /// 建立登入帐号、寄出验证信，并写下待审申请。注册后会自动登出。
  Future<void> submit({
    required String name,
    required String email,
    required String password,
    String phone = '',
  }) async {
    final trimmedEmail = email.trim();
    final UserCredential credential;
    try {
      credential = await _authClient.createUserWithEmailAndPassword(
        email: trimmedEmail,
        password: password,
      );
    } on FirebaseAuthException catch (error) {
      throw SignupException(_authMessage(error.code));
    }

    final user = credential.user;
    if (user == null) {
      throw const SignupException('注册失败，请稍后再试');
    }

    try {
      // 寄信失败不阻止申请；使用者登入后可以再寄一次。
      await user.sendEmailVerification();
    } catch (_) {}

    try {
      await _requests.doc(user.uid).set({
        'name': name.trim(),
        'email': trimmedEmail,
        if (phone.trim().isNotEmpty) 'phone': phone.trim(),
        'consentAt': FieldValue.serverTimestamp(),
        'consentVersion': signupConsentVersion,
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {
      throw const SignupException('帐号已建立，但申请没有提交成功，请联络管理员协助处理');
    } finally {
      // 待审之前不保持登入：看不到任何内容，也避免误以为已经是成员。
      await _authClient.signOut();
    }
  }

  /// 管理员：所有待审的申请。
  Future<List<SignupRequest>> pendingRequests() async {
    final snapshot = await _requests
        .where('status', isEqualTo: 'pending')
        .get();
    final requests = <SignupRequest>[];
    for (final doc in snapshot.docs) {
      final data = doc.data();
      if (data is! Map<String, dynamic>) continue;
      try {
        requests.add(SignupRequest.fromJson(doc.id, data));
      } on FormatException {
        // 格式不对的申请跳过，不让整个列表打不开。
      }
    }
    return requests;
  }

  /// 管理员通过：建立组员身份（没有群组和牧区），再删除申请。
  /// 先建正式账号，再删申请：中途失败时最多是申请还在，成员已经存在。
  Future<void> approve(SignupRequest request) async {
    final member = User(
      id: request.uid,
      name: request.name,
      email: request.email,
      username: request.name,
      role: UserRole.member,
    );
    // 电话只存在正式成员文档里，User 模型不读它；管理员在资料里需要时可以看到。
    await _users.doc(request.uid).set({
      ...member.toJson(),
      if (request.phone.isNotEmpty) 'phone': request.phone,
    });
    await _requests.doc(request.uid).delete();
  }

  /// 管理员拒绝：删除申请。帐号本身保留，但没有成员资料，登入后看不到内容。
  Future<void> reject(String uid) => _requests.doc(uid).delete();

  static String _authMessage(String code) {
    switch (code) {
      case 'email-already-in-use':
        return '这个 Email 已经注册过。请直接登入；如果一直显示等待确认，请联络管理员';
      case 'weak-password':
        return '密码太弱，请换一个更长的密码';
      case 'invalid-email':
        return 'Email 格式不正确';
      case 'network-request-failed':
        return '网络连线失败，请检查网络后再试';
      default:
        return '注册失败，请稍后再试';
    }
  }
}
