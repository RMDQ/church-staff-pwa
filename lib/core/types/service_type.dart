import '../config/church_config.dart';

/// 稳定的聚会 ID。显示名称及排程来自部署设定，不用改 ID 就能改名。
/// 未知 ID 原样保留，不能把旧资料或未设定的聚会误认为另一种聚会。
class ServiceType {
  const ServiceType(this.name);

  // 既有文件的 ID 保持不变；新部署可以使用完全不同的聚会清单。
  static const sundayService = ServiceType('sundayService');
  static const youth = ServiceType('youth');
  static const children = ServiceType('children');

  final String name;

  static List<ServiceType> get values => List.unmodifiable(
    ChurchConfig.current.services.map((service) => ServiceType(service.id)),
  );

  /// 还在举行的聚会。停用的聚会保留 ID 与旧资料，只是不再出现在分页上、
  /// 也不再产生新的服事表。
  static List<ServiceType> get active => List.unmodifiable(
    ChurchConfig.current.services
        .where((service) => service.enabled)
        .map((service) => ServiceType(service.id)),
  );

  static ServiceType fromName(String name) => ServiceType(name);

  ServiceDefinition? get _definition => ChurchConfig.current.service(name);
  String get label => _definition?.label ?? name;
  String get serviceName => _definition?.name ?? name;
  bool get enabled => _definition?.enabled ?? false;
  int get weekday =>
      _definition?.weekday ?? (throw StateError('聚会 $name 不在部署设定内，不能产生排程'));
  int get index =>
      ChurchConfig.current.services.indexWhere((s) => s.id == name);

  @override
  bool operator ==(Object other) => other is ServiceType && other.name == name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => 'ServiceType.$name';
}
