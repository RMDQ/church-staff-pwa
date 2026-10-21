import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../../../../core/config/church_config.dart';
import '../../../../core/time/church_time.dart';
import '../../../../core/services/app_update_service.dart';
import '../../../../core/services/app_version_service.dart';
import '../../../../core/services/external_link_service.dart';
import '../../../../core/services/push_notification_service.dart';
import '../../../../core/services/release_check_service.dart';
import '../../../../core/utils/error_messages.dart';
import '../../domain/entities/user.dart';
import '../providers/session_provider.dart';
import 'user_management_screen.dart' deferred as user_management_screen;
import 'group_settings_screen.dart' deferred as group_settings_screen;
import '../../../services/presentation/screens/service_settings_screen.dart'
    deferred as service_settings_screen;

/// 服事提醒的寄送端還不存在（見 build 裡的開關）。
const _rosterReminderSenderExists = false;

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    this.updateService = const AppUpdateService(),
    this.versionService = const AppVersionService(),
    this.releaseService = const ReleaseCheckService(),
  });

  /// 這幾個注入點只是為了測試 —— 正式環境永遠是預設那個。
  final AppUpdateService updateService;
  final AppVersionService versionService;
  final ReleaseCheckService releaseService;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  String? _statusUserId;
  bool _isPushEnabled = false;
  bool _isPushLoading = false;
  bool _isCheckingUpdate = false;
  late final Future<AppVersionInfo?> _versionInfoFuture = widget.versionService
      .fetchVersionInfo();

  /// 精靈裝的網站、而且 GitHub 上有比較新的 release 時才有值。
  /// 只給管理員看：一般同工看到「有新版本」也做不了什麼。
  late final Future<(ReleaseInfo, String)?> _newRelease = () async {
    final info = await _versionInfoFuture;
    if (info == null || !info.isInstallerSite) return null;
    final latest = await widget.releaseService.fetchLatest();
    if (latest == null || !isNewerRelease(latest.version, info.release)) {
      return null;
    }
    return (latest, info.release!);
  }();

  /// 「檢查更新」。
  ///
  /// 找到新版的話 `web/app_update.js` 會把頁面重載，所以那條路徑上這裡什麼都
  /// 不用收尾 —— 連 setState 都不必，widget 馬上就不在了。
  Future<void> _checkForUpdate() async {
    setState(() => _isCheckingUpdate = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await widget.updateService.checkForUpdate();
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            result == AppUpdateResult.updating ? '找到新版本，正在更新…' : '已经是最新版本',
          ),
        ),
      );
    } catch (error, st) {
      log('檢查更新失敗', error: error, stackTrace: st);
      if (!mounted) return;
      // 這個按鈕存在的理由就是使用者已經不相信畫面上的版本了，失敗要說出來，
      // 不能讓它看起來像「檢查過了，沒事」。
      messenger.showSnackBar(
        SnackBar(content: Text('检查更新失败：${mapErrorToUserMessage(error)}')),
      );
    } finally {
      if (mounted) setState(() => _isCheckingUpdate = false);
    }
  }

  Future<void> _loadAndPush(
    BuildContext context,
    Future<void> Function() loadLibrary,
    Widget Function() builder,
  ) async {
    var dialogShown = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      await loadLibrary();
      if (!context.mounted) return;
      if (dialogShown) {
        Navigator.of(context, rootNavigator: true).pop();
        dialogShown = false;
      }
      Navigator.push(context, MaterialPageRoute(builder: (_) => builder()));
    } catch (error, st) {
      log('載入畫面失敗', error: error, stackTrace: st);
      if (context.mounted) {
        if (dialogShown) {
          Navigator.of(context, rootNavigator: true).pop();
          dialogShown = false;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载失败：${mapErrorToUserMessage(error)}')),
        );
      }
    } finally {
      if (dialogShown && context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final userId = context.read<SessionProvider>().currentUser?.id;
    if (_statusUserId == userId) return;
    _statusUserId = userId;
    _refreshPushStatus();
  }

  Future<void> _refreshPushStatus() async {
    if (!_rosterReminderSenderExists ||
        !ChurchConfig.current.features.pushNotifications) {
      return;
    }
    final userId = _statusUserId;
    if (userId == null) return;
    setState(() => _isPushLoading = true);
    try {
      final pushService = context.read<PushNotificationService>();
      final enabled = await pushService.isNotificationEnabledForUser(userId);
      if (!mounted || _statusUserId != userId) return;
      setState(() => _isPushEnabled = enabled);
    } catch (_) {
      if (!mounted || _statusUserId != userId) return;
      setState(() => _isPushEnabled = false);
    } finally {
      if (mounted && _statusUserId == userId) {
        setState(() => _isPushLoading = false);
      }
    }
  }

  Future<void> _togglePush(bool value) async {
    if (!ChurchConfig.current.features.pushNotifications) return;
    final userId = context.read<SessionProvider>().currentUser?.id;
    if (userId == null) return;
    setState(() => _isPushLoading = true);
    try {
      final pushService = context.read<PushNotificationService>();
      final result = await pushService.setNotificationEnabled(
        userId: userId,
        enabled: value,
      );
      final enabled = result.enabled;
      if (!mounted) return;
      setState(() => _isPushEnabled = enabled);
      if (value && !enabled) {
        final reasonMessage = switch (result.failureReason) {
          PushToggleFailureReason.missingVapidKey => '系统设置缺少推送密钥，请联系管理员。',
          PushToggleFailureReason.permissionDenied =>
            '通知权限未开启，请在系统设置中允许此 App 通知。',
          PushToggleFailureReason.tokenUnavailable =>
            '当前设备无法获取推送标识码，请重新打开 App 后再试。',
          PushToggleFailureReason.saveTokenFailed => '已获取标识码，但保存失败，请稍后再试。',
          PushToggleFailureReason.savePreferenceFailed => '通知偏好保存失败，请稍后再试。',
          PushToggleFailureReason.notInitialized => '推送服务尚未初始化完成，请刷新后再试。',
          PushToggleFailureReason.disabled => '推送通知未启用。',
          PushToggleFailureReason.notWeb => '当前环境不支持网页推送。',
          null => '通知未启用，请确认浏览器通知权限设置。',
        };
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(reasonMessage)));
      }
    } catch (error, st) {
      log('更新通知設定失敗', error: error, stackTrace: st);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('更新通知设置失败：${mapErrorToUserMessage(error)}')),
      );
    } finally {
      if (mounted) {
        setState(() => _isPushLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionProvider>();
    final user = session.currentUser;

    if (user == null) return const SizedBox.shrink();

    return Scaffold(
      appBar: AppBar(title: const Text('个人中心')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // User Info Header
          Center(
            child: Column(
              children: [
                CircleAvatar(
                  radius: 40,
                  child: Text(
                    _avatarLetter(user.name),
                    style: const TextStyle(fontSize: 32),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  user.name,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                Text(
                  '@${user.username}',
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: Colors.grey),
                ),
                const SizedBox(height: 8),
                // 角色是身分，group 是編輯權限 —— 兩種不同的東西，所以用不同
                // 的底色，而不是排成一串看起來同質的標籤。
                //
                // 管理員不列 group：他隱含全部，逐項列出反而像是「被指定了這
                // 幾項」，看起來比實際權限還小。Wrap 是為了窄螢幕會換行而不是
                // 擠成一行溢出。
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    Chip(
                      label: Text(user.role.label),
                      backgroundColor: Theme.of(
                        context,
                      ).colorScheme.primaryContainer,
                    ),
                    if (!user.isAdmin)
                      for (final group in UserGroup.values)
                        if (user.groups.contains(group))
                          Chip(
                            label: Text(group.label),
                            backgroundColor: Theme.of(
                              context,
                            ).colorScheme.secondaryContainer,
                          ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),

          // Admin Actions
          if (session.isAdmin) ...[
            const Divider(),
            FutureBuilder<(ReleaseInfo, String)?>(
              future: _newRelease,
              builder: (context, snapshot) {
                final found = snapshot.data;
                if (found == null) return const SizedBox.shrink();
                return _NewReleaseTile(release: found.$1, current: found.$2);
              },
            ),
            ListTile(
              leading: const Icon(Icons.manage_accounts),
              title: const Text('账号管理'),
              subtitle: const Text('新增、删除或修改同工权限'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _loadAndPush(
                context,
                user_management_screen.loadLibrary,
                () => user_management_screen.UserManagementScreen(),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.event_repeat),
              title: const Text('聚会设置'),
              subtitle: const Text('新增或修改每周的聚会'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _loadAndPush(
                context,
                service_settings_screen.loadLibrary,
                () => service_settings_screen.ServiceSettingsScreen(),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.groups),
              title: const Text('小组管理'),
              subtitle: const Text('设置各牧区小组列表'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _loadAndPush(
                context,
                group_settings_screen.loadLibrary,
                () => group_settings_screen.GroupSettingsScreen(),
              ),
            ),
          ],

          const Divider(),

          // 先藏起來：App 只會記下「要提醒」，還沒有任何東西真的在週一寄出。
          // 留著開關會讓同工以為打開就會收到。有寄送端之後把這個常數改回 true。
          if (_rosterReminderSenderExists &&
              ChurchConfig.current.features.pushNotifications)
            SwitchListTile(
              secondary: const Icon(Icons.notifications_active),
              title: const Text('服事提醒'),
              subtitle: const Text('每周一晚间发送提醒'),
              value: _isPushEnabled,
              onChanged: _isPushLoading ? null : _togglePush,
            ),

          // Logout Button
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title: const Text('退出登录', style: TextStyle(color: Colors.red)),
            onTap: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('退出登录确认'),
                  content: const Text('确定要退出登录吗？'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text(
                        '退出登录',
                        style: TextStyle(color: Colors.red),
                      ),
                    ),
                  ],
                ),
              );

              if (confirm != true) return;
              await session.logout();
              // 登出失敗時 session 會被保留（避免假登出），所以錯誤要在這裡
              // 講清楚，否則使用者以為登出成功、畫面卻沒有變化。
              final logoutError = session.error;
              if (logoutError == null) return;
              session.clearError();
              if (!context.mounted) return;
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(logoutError)));
            },
          ),
          Padding(
            padding: const EdgeInsets.only(top: 20, bottom: 8),
            child: FutureBuilder<AppVersionInfo?>(
              future: _versionInfoFuture,
              builder: (context, snapshot) {
                final info = snapshot.data;
                // 頁尾的版本資訊。刻意都用同一個灰色小字：這裡是註腳，不是
                // 功能入口 —— 平常載入與切回前景都會自己檢查更新，按鈕只是給
                // 「我看起來還是舊版」的人一個不必被叫去滑掉 App 的出口。
                // 一顆正常的 TextButton（主色、按鈕級字級）會比它上面那行還
                // 搶眼，看起來像有什麼事該做。
                final captionStyle = Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: Colors.grey.shade600);

                // 兩行，各自置中。擠在同一行時「檢查更新」會把整組推得偏
                // 左，看起來像沒對齊。
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 這是「這台裝置正在跑的版本」，不是伺服器的 ——
                    // version.json 跟著 bundle 一起進快取（見 AppVersionService）。
                    if (info != null)
                      Text(
                        '更新于 ${_buildVersionDateText(info)}',
                        textAlign: TextAlign.center,
                        style: captionStyle,
                      ),
                    if (widget.updateService.isSupported)
                      InkWell(
                        onTap: _isCheckingUpdate ? null : _checkForUpdate,
                        // 字級小，靠 padding 把可點範圍撐到手指按得到。
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: 8,
                            horizontal: 12,
                          ),
                          child: Text(
                            _isCheckingUpdate ? '检查中…' : '检查更新',
                            textAlign: TextAlign.center,
                            // 顏色跟上面那行一樣，只用底線表示按得下去。
                            style: captionStyle?.copyWith(
                              decoration: _isCheckingUpdate
                                  ? null
                                  : TextDecoration.underline,
                              decorationColor: Colors.grey.shade600,
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 空字串直接取 [0] 會 RangeError（Firestore 上的 name 不保證非空）。
  String _avatarLetter(String name) {
    final trimmed = name.trim();
    return trimmed.isEmpty ? '?' : trimmed[0];
  }

  String _buildVersionDateText(AppVersionInfo? info) {
    return DateFormat(
      'yyyy/MM/dd HH:mm',
    ).format(ChurchTime.inZone(info!.generatedAt));
  }
}

/// 「有新版本」。點下去開更新教學：更新要在 Cloud Shell 跑精靈，App 自己做不到。
class _NewReleaseTile extends StatelessWidget {
  const _NewReleaseTile({required this.release, required this.current});

  final ReleaseInfo release;
  final String current;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final guideUrl = release.guideUrl;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.system_update,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '有新版本可以更新',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '当前 $current，最新 ${release.version}。只有管理员看得到这则提醒。',
              style: TextStyle(color: theme.colorScheme.onPrimaryContainer),
            ),
            if (release.notes.isNotEmpty) ...[
              const SizedBox(height: 6),
              for (final note in release.notes)
                Text(
                  '・$note',
                  style: TextStyle(color: theme.colorScheme.onPrimaryContainer),
                ),
            ],
            if (guideUrl != null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => openExternalLink(guideUrl),
                  child: const Text('更新指南'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
