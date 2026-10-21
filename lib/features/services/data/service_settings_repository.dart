import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/config/church_config.dart';
import '../../../core/config/service_catalog.dart';

/// settings/services：管理员在 App 里设定的聚会清单。
///
/// ```
/// { services: [{id, label, name, weekday, enabled}, …],
///   ids: [曾经用过的每一个聚会 ID] }
/// ```
///
/// ids 另外存一份，是因为 Firestore rules 没办法在 map 的清单里找 id；
/// rules 用它判断一个服事表的 type 存不存在，所以只能增加，不能减少。
class ServiceSettings {
  const ServiceSettings({required this.services, required this.ids});

  final List<ServiceDefinition>? services;
  final List<String> ids;
}

abstract class ServiceSettingsRepository {
  /// 文件不存在时回传 null（沿用部署设定）。
  Future<ServiceSettings?> load();

  Future<void> save(List<ServiceDefinition> services);
}

class FirestoreServiceSettingsRepository implements ServiceSettingsRepository {
  FirestoreServiceSettingsRepository({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  DocumentReference<Map<String, dynamic>> get _doc =>
      _firestore.collection('settings').doc('services');

  @override
  Future<ServiceSettings?> load() async {
    // 要伺服器上的那一版：Firestore 的离线快取可能还是存档前的，套回去的话
    // 刚停用的聚会又会出现。不用 get(Source.server)：网页刚启动、连线还没
    // 建好时它会直接回报离线，每次启动都撞在同一个时间点，就永远拿不到新版。
    // 改成听这份文件，等第一笔确定来自伺服器的快照；30 秒都等不到（真的离线）
    // 就丢例外，呼叫端沿用本机记下的清单。
    final snapshot = await _doc
        .snapshots(includeMetadataChanges: true)
        .firstWhere((snapshot) => !snapshot.metadata.isFromCache)
        .timeout(const Duration(seconds: 30));
    final data = snapshot.data();
    if (!snapshot.exists || data == null) return null;
    final ids = data['ids'];
    return ServiceSettings(
      services: ServiceCatalog.parseDocument(data),
      ids: ids is List ? ids.whereType<String>().toList() : const [],
    );
  }

  @override
  Future<void> save(List<ServiceDefinition> services) async {
    // 在 transaction 里读旧的 ids 再合并：两位管理员同时存，也不会有人的
    // 新聚会 ID 被对方覆盖掉（rules 也会挡减少 ids 的写入）。
    await _firestore.runTransaction((transaction) async {
      final current = await transaction.get(_doc);
      final previous = current.data()?['ids'];
      transaction.set(_doc, {
        'services': [for (final service in services) service.toJson()],
        'ids': ServiceCatalog.knownIds(
          previous is List ? previous.whereType<String>() : const [],
          services,
        ),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
  }
}
