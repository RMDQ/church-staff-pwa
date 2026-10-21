import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:church_staff_pwa/core/types/service_type.dart';
import '../../domain/repositories/group_settings_repository.dart';
import '../../../../core/utils/error_messages.dart';

class GroupSettingsProvider extends ChangeNotifier {
  final GroupSettingsRepository _repository;

  Map<ServiceType, List<String>> _templates = {
    for (final type in ServiceType.values) type: [],
  };
  bool _isLoading = false;
  String? _error;

  // 追踪上一次 session userId，用来判断帐号是否真的换了。
  String? _lastSessionUserId;

  // Fetch generation counter：每次 session 变动时递增，让过期 fetch 的结果被丢弃。
  int _fetchToken = 0;

  GroupSettingsProvider(this._repository);

  /// 故意回传 raw reference（不做 defensive copy），让消费端可以用 `identical()`
  /// 廉价侦测「templates 是否真的换过一份」— 例如 user_management_screen 用这个
  /// 判断要不要重新排序。改成 `Map.from(_templates)` 会让 identical 永远 false，
  /// 默默退化使用端的优化。
  Map<ServiceType, List<String>> get templates => _templates;
  bool get isLoading => _isLoading;
  String? get error => _error;

  Future<void> fetchTemplates() async {
    final token = ++_fetchToken;
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final result = await _repository.getSmallGroupTemplates();
      if (token != _fetchToken) return; // stale fetch，丢弃结果
      _templates = result.isEmpty
          ? {for (final type in ServiceType.values) type: []}
          : result;
    } catch (e, st) {
      if (token != _fetchToken) return; // stale fetch，丢弃错误
      log('载入小组设定失败', error: e, stackTrace: st);
      _error = '载入失败:${mapErrorToUserMessage(e)}';
    } finally {
      if (token == _fetchToken) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  /// 由 ChangeNotifierProxyProvider 在 SessionProvider.currentUser 变动时呼叫。
  /// 当 userId 真的改变，清掉 cache 并重抓资料。
  void onSessionChanged(String? userId) {
    if (userId == _lastSessionUserId) return;
    _lastSessionUserId = userId;

    _fetchToken++; // 让进行中的 fetch 过期
    _templates = {for (final type in ServiceType.values) type: []};
    _error = null;

    if (userId != null) {
      fetchTemplates();
    } else {
      notifyListeners();
    }
  }

  Future<void> updateTemplates(
    Map<ServiceType, List<String>> newTemplates,
  ) async {
    try {
      await _repository.updateSmallGroupTemplates(newTemplates);
      _templates = Map.from(newTemplates);
      notifyListeners();
    } catch (e, st) {
      log('更新小组设定失败', error: e, stackTrace: st);
      _error = '更新失败:${mapErrorToUserMessage(e)}';
      notifyListeners();
    }
  }
}
