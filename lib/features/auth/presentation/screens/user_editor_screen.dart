import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../domain/entities/user.dart';
import 'package:church_staff_pwa/core/types/service_type.dart';
import '../../../roster/presentation/providers/roster_provider.dart';
import '../providers/group_settings_provider.dart';
import '../providers/session_provider.dart';
import '../providers/user_admin_provider.dart';
import '../widgets/account_error_snack_bar.dart';
import '../../../../core/config/church_config.dart';

class UserEditorScreen extends StatefulWidget {
  final User? user; // If null, it's add mode
  final bool isDialog;

  const UserEditorScreen({super.key, this.user, this.isDialog = false});

  @override
  State<UserEditorScreen> createState() => _UserEditorScreenState();
}

class _UserEditorScreenState extends State<UserEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _emailController;
  late TextEditingController _usernameController;
  late TextEditingController _passwordController;
  late UserRole _selectedRole;
  late Set<UserGroup> _groups;
  late List<UserZoneInfo> _zones;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.user?.name ?? '');
    _emailController = TextEditingController(text: widget.user?.email ?? '');
    _usernameController = TextEditingController(
      text: widget.user?.username ?? '',
    );
    _passwordController = TextEditingController();
    _selectedRole = widget.user?.role ?? UserRole.member;
    _groups = Set.from(widget.user?.groups ?? const <UserGroup>{});
    _zones = List.from(widget.user?.zones ?? []);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  /// 编辑权限，一项一项给。
  ///
  /// 管理员本来就隐含全部，所以那个情况下勾选框显示为已勾且不可动 —— 让它可勾
  /// 只会让人以为「取消勾选就能收回」，但实际上 role 才是决定权。
  Widget _buildGroupSection() {
    final isAdmin = _selectedRole == UserRole.admin;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('编辑权限', style: Theme.of(context).textTheme.labelLarge),
        if (isAdmin)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '管理员拥有全部编辑权限，不需要另外指定。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        // 没开行事历的教会不列「行事历编辑」：勾了也没有地方用。已经有的
        // 权限照样显示，才看得到、拿得掉。
        for (final group in UserGroup.values)
          if (group != UserGroup.calendarEditors ||
              ChurchConfig.current.features.calendar ||
              _groups.contains(group))
            CheckboxListTile(
              value: isAdmin || _groups.contains(group),
              onChanged: isAdmin
                  ? null
                  : (checked) {
                      setState(() {
                        if (checked ?? false) {
                          _groups.add(group);
                        } else {
                          _groups.remove(group);
                        }
                      });
                    },
              title: Text(group.label),
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
            ),
      ],
    );
  }

  void _addZone() {
    final usedTypes = _zones.map((zone) => zone.serviceType).toSet();
    // 停用的聚会不再给新的牧区；已经有的照样显示，才改得了、拿得掉。
    final availableTypes = ServiceType.active
        .where((type) => !usedTypes.contains(type))
        .toList();
    if (availableTypes.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已添加所有牧区')));
      return;
    }
    setState(() {
      _zones.add(
        UserZoneInfo(
          serviceType: availableTypes.first,
          smallGroups: [],
          ministries: [],
        ),
      );
    });
  }

  void _removeZone(int index) {
    setState(() {
      _zones.removeAt(index);
    });
  }

  void _updateZone(int index, UserZoneInfo newZone) {
    setState(() {
      _zones[index] = newZone;
    });
  }

  void _syncZoneToAllServices(UserZoneInfo sourceZone) {
    setState(() {
      for (final type in ServiceType.active) {
        final existingIndex = _zones.indexWhere((z) => z.serviceType == type);
        final syncedZone = UserZoneInfo(
          serviceType: type,
          smallGroups: List.from(sourceZone.smallGroups),
          ministries: List.from(sourceZone.ministries),
        );
        if (existingIndex >= 0) {
          _zones[existingIndex] = syncedZone;
        } else {
          _zones.add(syncedZone);
        }
      }
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已将小组与服事设置同步至所有聚会')));
  }

  /// 没填代称就用姓名，跟安装精灵建立首位管理员时一样。
  String get _username {
    final value = _usernameController.text.trim();
    return value.isEmpty ? _nameController.text.trim() : value;
  }

  Future<void> _save() async {
    if (_zones.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请至少设置一个牧区')));
      return;
    }
    if (_formKey.currentState!.validate()) {
      final authProvider = context.read<UserAdminProvider>();
      final email = _emailController.text.trim();
      final hadEmail = widget.user?.email.isNotEmpty ?? false;
      final shouldCreateAuth =
          widget.user != null && !hadEmail && email.isNotEmpty;
      try {
        if (widget.user == null) {
          await authProvider.addUser(
            _nameController.text,
            email,
            _username,
            _selectedRole,
            password: _passwordController.text.trim(),
            zones: _zones,
            groups: _groups,
          );
        } else {
          final updatedUser = widget.user!.copyWith(
            name: _nameController.text,
            email: email,
            username: _username,
            role: _selectedRole,
            zones: _zones,
            groups: _groups,
          );
          await authProvider.updateUser(
            updatedUser,
            password: shouldCreateAuth ? _passwordController.text.trim() : null,
          );
        }

        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('保存成功')));
          Navigator.pop(context);
        }
      } catch (e, st) {
        log('储存使用者资料失败', error: e, stackTrace: st);
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(accountErrorSnackBar(e, prefix: '错误：'));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // 管理员不能改自己的角色：唯一的管理员把自己降级就没人能管了。
    final isSelf =
        widget.user != null &&
        widget.user!.id == context.watch<SessionProvider>().currentUser?.id;
    final canEditEmail =
        widget.user == null || (widget.user?.email.isEmpty ?? false);
    final hadEmail = widget.user?.email.isNotEmpty ?? false;
    final shouldPromptPassword =
        widget.user == null ||
        (!hadEmail && _emailController.text.trim().isNotEmpty);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.user == null ? '新增账号' : '编辑账号'),
        leading: widget.isDialog
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              )
            : null,
        actions: [IconButton(icon: const Icon(Icons.check), onPressed: _save)],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '基本资料',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _nameController,
                      decoration: const InputDecoration(
                        labelText: '姓名',
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) => v?.isEmpty == true ? '请输入姓名' : null,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _emailController,
                      decoration: const InputDecoration(
                        labelText: '邮箱 (选填)',
                        border: OutlineInputBorder(),
                        hintText: 'example@gmail.com',
                        helperText: '填写后将创建登录账号并需要设置密码',
                      ),
                      enabled: canEditEmail,
                      onChanged: canEditEmail ? (_) => setState(() {}) : null,
                      validator: (v) {
                        if (v == null || v.isEmpty) return null;
                        if (!v.contains('@')) return '请输入有效的邮箱地址';
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _usernameController,
                      // 只是显示在个人页的 @代称；登入一律用 Email。以前叫「显示帐号
                      // (ID)」而且有 Email 就必填，同工看不懂要填什么。
                      decoration: const InputDecoration(
                        labelText: '账号代称（选填）',
                        border: OutlineInputBorder(),
                        helperText: '显示在个人主页，不是登录用；不填就默认使用姓名',
                      ),
                    ),
                    if (shouldPromptPassword) ...[
                      if (!hadEmail &&
                          _emailController.text.trim().isNotEmpty) ...[
                        const SizedBox(height: 8),
                        const Text(
                          '添加邮箱后将创建登录账号，请设置登录密码',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ],
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _passwordController,
                        decoration: const InputDecoration(
                          labelText: '密码',
                          border: OutlineInputBorder(),
                          helperText: '创建登录账号用',
                        ),
                        obscureText: true,
                        textInputAction: TextInputAction.done,
                        validator: (v) {
                          if (_emailController.text.trim().isNotEmpty &&
                              v?.trim().isEmpty == true) {
                            return '请输入密码';
                          }
                          return null;
                        },
                      ),
                    ],
                    const SizedBox(height: 16),
                    DropdownButtonFormField<UserRole>(
                      initialValue: _selectedRole,
                      decoration: InputDecoration(
                        labelText: '角色',
                        border: const OutlineInputBorder(),
                        helperText: isSelf ? '不能变更自己的角色，请另一位管理员协助修改' : null,
                      ),
                      items: UserRole.values.map((role) {
                        return DropdownMenuItem(
                          value: role,
                          child: Text(role.label),
                        );
                      }).toList(),
                      onChanged: isSelf
                          ? null
                          : (value) {
                              if (value != null) {
                                setState(() => _selectedRole = value);
                              }
                            },
                    ),
                    const SizedBox(height: 8),
                    _buildGroupSection(),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '牧区资料（必填）',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Wrap(
                  spacing: 4,
                  children: [
                    if (_zones.isNotEmpty && ServiceType.active.length > 1)
                      TextButton.icon(
                        icon: const Icon(Icons.sync, size: 18),
                        label: const Text('同步到所有聚会'),
                        onPressed: () => _syncZoneToAllServices(_zones.first),
                      ),
                    if (ServiceType.active.any(
                      (type) => !_zones.any((zone) => zone.serviceType == type),
                    ))
                      TextButton.icon(
                        icon: const Icon(Icons.add),
                        label: const Text('新增牧区'),
                        onPressed: _addZone,
                      ),
                  ],
                ),
              ],
            ),
            if (_zones.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: Center(
                  child: Text(
                    '尚未设置牧区。请点击「新增牧区」，至少设置一个才能保存。',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
              )
            else
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  '在牧区中勾选「参与服事」，这位同工才会出现在该服事的排班名单。',
                  style: TextStyle(color: Colors.grey, fontSize: 13),
                ),
              ),
            ..._zones.asMap().entries.map((entry) {
              final index = entry.key;
              final zone = entry.value;
              return _ZoneEditorCard(
                key: ValueKey('zone_$index'),
                zone: zone,
                usedTypes: _zones.map((z) => z.serviceType).toSet(),
                onRemove: () => _removeZone(index),
                onUpdate: (newZone) => _updateZone(index, newZone),
                onSync: _syncZoneToAllServices,
              );
            }),
          ],
        ),
      ),
    );
  }
}

