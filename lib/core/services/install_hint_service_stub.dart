import 'install_hint_service.dart';

// 非 web（测试环境、未来若有原生版）：本来就是 App，没有主画面要加。

InstallHint readInstallHint() => const InstallHint(
  platform: InstallPlatform.other,
  isStandalone: true,
  canPrompt: false,
);

Future<String> promptInstall() async => 'unavailable';
