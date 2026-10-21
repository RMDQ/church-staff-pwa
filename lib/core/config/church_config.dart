import 'dart:convert';

import '../time/time_zone_database.dart';
import 'default_church_config.dart';

/// 部署者提供的公开设定。凭证不属于这份设定，也不应进入前端 bundle。
class ChurchConfig {
  ChurchConfig._({
    required this.appName,
    required this.shortName,
    required this.timeZone,
    required this.services,
    required this.features,
    required this.devotional,
    required this.checkin,
    required this.icons,
  });

  static ChurchConfig current = ChurchConfig.fromJson(
    jsonDecode(
          const String.fromEnvironment(
            'CHURCH_CONFIG_JSON',
            defaultValue: defaultChurchConfigJson,
          ),
        )
        as Map<String, dynamic>,
  );

  final String appName;
  final String shortName;
  final String timeZone;
  final List<ServiceDefinition> services;
  final ChurchFeatures features;
  final DevotionalConfig devotional;

  /// 打卡规则：时间窗口、准时线、允许距离与教堂位置。
  final CheckinConfig checkin;
  final Map<String, String> icons;

  ServiceDefinition? service(String id) {
    for (final service in services) {
      if (service.id == id) return service;
    }
    return null;
  }

  factory ChurchConfig.fromJson(Map<String, dynamic> json) {
    _checkKeys(json, const [
      'schemaVersion',
      'appName',
      'shortName',
      'timeZone',
      'services',
      'features',
      'devotional',
      'icons',
      'checkin',
    ]);
    if (json['schemaVersion'] != 1) {
      throw const FormatException('不支援的教会设定版本');
    }
    final timeZone = _text(json, 'timeZone');
    try {
      timeZoneLocation(timeZone);
    } catch (_) {
      throw FormatException('无效的 IANA 时区：$timeZone');
    }
    final services = parseServices(json['services']);
    final rawIcons = _object(json['icons'], 'icons');
    _checkKeys(rawIcons, const [
      'favicon',
      'icon192',
      'icon512',
      'maskable192',
      'maskable512',
    ]);
    final icons = rawIcons.map((key, value) {
      if (value is! String ||
          value.length > 240 ||
          !RegExp(
            r'^[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*\.png$',
          ).hasMatch(value)) {
        throw FormatException('图示必须是安全的相对 PNG 路径：$key');
      }
      return MapEntry(key, value);
    });
    for (final key in [
      'favicon',
      'icon192',
      'icon512',
      'maskable192',
      'maskable512',
    ]) {
      if (!icons.containsKey(key)) throw FormatException('缺少图示：$key');
    }
    return ChurchConfig._(
      appName: _text(json, 'appName'),
      shortName: _text(json, 'shortName', max: 40),
      timeZone: timeZone,
      services: List.unmodifiable(services),
      features: ChurchFeatures.fromJson(_object(json['features'], 'features')),
      devotional: DevotionalConfig.fromJson(
        _object(json['devotional'], 'devotional'),
      ),
      checkin: CheckinConfig.fromJson(_object(json['checkin'], 'checkin')),
      icons: Map.unmodifiable(icons),
    );
  }

  /// 同一份设定，换成另一份聚会清单 —— 管理员在 App 里改过的那份
  /// （settings/services，见 ServiceCatalog）。其他栏位仍来自部署设定。
  ChurchConfig withServices(List<ServiceDefinition> services) => ChurchConfig._(
    appName: appName,
    shortName: shortName,
    timeZone: timeZone,
    services: List.unmodifiable(services),
    features: features,
    devotional: devotional,
    checkin: checkin,
    icons: icons,
  );

  /// 部署设定和 settings/services 共用同一套检查。
  static List<ServiceDefinition> parseServices(Object? rawServices) {
    if (rawServices is! List ||
        rawServices.isEmpty ||
        rawServices.length > 20) {
      throw const FormatException('services 必须包含 1 至 20 种聚会');
    }
    final services = rawServices
        .map(
          (raw) => ServiceDefinition.fromJson(
            _object(
              raw is Map ? Map<String, dynamic>.from(raw) : raw,
              'service',
            ),
          ),
        )
        .toList();
    if (services.map((s) => s.id).toSet().length != services.length) {
      throw const FormatException('聚会 ID 不可重复');
    }
    return services;
  }

