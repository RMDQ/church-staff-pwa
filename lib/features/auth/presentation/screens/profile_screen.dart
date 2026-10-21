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

/// 服事提醒的寄送端还不存在（见 build 里的开关）。
const _rosterReminderSenderExists = false;

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    this.updateService = const AppUpdateService(),
    this.versionService = const AppVersionService(),
    this.releaseService = const ReleaseCheckService(),
  });

  /// 这几个注入点只是为了测试 —— 正式环境永远是预设那个。
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

  /// 精灵装的网站、而且 GitHub 上有比较新的 release 时才有值。
  /// 只给管理员看：一般同工看到「有新版本」也做不了什么。
  late final Future<(ReleaseInfo, String)?> _newRelease = () async {
    final info = await _versionInfoFuture;
    if (info == null || !info.isInstallerSite) return null;
    final latest = await widget.releaseService.fetchLatest();
    if (latest == null || !isNewerRelease(latest.version, info.release)) {
      return null;
    }
    return (latest, info.release!);
  }();

  /// 「检查更新」。
  ///
  /// 找到新版的话 `web/app_update.js` 会把页面重载，所以那条路径上这里什么都
  /// 不用收尾 —— 连 setState 都不必，widget 马上就不在了。
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
      log('检查更新失败', error: error, stackTrace: st);
      if (!mounted) return;
      // 这个按钮存在的理由就是使用者已经不相信画面上的版本了，失败要说出来，
      // 不能让它看起来像「检查过了，没事」。
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
      log('载入画面失败', error: error, stackTrace: st);
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
      log('更新通知设定失败', error: error, stackTrace: st);
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
                // 角色是身分，group 是编辑权限 —— 两种不同的东西，所以用不同
                // 的底色，而不是排成一串看起来同质的标签。
                //
                // 管理员不列 group：他隐含全部，逐项列出反而像是「被指定了这
                // 几项」，看起来比实际权限还小。Wrap 是为了窄萤幕会换行而不是
                // 挤成一行溢出。
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

          // 先藏起来：App 只会记下「要提醒」，还没有任何东西真的在周一寄出。
          // 留著开关会让同工以为打开就会收到。有寄送端之后把这个常数改回 true。
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
              // 登出失败时 session 会被保留（避免假登出），所以错误要在这里
              // 讲清楚，否则使用者以为登出成功、画面却没有变化。
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
                // 页尾的版本资讯。刻意都用同一个灰色小字：这里是注脚，不是
                // 功能入口 —— 平常载入与切回前景都会自己检查更新，按钮只是给
                // 「我看起来还是旧版」的人一个不必被叫去滑掉 App 的出口。
                // 一颗正常的 TextButton（主色、按钮级字级）会比它上面那行还
                // 抢眼，看起来像有什么事该做。
                final captionStyle = Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: Colors.grey.shade600);

                // 两行，各自置中。挤在同一行时「检查更新」会把整组推得偏
                // 左，看起来像没对齐。
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 这是「这台装置正在跑的版本」，不是伺服器的 ——
                    // version.json 跟著 bundle 一起进快取（见 AppVersionService）。
                    if (info != null)
                      Text(
                        '更新于 ${_buildVersionDateText(info)}',
                        textAlign: TextAlign.center,
                        style: captionStyle,
                      ),
                    if (widget.updateService.isSupported)
                      InkWell(
                        onTap: _isCheckingUpdate ? null : _checkForUpdate,
                        // 字级小，靠 padding 把可点范围撑到手指按得到。
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: 8,
                            horizontal: 12,
                          ),
                          child: Text(
                            _isCheckingUpdate ? '检查中…' : '检查更新',
                            textAlign: TextAlign.center,
                            // 颜色跟上面那行一样，只用底线表示按得下去。
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

  /// 空字串直接取 [0] 会 RangeError（Firestore 上的 name 不保证非空）。
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

/// 「有新版本」。点下去开更新教学：更新要在 Cloud Shell 跑精灵，App 自己做不到。
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
