import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:church_staff_pwa/core/utils/error_messages.dart';

void main() {
  group('mapErrorToUserMessage', () {
    // ── FirebaseAuthException ──────────────────────────────────────────────

    test('user-not-found → 帐号或密码错误', () {
      // ignore: invalid_use_of_protected_member
      final e = FirebaseAuthException(code: 'user-not-found');
      expect(mapErrorToUserMessage(e), '帐号或密码错误');
    });

    test('wrong-password → 帐号或密码错误', () {
      // ignore: invalid_use_of_protected_member
      final e = FirebaseAuthException(code: 'wrong-password');
      expect(mapErrorToUserMessage(e), '帐号或密码错误');
    });

    test('invalid-credential → 帐号或密码错误', () {
      // ignore: invalid_use_of_protected_member
      final e = FirebaseAuthException(code: 'invalid-credential');
      expect(mapErrorToUserMessage(e), '帐号或密码错误');
    });

    test('user-disabled → 帐号已被停用', () {
      // ignore: invalid_use_of_protected_member
      final e = FirebaseAuthException(code: 'user-disabled');
      expect(mapErrorToUserMessage(e), '帐号已被停用，请联络管理员');
    });

    test('email-already-in-use → 此电子邮件已被注册', () {
      // ignore: invalid_use_of_protected_member
      final e = FirebaseAuthException(code: 'email-already-in-use');
      expect(mapErrorToUserMessage(e), '此电子邮件已被注册');
    });

    test('weak-password → 密码强度不足', () {
      // ignore: invalid_use_of_protected_member
      final e = FirebaseAuthException(code: 'weak-password');
      expect(mapErrorToUserMessage(e), '密码强度不足，至少 6 个字元');
    });

    test('invalid-email → 电子邮件格式错误', () {
      // ignore: invalid_use_of_protected_member
      final e = FirebaseAuthException(code: 'invalid-email');
      expect(mapErrorToUserMessage(e), '电子邮件格式错误');
    });

    test('network-request-failed → 网路连线失败', () {
      // ignore: invalid_use_of_protected_member
      final e = FirebaseAuthException(code: 'network-request-failed');
      expect(mapErrorToUserMessage(e), '网路连线失败，请检查网路');
    });

    test('too-many-requests → 登入尝试次数过多', () {
      // ignore: invalid_use_of_protected_member
      final e = FirebaseAuthException(code: 'too-many-requests');
      expect(mapErrorToUserMessage(e), '登入尝试次数过多，请稍后再试');
    });

    test('FirebaseAuthException 未知 code → fallback 登入失败', () {
      // ignore: invalid_use_of_protected_member
      final e = FirebaseAuthException(code: 'some-unknown-auth-error');
      expect(mapErrorToUserMessage(e), '登入失败，请稍后再试');
    });

    // ── FirebaseException（Firestore / Storage 等）─────────────────────────

    test('permission-denied → 没有权限', () {
      final e = FirebaseException(
        plugin: 'cloud_firestore',
        code: 'permission-denied',
      );
      expect(mapErrorToUserMessage(e), '没有权限执行此操作，请联络管理员');
    });

    test('unavailable → 网路不稳', () {
      final e = FirebaseException(
        plugin: 'cloud_firestore',
        code: 'unavailable',
      );
      expect(mapErrorToUserMessage(e), '网路不稳，请稍后再试');
    });

    test('deadline-exceeded → 网路不稳', () {
      final e = FirebaseException(
        plugin: 'cloud_firestore',
        code: 'deadline-exceeded',
      );
      expect(mapErrorToUserMessage(e), '网路不稳，请稍后再试');
    });

    test('not-found → 资料不存在', () {
      final e = FirebaseException(plugin: 'cloud_firestore', code: 'not-found');
      expect(mapErrorToUserMessage(e), '资料不存在');
    });

    test('already-exists → 资料已存在', () {
      final e = FirebaseException(
        plugin: 'cloud_firestore',
        code: 'already-exists',
      );
      expect(mapErrorToUserMessage(e), '资料已存在');
    });

    test('failed-precondition → 操作条件不符', () {
      final e = FirebaseException(
        plugin: 'cloud_firestore',
        code: 'failed-precondition',
      );
      expect(mapErrorToUserMessage(e), '操作条件不符，请重新整理页面');
    });

    test('FirebaseException 未知 code → 资料处理失败 fallback', () {
      final e = FirebaseException(
        plugin: 'cloud_firestore',
        code: 'some-unknown-code',
      );
      expect(mapErrorToUserMessage(e), '资料处理失败，请稍后再试');
    });

    // ── TimeoutException ───────────────────────────────────────────────────

    test('TimeoutException → 操作逾时', () {
      final e = TimeoutException('timeout');
      expect(mapErrorToUserMessage(e), '操作逾时，请稍后再试');
    });

    test('TimeoutException（duration 为 null）→ 操作逾时', () {
      final e = TimeoutException(null);
      expect(mapErrorToUserMessage(e), '操作逾时，请稍后再试');
    });

    // ── null 与其他 Exception ──────────────────────────────────────────────

    test('null 输入 → 操作失败 fallback', () {
      expect(mapErrorToUserMessage(null), '操作失败，请稍后再试');
    });

    test('一般 Exception → 操作失败 fallback', () {
      expect(mapErrorToUserMessage(Exception('some error')), '操作失败，请稍后再试');
    });

    test('字串型例外（非 Exception 物件）→ 操作失败 fallback', () {
      expect(mapErrorToUserMessage('random error string'), '操作失败，请稍后再试');
    });

    test('StateError → 操作失败 fallback', () {
      expect(mapErrorToUserMessage(StateError('bad state')), '操作失败，请稍后再试');
    });
  });

  group('mapPasswordResetErrorToUserMessage', () {
    test('user-not-found 当成已寄出，不透露帐号存不存在', () {
      // ignore: invalid_use_of_protected_member
      final e = FirebaseAuthException(code: 'user-not-found');
      expect(mapPasswordResetErrorToUserMessage(e), isNull);
    });

    test('invalid-email → 电子邮件格式错误', () {
      // ignore: invalid_use_of_protected_member
      final e = FirebaseAuthException(code: 'invalid-email');
      expect(mapPasswordResetErrorToUserMessage(e), '电子邮件格式错误');
    });

    test('too-many-requests 讲寄送，不讲登入', () {
      // ignore: invalid_use_of_protected_member
      final e = FirebaseAuthException(code: 'too-many-requests');
      expect(mapPasswordResetErrorToUserMessage(e), '寄送次数过多，请稍后再试');
    });

    test('其他例外 → 无法寄出重设信', () {
      expect(
        mapPasswordResetErrorToUserMessage(Exception('boom')),
        '无法寄出重设信，请稍后再试',
      );
    });
  });
}