  Map<String, dynamic> toJson() => {
    'schemaVersion': 1,
    'appName': appName,
    'shortName': shortName,
    'timeZone': timeZone,
    'services': services.map((s) => s.toJson()).toList(),
    'features': features.toJson(),
    'devotional': devotional.toJson(),
    'checkin': checkin.toJson(),
    'icons': icons,
  };
}

class ServiceDefinition {
  const ServiceDefinition({
    required this.id,
    required this.label,
    required this.name,
    required this.weekday,
    required this.enabled,
  });

  final String id;
  final String label;
  final String name;
  final int weekday;
  final bool enabled;

  factory ServiceDefinition.fromJson(Map<String, dynamic> json) {
    _checkKeys(json, const ['id', 'label', 'name', 'weekday', 'enabled']);
    final id = _text(json, 'id', max: 64);
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_-]{0,63}$').hasMatch(id) ||
        const ['constructor', 'prototype'].contains(id)) {
      throw FormatException('无效的聚会 ID：$id');
    }
    final weekday = json['weekday'];
    if (weekday is! int || weekday < 1 || weekday > 7) {
      throw FormatException('聚会 $id 的 weekday 必须是 1 至 7');
    }
    return ServiceDefinition(
      id: id,
      label: _text(json, 'label', max: 40),
      name: _text(json, 'name'),
      weekday: weekday,
      enabled: _flag(json, 'enabled'),
    );
  }

  ServiceDefinition copyWith({
    String? label,
    String? name,
    int? weekday,
    bool? enabled,
  }) => ServiceDefinition(
    id: id,
    label: label ?? this.label,
    name: name ?? this.name,
    weekday: weekday ?? this.weekday,
    enabled: enabled ?? this.enabled,
  );

  @override
  bool operator ==(Object other) =>
      other is ServiceDefinition &&
      other.id == id &&
      other.label == label &&
      other.name == name &&
      other.weekday == weekday &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(id, label, name, weekday, enabled);

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'name': name,
    'weekday': weekday,
    'enabled': enabled,
  };
}

/// 打卡的设定。服务器据此判断时间、距离与准时，App 只用来显示。
class CheckinConfig {
  const CheckinConfig({
    required this.serviceId,
    required this.start,
    required this.end,
    required this.onTimeBefore,
    required this.allowedMeters,
    required this.latitude,
    required this.longitude,
  });

  final String serviceId;

  /// HH:mm，教会时区。
  final String start;
  final String end;
  final String onTimeBefore;
  final int allowedMeters;
  final double latitude;
  final double longitude;

  factory CheckinConfig.fromJson(Map<String, dynamic> json) {
    _checkKeys(json, const [
      'serviceId',
      'start',
      'end',
      'onTimeBefore',
      'allowedMeters',
      'latitude',
      'longitude',
    ]);
    final allowed = json['allowedMeters'];
    final latitude = json['latitude'];
    final longitude = json['longitude'];
    if (allowed is! int || allowed < 10 || allowed > 500) {
      throw const FormatException('checkin.allowedMeters 必须是 10 至 500 的整数');
    }
    if (latitude is! num || latitude < -90 || latitude > 90) {
      throw const FormatException('checkin.latitude 必须在 -90 至 90 之间');
    }
    if (longitude is! num || longitude < -180 || longitude > 180) {
      throw const FormatException('checkin.longitude 必须在 -180 至 180 之间');
    }
    return CheckinConfig(
      serviceId: _text(json, 'serviceId'),
      start: _clock(json, 'start'),
      end: _clock(json, 'end'),
      onTimeBefore: _clock(json, 'onTimeBefore'),
      allowedMeters: allowed,
      latitude: latitude.toDouble(),
      longitude: longitude.toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
    'serviceId': serviceId,
    'start': start,
    'end': end,
    'onTimeBefore': onTimeBefore,
    'allowedMeters': allowedMeters,
    'latitude': latitude,
    'longitude': longitude,
  };
}

String _clock(Map<String, dynamic> json, String field) {
  final value = _text(json, field, max: 5);
  if (!RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').hasMatch(value)) {
    throw FormatException('checkin.$field 必须是 HH:mm 格式');
  }
  return value;
}

class ChurchFeatures {
  const ChurchFeatures({
    this.calendar = false,
    this.photoImport = false,
    this.pushNotifications = false,
    this.lineNotifications = false,
  });

