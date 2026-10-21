// 非 web（App 测试环境、未来若有原生版）：没有 service worker，也就没有这回事。

bool isUpdateCheckSupported() => false;

Future<String> checkForUpdate() async => 'unsupported';
