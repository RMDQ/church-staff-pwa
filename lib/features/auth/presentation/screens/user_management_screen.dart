import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../domain/entities/user.dart';
import 'package:church_staff_pwa/core/types/service_type.dart';
import '../../../../core/widgets/text_warmup.dart';
import '../providers/session_provider.dart';
import '../providers/user_admin_provider.dart';
import '../providers/group_settings_provider.dart';
import 'signup_review_screen.dart';
import 'user_editor_screen.dart';

class UserManagementScreen extends StatefulWidget {
  const UserManagementScreen({super.key});

  @override
  State<UserManagementScreen> createState() => _UserManagementScreenState();
}

class _UserManagementScreenState extends State<UserManagementScreen> {
  // itemBuilder 会跑很多次，常数配置一次就好。
  static const _cardRadius = BorderRadius.all(Radius.circular(12));
  static const _cardMargin = EdgeInsets.symmetric(horizontal: 16, vertical: 8);

  late Future<List<User>> _usersFuture;
  String _nameFilter = '';
  List<_UserListItemData> _sortedUsers = const [];

  // GroupSettingsProvider.templates 刻意回传同一份 reference，
  // 所以用 identical() 就能判断要不要重排，不必逐项比对。
  Map<ServiceType, List<String>>? _lastTemplates;

  // 名单里会显示的所有不重复字串，资料换了才重算。给 TextWarmup 用。
  List<String> _warmupStrings = const [];

  final ScrollController _scrollController = ScrollController();
  double _restoreOffset = 0;
  bool _pendingRestore = false;
  List<User> _lastUsers = const [];
  bool _isRefreshing = false;
  bool _hasLoaded = false;

  // Refresh generation counter：删除、关闭编辑 dialog、初次载入都会各自发一次
  // 请求，先发的不保证先回。没有这个 token，晚回的旧请求会把新资料
  // （_sortedUsers / _warmupStrings）盖回旧的，画面与 _usersFuture 对不起来。
  int _refreshToken = 0;

  @override
  void initState() {
    super.initState();
    _refreshUsers();
  }

