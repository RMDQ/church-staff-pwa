import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:flutter/foundation.dart';

import '../../../../core/config/church_config.dart';
import '../../../../core/config/service_catalog.dart';
import '../../../../core/services/app_reload_service.dart';
import '../../data/service_settings_repository.dart';

/// 登入后读一次 settings/services；跟目前用的清单不同就套用并重新载入。
class ServiceCatalogProvider extends ChangeNotifier {
  ServiceCatalogProvider(
    this._repository, {
    Future<bool> Function(String reason) reload = reloadAppOnce,
  }) : _reload = reload;

  final ServiceSettingsRepository _repository;
  final Future<bool> Function(String reason) _reload;
  String? _userId;

  /// 设定页要知道目前的清单是不是已经存在 Firestore。
  ServiceSettings? settings;

  void onSessionChanged(String? userId) {
    if (userId == _userId) return;
    _userId = userId;
    if (userId != null) unawaited(refresh());
  }

  Future<void> refresh() async {
    try {
      settings = await _repository.load();
      final services = settings?.services;
      await ServiceCatalog.remember(services);
      if (ServiceCatalog.apply(services)) {
        notifyListeners();
        await _reload(_fingerprint(ChurchConfig.current.services));
      }
    } catch (e, st) {
      // 读不到就沿用现在的清单（部署设定或本机快取），不影响其他功能。
      log('读取聚会设定失败', error: e, stackTrace: st);
    }
  }

  /// 管理员存好新的清单：套用、记下，再重新载入让各页面用新清单。
  Future<void> save(List<ServiceDefinition> services) async {
    await _repository.save(services);
    await ServiceCatalog.remember(services);
    ServiceCatalog.apply(services);
    settings = await _repository.load();
    notifyListeners();
    await _reload(_fingerprint(services));
  }

  static String _fingerprint(List<ServiceDefinition> services) =>
      jsonEncode([for (final service in services) service.toJson()]);
}
