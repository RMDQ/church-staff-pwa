import 'package:church_staff_pwa/features/auth/domain/signup_request.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('validateSignup', () {
    String? check({
      String name = '王小明',
      String email = 'wang@example.com',
      String password = '12345678',
      bool consented = true,
    }) => validateSignup(
      name: name,
      email: email,
      password: password,
      consented: consented,
    );

    test('accepts a complete, consented form', () {
      expect(check(), isNull);
    });

    test('asks for a name', () {
      expect(check(name: '   '), '请输入姓名');
    });

    test('rejects a malformed email', () {
      expect(check(email: 'not-an-email'), 'Email 格式不正确');
      expect(check(email: 'a b@example.com'), 'Email 格式不正确');
    });

    test('requires a password of at least 8 characters', () {
      expect(check(password: '1234567'), '密码至少 8 位');
      expect(check(password: '12345678'), isNull);
    });

    test('requires consent', () {
      expect(check(consented: false), '请先勾选同意条款');
    });
  });

  group('SignupRequest.fromJson', () {
    test('reads a pending request', () {
      final request = SignupRequest.fromJson('uid-1', {
        'name': '王小明',
        'email': 'wang@example.com',
        'phone': '+39 06 0000',
        'status': 'pending',
      });
      expect(request.uid, 'uid-1');
      expect(request.name, '王小明');
      expect(request.email, 'wang@example.com');
      expect(request.phone, '+39 06 0000');
    });

    test('phone is optional', () {
      final request = SignupRequest.fromJson('uid-2', {
        'name': '李小华',
        'email': 'li@example.com',
      });
      expect(request.phone, '');
    });

    test('a request without a name or email is refused, not guessed', () {
      expect(
        () => SignupRequest.fromJson('uid-3', {'email': 'x@example.com'}),
        throwsFormatException,
      );
    });
  });

  test('the pending exception says what the member should do', () {
    expect(const SignupPendingException().message, contains('等待管理员确认'));
  });
}