class _ZoneEditorCard extends StatefulWidget {
  final UserZoneInfo zone;
  final Set<ServiceType> usedTypes;
  final VoidCallback onRemove;
  final ValueChanged<UserZoneInfo> onUpdate;
  final ValueChanged<UserZoneInfo>? onSync;

  const _ZoneEditorCard({
    super.key,
    required this.zone,
    required this.usedTypes,
    required this.onRemove,
    required this.onUpdate,
    this.onSync,
  });

  @override
  State<_ZoneEditorCard> createState() => _ZoneEditorCardState();
}

class _ZoneEditorCardState extends State<_ZoneEditorCard> {
  late List<String> _groups;
  late List<String> _ministries;
  late ServiceType _selectedType;

  @override
  void initState() {
    super.initState();
    _selectedType = widget.zone.serviceType;
    _groups = List.from(widget.zone.smallGroups);
    _ministries = List.from(widget.zone.ministries);
  }

  void _notifyUpdate() {
    widget.onUpdate(
      widget.zone.copyWith(
        serviceType: _selectedType,
        smallGroups: _groups,
        ministries: _ministries,
      ),
    );
  }

  Future<void> _confirmRemoveZone() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: const Text('确定要删除此牧区吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      widget.onRemove();
    }
  }

  @override
  Widget build(BuildContext context) {
    final templates = context.watch<RosterProvider>().templates;
    final ministryOptions = templates[_selectedType] ?? const <String>[];
    final groupTemplates = context.watch<GroupSettingsProvider>().templates;
    final groupOptions = groupTemplates[_selectedType] ?? const <String>[];

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<ServiceType>(
                    initialValue: _selectedType,
                    decoration: const InputDecoration(labelText: '牧区'),
                    items: {...ServiceType.active, _selectedType}.map((type) {
                      final isUsed = widget.usedTypes.contains(type);
                      final isCurrent = type == _selectedType;
                      return DropdownMenuItem(
                        value: type,
                        enabled: !isUsed || isCurrent,
                        child: Text(
                          type.label,
                          style: TextStyle(
                            color: !isUsed || isCurrent ? null : Colors.grey,
                          ),
                        ),
                      );
                    }).toList(),
                    onChanged: (value) {
                      if (value != null) {
                        final newOptions =
                            context.read<RosterProvider>().templates[value] ??
                            [];
                        final newGroupOptions =
                            context
                                .read<GroupSettingsProvider>()
                                .templates[value] ??
                            [];
                        setState(() {
                          _selectedType = value;
                          _ministries = _ministries
                              .where(newOptions.contains)
                              .toList();
                          _groups = _groups
                              .where(newGroupOptions.contains)
                              .toList();
                        });
                        _notifyUpdate();
                      }
                    },
                  ),
                ),
                if (ServiceType.active.length > 1 && widget.onSync != null)
                  IconButton(
                    icon: const Icon(Icons.sync, color: Colors.blue),
                    tooltip: '以此牧区设置同步到所有聚会',
                    onPressed: () => widget.onSync!(
                      widget.zone.copyWith(
                        serviceType: _selectedType,
                        smallGroups: _groups,
                        ministries: _ministries,
                      ),
                    ),
                  ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                  onPressed: _confirmRemoveZone,
                ),
              ],
            ),
            const SizedBox(height: 12),

            _OptionListSelector(
              title: '所属小组',
              options: groupOptions,
              selected: _groups,
              onChanged: (newGroups) {
                _groups = newGroups;
                _notifyUpdate();
              },
              emptyText: '尚未设置小组列表',
            ),
            const SizedBox(height: 12),

            _OptionListSelector(
              title: '参与服事',
              options: ministryOptions,
              selected: _ministries,
              onChanged: (newMinistries) {
                _ministries = newMinistries;
                _notifyUpdate();
              },
              emptyText: '尚未设置服事项目：请先到「服事表」点击铅笔，再点击右上角图标「服事项目设置」添加',
            ),
          ],
        ),
      ),
    );
  }
}

class _OptionListSelector extends StatelessWidget {
  final String title;
  final List<String> options;
  final List<String> selected;
  final ValueChanged<List<String>> onChanged;
  final String emptyText;

  const _OptionListSelector({
    required this.title,
    required this.options,
    required this.selected,
    required this.onChanged,
    required this.emptyText,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
        ),
        const SizedBox(height: 4),
        if (options.isEmpty)
          Text(emptyText, style: const TextStyle(color: Colors.grey)),
        if (options.isNotEmpty)
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: options.map((option) {
              final isSelected = selected.contains(option);
              return FilterChip(
                label: Text(option),
                selected: isSelected,
                onSelected: (value) {
                  final updated = List<String>.from(selected);
                  if (value) {
                    if (!updated.contains(option)) {
                      updated.add(option);
                    }
                  } else {
                    updated.remove(option);
                  }
                  final ordered = options.where(updated.contains).toList();
                  onChanged(ordered);
                },
              );
            }).toList(),
          ),
      ],
    );
  }
}
