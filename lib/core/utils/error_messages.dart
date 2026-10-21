import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';

/// 将任意例外转换为对非技术使用者友善的繁中讯息。
///
/// 呼叫端应另外以 [dart:developer] 的 [log] 记录原始 error 与 stackTrace，
/// 保留完整资讯供未来串接 Sentry 使用。
String mapErrorToUserMessage(Object? error) {
  // 1. FirebaseAuthException（登入/Auth 相关）
  if (error is FirebaseAuthException) {
    return switch (error.code) {
      'user-not-found' || 'invalid-credential' || 'wrong-password' => '帐号或密码错误',
      'user-disabled' => '帐号已被停用，请联络管理员',
      'email-already-in-use' => '此电子邮件已被注册',
      'weak-password' => '密码强度不足，至少 6 个字元',
      'invalid-email' => '电子邮件格式错误',
      'network-request-failed' => '网路连线失败，请检查网路',
      'too-many-requests' => '登入尝试次数过多，请稍后再试',
      _ => '登入失败，请稍后再试',
    };
  }

  // 2. FirebaseException（Firestore、Storage 等）
  if (error is FirebaseException) {
    return switch (error.code) {
      'permission-denied' => '没有权限执行此操作，请联络管理员',
      'unavailable' || 'deadline-exceeded' => '网路不稳，请稍后再试',
      'not-found' => '资料不存在',
      'already-exists' => '资料已存在',
      'failed-precondition' => '操作条件不符，请重新整理页面',
      _ => '资料处理失败，请稍后再试',
    };
  }

  // 3. TimeoutException
  if (error is TimeoutException) {
    return '操作逾时，请稍后再试';
  }

  // 4. 其他所有例外
  return '操作失败，请稍后再试';
}

/// 寄重设密码信失败时给使用者看的讯息；回传 null 代表「当作寄出了」。
///
/// user-not-found 刻意当成功：画面一律说「如果这个 Email 有帐号就会收到
/// 信」，不让登入页变成查谁有帐号的工具。开了 email enumeration
/// protection 的专案本来就不会回这个错，这里是给没开的专案用的。
String? mapPasswordResetErrorToUserMessage(Object? error) {
  if (error is FirebaseAuthException) {
    return switch (error.code) {
      'user-not-found' => null,
      'invalid-email' || 'missing-email' => '电子邮件格式错误',
      'user-disabled' => '帐号已被停用，请联络管理员',
      'network-request-failed' => '网路连线失败，请检查网路',
      'too-many-requests' => '寄送次数过多，请稍后再试',
      _ => '无法寄出重设信，请稍后再试',
    };
  }
  if (error is TimeoutException) return '操作逾时，请稍后再试';
  return '无法寄出重设信，请稍后再试';
}