  void _refreshUsers() {
    if (_scrollController.hasClients) {
      _restoreOffset = _scrollController.offset;
      _pendingRestore = true;
    }
    final token = ++_refreshToken;
    // 管理画面 pull-to-refresh / initial load 一律拉最新，避开 cache。
    final future = context.read<UserAdminProvider>().getUsers(
      forceRefresh: true,
    );
    setState(() {
      _usersFuture = future;
      _isRefreshing = true;
    });
    future
        .then((users) {
          if (!mounted || token != _refreshToken) return;
          // 资料回来才排序，用一次性的 context.read 取 templates。
          final templates = context.read<GroupSettingsProvider>().templates;
          setState(() {
            _lastUsers = users;
            _sortedUsers = _buildSortedUsers(users, templates);
            // 预热的是「列上真正会显示的字串」：标题与副标。名单的人不见得
            // 都出现在服事表里，所以这里要自己来一次。
            _warmupStrings = TextWarmup.uniqueStringsOf(
              _sortedUsers.expand((item) => [item.displayName, item.subtitle]),
            );
            _lastTemplates = templates;
            _isRefreshing = false;
            _hasLoaded = true;
          });
        })
        .catchError((_) {
          if (!mounted || token != _refreshToken) return;
          setState(() {
            _isRefreshing = false;
          });
        });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _openEditor([User? user]) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        final size = MediaQuery.of(context).size;
        final width = size.width < 640 ? size.width - 32 : 600.0;
        final height = size.height < 720 ? size.height - 32 : 700.0;
        return Dialog(
          insetPadding: const EdgeInsets.all(16),
          child: SizedBox(
            width: width,
            height: height,
            child: UserEditorScreen(user: user, isDialog: true),
          ),
        );
      },
    );
    _refreshUsers();
  }

  @override
  Widget build(BuildContext context) {
    // 自己那一行不给删：唯一的管理员删掉自己，网站就没人能管了。
    final selfId = context.select<SessionProvider, String?>(
      (session) => session.currentUser?.id,
    );
    // context.select 仍负责在 templates 变动时触发 rebuild；
    // 这里用 reference 比较决定要不要重排。
    final groupTemplates = context
        .select<GroupSettingsProvider, Map<ServiceType, List<String>>>(
          (provider) => provider.templates,
        );

    // Re-sort only when the templates reference differs AND we have data.
    if (!identical(groupTemplates, _lastTemplates) && _lastUsers.isNotEmpty) {
      _sortedUsers = _buildSortedUsers(_lastUsers, groupTemplates);
      _lastTemplates = groupTemplates;
    }

    // BorderSide 吃 theme，只能留在 build，但至少提到 itemBuilder 外面。
    final cardBorderSide = BorderSide(
      color: Theme.of(context).dividerColor.withValues(alpha: 0.6),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('账号管理'),
        actions: [
          IconButton(
            tooltip: '待审核的注册',
            icon: const Icon(Icons.how_to_reg_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const SignupReviewScreen(),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openEditor(),
        child: const Icon(Icons.add),
      ),
      body: Stack(
        children: [
          TextWarmup(strings: _warmupStrings),
          FutureBuilder<List<User>>(
            future: _usersFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting &&
                  !_hasLoaded) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return Center(child: Text('Error: ${snapshot.error}'));
              }

              // _sortedUsers is up-to-date: either from _refreshUsers callback
              // or the reference-check block in build().
              final filter = _nameFilter.trim().toLowerCase();
              final filteredUsers = filter.isEmpty
                  ? _sortedUsers
                  : _sortedUsers
                        .where((item) => item.nameLower.contains(filter))
                        .toList();

              // KEPT: scroll-position restore (0c178a5 fix)
              if (_pendingRestore && _scrollController.hasClients) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted || !_scrollController.hasClients) return;
                  final maxOffset = _scrollController.position.maxScrollExtent;
                  if (maxOffset <= 0 && _restoreOffset > 0) {
                    return;
                  }
                  final target = _restoreOffset > maxOffset
                      ? maxOffset
                      : _restoreOffset;
                  if (target >= 0) {
                    _scrollController.jumpTo(target);
                  }
                  _pendingRestore = false;
                });
              }

              return Column(
                children: [
                  if (_isRefreshing)
                    const LinearProgressIndicator(minHeight: 2),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: TextField(
                      decoration: const InputDecoration(
                        labelText: '搜索姓名',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.search),
                      ),
                      onChanged: (value) {
                        setState(() {
                          _nameFilter = value;
                          // reset scroll position on new search
                        });
                        if (_scrollController.hasClients) {
                          _scrollController.jumpTo(0);
                        }
                      },
                    ),
                  ),
                  Expanded(
                    child: filteredUsers.isEmpty
                        ? const Center(child: Text('没有匹配的账号'))
                        : ListView.builder(
                            key: const PageStorageKey('user_management_list'),
                            controller: _scrollController,
                            itemExtent: 88,
                            itemCount: filteredUsers.length,
                            itemBuilder: (context, index) {
                              final data = filteredUsers[index];

                              return RepaintBoundary(
                                child: Card(
                                  margin: _cardMargin,
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: _cardRadius,
                                    side: cardBorderSide,
                                  ),
                                  child: ListTile(
                                    leading: const CircleAvatar(
                                      child: Icon(Icons.person, size: 18),
                                    ),
                                    title: Text(
                                      data.displayName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: Text(
                                      data.subtitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    onTap: () => _openEditor(data.user),
                                    trailing: data.user.id == selfId
                                        ? null
                                        : IconButton(
                                            icon: const Icon(
                                              Icons.delete,
                                              color: Colors.red,
                                            ),
                                            onPressed: () async {
                                              final authProvider = context
                                                  .read<UserAdminProvider>();
                                              final messenger =
                                                  ScaffoldMessenger.of(context);
                                              final confirm = await showDialog<bool>(
                                                context: context,
                                                builder: (context) => AlertDialog(
                                                  title: const Text('确认删除'),
                                                  content: Text(
                                                    '确定要删除 ${data.user.name} 吗？',
                                                  ),
                                                  actions: [
                                                    TextButton(
                                                      onPressed: () =>
                                                          Navigator.pop(
                                                            context,
                                                            false,
                                                          ),
                                                      child: const Text('取消'),
                                                    ),
                                                    TextButton(
                                                      onPressed: () =>
                                                          Navigator.pop(
                                                            context,
                                                            true,
                                                          ),
                                                      child: const Text(
                                                        '删除',
                                                        style: TextStyle(
                                                          color: Colors.red,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              );

                                              if (confirm != true) return;
                                              try {
                                                await authProvider.deleteUser(
                                                  data.user.id,
                                                );
                                              } catch (e, st) {
                                                log(
                                                  '刪除使用者失敗',
                                                  error: e,
                                                  stackTrace: st,
                                                );
                                                messenger.showSnackBar(
                                                  accountErrorSnackBar(
                                                    e,
                                                    prefix: '刪除失敗：',
                                                  ),
                                                );
                                                return;
                                              }
                                              if (!context.mounted) return;
                                              _refreshUsers();
                                            },
                                          ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// 使用者列表的副标：`角色 | 牧区 | 可编辑：…`。
///
/// 角色与牧区都是身分，排在一起；编辑权是另一回事，接在后面。副标只有一行，
/// 超出的部分会从尾端被 ellipsis 切掉 —— 牧区标签只有「主日／青崇／儿主」这种
/// 两个字的短名，所以就算三个牧区都有，权限通常还是看得到。
///
/// 管理员本来就全有，role 标签已经说完了，逐项列出反而像是被指定了那几项。
String userListSubtitle(User user, String zoneText) {
  final groupText = user.isAdmin
      ? ''
      : [
          for (final group in UserGroup.values)
            if (user.groups.contains(group)) group.shortLabel,
        ].join('、');
  return [
    user.role.label,
    if (zoneText.isNotEmpty) zoneText,
    if (groupText.isNotEmpty) '可编辑：$groupText',
  ].join(' | ');
}

class _UserListItemData {
  final User user;
  final String displayName;
  final String subtitle;
  final String initial;
  final String nameLower;
  final int roleOrder;
  final int zoneOrder;
  final int groupOrder;

  const _UserListItemData({
    required this.user,
    required this.displayName,
    required this.subtitle,
    required this.initial,
    required this.nameLower,
    required this.roleOrder,
    required this.zoneOrder,
    required this.groupOrder,
  });
}

List<_UserListItemData> _buildSortedUsers(
  List<User> users,
  Map<ServiceType, List<String>> groupTemplates,
) {
  final result = <_UserListItemData>[];
  for (final user in users) {
    UserZoneInfo? primaryZone;
    var minIndex = 999;
    for (final zone in user.zones) {
      final idx = ServiceType.values.indexOf(zone.serviceType);
      if (idx < minIndex) {
        minIndex = idx;
        primaryZone = zone;
      }
    }
    final zoneOrder = primaryZone == null ? 999 : minIndex;
    final roleOrder = UserRole.values.indexOf(user.role);
    var groupOrder = 999;
    if (primaryZone != null && primaryZone.smallGroups.isNotEmpty) {
      final groupOrderList =
          groupTemplates[primaryZone.serviceType] ?? const <String>[];
      final groupName = primaryZone.smallGroups.first;
      final idx = groupOrderList.indexOf(groupName);
      if (idx != -1) {
        groupOrder = idx;
      }
    }
    final zoneText = user.zones.map((z) => z.serviceType.label).join(', ');
    final displayName = user.username.isEmpty ? '${user.name}（无帐号）' : user.name;
    final subtitle = userListSubtitle(user, zoneText);
    result.add(
      _UserListItemData(
        user: user,
        displayName: displayName,
        subtitle: subtitle,
        initial: user.name.isEmpty ? '?' : user.name[0],
        nameLower: user.name.toLowerCase(),
        roleOrder: roleOrder,
        zoneOrder: zoneOrder,
        groupOrder: groupOrder,
      ),
    );
  }

  result.sort((a, b) {
    if (a.roleOrder != b.roleOrder) return a.roleOrder - b.roleOrder;
    if (a.zoneOrder != b.zoneOrder) return a.zoneOrder - b.zoneOrder;
    if (a.groupOrder != b.groupOrder) return a.groupOrder - b.groupOrder;
    return a.user.name.compareTo(b.user.name);
  });

  return result;
}
