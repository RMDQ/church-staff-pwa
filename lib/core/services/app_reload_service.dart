import 'app_reload_service_stub.dart'
    if (dart.library.js_interop) 'app_reload_service_web.dart'
    as impl;

/// 聚会清单变了就整页重新载入：分页、各 provider 里依聚会分组的快取都要
/// 重建，重新载入最单纯也最不会漏。同一个 [reason] 在一个分页里最多重载
/// 两次，万一本机快取写不进去（无痕模式），也不会一直重载。
Future<bool> reloadAppOnce(String reason) => impl.reloadAppOnce(reason);
