import 'dart:convert';
import 'dart:developer';

import 'package:shared_preferences/shared_preferences.dart';

import 'church_config.dart';

/// 聚会清单从哪里来。
///
/// 部署设定（build 时写死的 CHURCH_CONFIG_JSON）是预设值；管理员在「聚会设定」
/// 改过之后，清单存在 Firestore 的 settings/services，以那份为准。这样新增
/// 祷告会、改星期几都不必重新部署。
///
/// App 各处都透过 [ChurchConfig.current] 读聚会（见 ServiceType），所以这里只
/// 负责把 current 换成「部署设定 + 另一份聚会清单」。为了不在启动时等网路，
/// 最后一次读到的清单会存在本机，启动时先套用（[applyCached]）。
class ServiceCatalog {
  ServiceCatalog._();

  static const cacheKey = 'service_catalog_v1';

  static ChurchConfig? _deployed;

  /// build 时的部署设定。第一次存取时记下，之后 current 被换掉也不受影响。
  static ChurchConfig get deployed => _deployed ??= ChurchConfig.current;

  /// 测试用：换一份部署设定，并清掉已套用的覆写。
  static void resetForTesting(ChurchConfig config) {
    _deployed = config;
    ChurchConfig.current = config;
  }

  /// settings/services 里的清单；格式不对就当作没有，沿用部署设定。
  static List<ServiceDefinition>? parseDocument(Map<String, dynamic>? data) {
    if (data == null) return null;
    try {
      return ChurchConfig.parseServices(data['services']);
    } catch (e) {
      log('settings/services 格式不正确，沿用部署设定', error: e);
      return null;
    }
  }

  /// 套用 [services]（null = 回到部署设定）。回传清单有没有真的改变。
  static bool apply(List<ServiceDefinition>? services) {
    final next = services ?? deployed.services;
    final current = ChurchConfig.current.services;
    if (current.length == next.length &&
        Iterable.generate(current.length).every((i) => current[i] == next[i])) {
      return false;
    }
    ChurchConfig.current = deployed.withServices(next);
    return true;
  }

  /// 启动时先用上一次读到的清单，不等网路。
  static Future<void> applyCached() async {
    deployed;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(cacheKey);
      if (raw == null) return;
      apply(ChurchConfig.parseServices(jsonDecode(raw)));
    } catch (e) {
      log('读取本机聚会清单失败，沿用部署设定', error: e);
    }
  }

  static Future<void> remember(List<ServiceDefinition>? services) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (services == null) {
        await prefs.remove(cacheKey);
      } else {
        await prefs.setString(
          cacheKey,
          jsonEncode([for (final service in services) service.toJson()]),
        );
      }
    } catch (e) {
      log('储存本机聚会清单失败', error: e);
    }
  }

  /// 要写进 settings/services 的 ids：用过的聚会 ID 永远留著（Firestore rules
  /// 用它判断哪些聚会存在，只能增加不能减少），加上部署设定的和这次的。
  static List<String> knownIds(
    Iterable<String> previous,
    List<ServiceDefinition> services,
  ) => {
    ...previous,
    ...deployed.services.map((service) => service.id),
    ...services.map((service) => service.id),
  }.toList();
}