  final bool calendar;
  final bool photoImport;
  final bool pushNotifications;
  final bool lineNotifications;

  factory ChurchFeatures.fromJson(Map<String, dynamic> json) {
    _checkKeys(json, const [
      'calendar',
      'photoImport',
      'pushNotifications',
      'lineNotifications',
    ]);
    final result = ChurchFeatures(
      calendar: _flag(json, 'calendar'),
      photoImport: _flag(json, 'photoImport'),
      pushNotifications: _flag(json, 'pushNotifications'),
      lineNotifications: _flag(json, 'lineNotifications'),
    );
    if (result.lineNotifications && !result.calendar) {
      throw const FormatException('LINE 行事历通知需要启用行事历');
    }
    return result;
  }

  Map<String, dynamic> toJson() => {
    'calendar': calendar,
    'photoImport': photoImport,
    'pushNotifications': pushNotifications,
    'lineNotifications': lineNotifications,
  };
}

class DevotionalConfig {
  const DevotionalConfig({
    required this.enabled,
    required this.dataUrl,
    required this.linkUrl,
    required this.sourceName,
    this.fetchUrl = '',
    this.fetchFormat = 'json',
  });

  final bool enabled;
  final String dataUrl;
  final String linkUrl;
  final String sourceName;
  final String fetchUrl;
  final String fetchFormat;

  factory DevotionalConfig.fromJson(Map<String, dynamic> json) {
    _checkKeys(json, const [
      'enabled',
      'dataUrl',
      'linkUrl',
      'sourceName',
      'fetchUrl',
      'fetchFormat',
    ]);
    final enabled = _flag(json, 'enabled');
    final format = json['fetchFormat'] ?? 'json';
    if (format != 'json' && format != 'dailyBibleHtml') {
      throw const FormatException('不支援的每日灵粮抓取格式');
    }
    return DevotionalConfig(
      enabled: enabled,
      dataUrl: _httpsUrl(json, 'dataUrl', isRequired: enabled),
      linkUrl: _httpsUrl(json, 'linkUrl', isRequired: enabled),
      sourceName: _text(json, 'sourceName'),
      fetchUrl: _httpsUrl(
        {'fetchUrl': json['fetchUrl'] ?? ''},
        'fetchUrl',
        isRequired: false,
      ),
      fetchFormat: format as String,
    );
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'dataUrl': dataUrl,
    'linkUrl': linkUrl,
    'sourceName': sourceName,
    'fetchUrl': fetchUrl,
    'fetchFormat': fetchFormat,
  };
}

Map<String, dynamic> _object(Object? value, String field) {
  if (value is! Map<String, dynamic>) {
    throw FormatException('$field 必须是物件');
  }
  return value;
}

void _checkKeys(Map<String, dynamic> json, List<String> allowed) {
  if (json.keys.any((key) => !allowed.contains(key))) {
    throw const FormatException('不支援的设定栏位；凭证不能放在公开设定档');
  }
}

String _text(Map<String, dynamic> json, String field, {int max = 100}) {
  final value = json[field];
  if (value is! String ||
      value.trim().isEmpty ||
      value.length > max ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
    throw FormatException('$field 必须是 1 至 $max 字的纯文字');
  }
  return value;
}

bool _flag(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value is! bool) throw FormatException('$field 必须是布林值');
  return value;
}

String _httpsUrl(
  Map<String, dynamic> json,
  String field, {
  required bool isRequired,
}) {
  final value = json[field];
  if (value is! String ||
      value.length > 2048 ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
    throw FormatException('$field 必须是安全的 URL 字串');
  }
  if (value.isEmpty && !isRequired) return '';
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    throw FormatException('$field 必须是 HTTPS 网址');
  }
  return value;
}
