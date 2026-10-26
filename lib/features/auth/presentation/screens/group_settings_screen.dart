import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:church_staff_pwa/core/types/service_type.dart';
import '../../../../core/widgets/text_controller_scope.dart';
import '../providers/group_settings_provider.dart';
import '../providers/user_admin_provider.dart';

class GroupSettingsScreen extends StatefulWidget {
  const GroupSettingsScreen({super.key});

  @override
  State<GroupSettingsScreen> createState() => _GroupSettingsScreenState();
}

class _GroupSettingsScreenState extends State<GroupSettingsScreen> {
  late Map<ServiceType, List<String>> _editingTemplates;
  bool _initialized = false;
  bool _sharedAcrossServices = false;

  @override
  void initState() {
    super.initState();
    _editingTemplates = {for (final type in ServiceType.values) type: []};
  }

  List<String> get _unifiedGroups {
    final seen = <String>{};
    final result = <String>[];
    for (final type in ServiceType.active) {
      final list = _editingTemplates[type];
      if (list != null) {
        for (final item in list) {
          if (seen.add(item)) result.add(item);
        }
      }
    }
    return result;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final provider = context.watch<GroupSettingsProvider>();
    if (!_initialized && !provider.isLoading) {
      _editingTemplates = Map.fromIterables(
        provider.templates.keys,
        provider.templates.values.map((list) => List<String>.from(list)),
      );
      if (_sharedAcrossServices) {
        final merged = _unifiedGroups;
        for (final t in ServiceType.active) {
          _editingTemplates[t] = List.from(merged);
        }
      }
      _initialized = true;
    }
  }

  Future<void> _promptAddGroup(ServiceType type) async {
    final controller = TextEditingController();
    final existing = _sharedAcrossServices
        ? _unifiedGroups
        : (_editingTemplates[type] ?? const <String>[]);
    final name = await _showGroupNameDialog(
      title: '新增小组',
      controller: controller,
      existing: existing,
    );
    if (name == null) return;
    setState(() {
      if (_sharedAcrossServices) {
        for (final t in ServiceType.active) {
          final list = _editingTemplates[t] ??= [];
          if (!list.contains(name)) list.add(name);
        }
      } else {
        (_editingTemplates[type] ??= []).add(name);
      }
    });
  }

  void _removeGroup(int index, ServiceType type) {
    setState(() {
      if (_sharedAcrossServices) {
        final groupName = _unifiedGroups[index];
        for (final t in ServiceType.active) {
          _editingTemplates[t]?.remove(groupName);
        }
      } else {
        _editingTemplates[type]?.removeAt(index);
      }
    });
  }

  Future<void> _promptEditGroup(int index, ServiceType type) async {
    final current = _sharedAcrossServices
        ? _unifiedGroups[index]
        : (_editingTemplates[type]?[index] ?? '');
    final controller = TextEditingController(text: current);
    final existing = _sharedAcrossServices
        ? _unifiedGroups
        : (_editingTemplates[type] ?? const <String>[]);
    final name = await _showGroupNameDialog(
      title: '编辑小组',
      controller: controller,
      existing: existing,
      currentName: current,
    );
    if (name == null) return;
    _updateGroup(index, name, type);
  }

  Future<void> _confirmRemoveGroup(int index, ServiceType type) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: const Text('确定要删除此小组吗？'),
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

    if (confirmed == true) {
      _removeGroup(index, type);
    }
  }

  Future<String?> _showGroupNameDialog({
    required String title,
    required TextEditingController controller,
    required List<String> existing,
    String? currentName,
  }) {
    return showDialog<String>(
      context: context,
      builder: (context) {
        String? errorText;
        String? validateValue(String value) {
          final trimmed = value.trim();
          if (trimmed.isEmpty) return '请输入名称';
          final isDuplicate = existing.any(
            (name) =>
                name.trim() == trimmed && name.trim() != currentName?.trim(),
          );
          if (isDuplicate) return '名称已存在';
          return null;
        }

        void submit() {
          final value = controller.text;
          final validation = validateValue(value);
          if (validation != null) {
            setState(() => errorText = validation);
            return;
          }
          Navigator.pop(context, value.trim());
        }

        return TextControllerScope(
          controller: controller,
          child: StatefulBuilder(
            builder: (context, setState) => AlertDialog(
              title: Text(title),
              content: TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: '小组名称',
                  border: const OutlineInputBorder(),
                  errorText: errorText,
                ),
                onChanged: (value) =>
                    setState(() => errorText = validateValue(value)),
                onSubmitted: (_) => submit(),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                TextButton(onPressed: submit, child: const Text('保存')),
              ],
            ),
          ),
        );
      },
    );
  }

  void _updateGroup(int index, String value, ServiceType type) {
    setState(() {
      if (_sharedAcrossServices) {
        final oldName = _unifiedGroups[index];
        for (final t in ServiceType.active) {
          final list = _editingTemplates[t];
          if (list != null) {
            final oldIdx = list.indexOf(oldName);
            if (oldIdx >= 0) {
              list[oldIdx] = value;
            } else if (!list.contains(value)) {
              list.add(value);
            }
          }
        }
      } else {
        _editingTemplates[type]?[index] = value;
      }
    });
  }

  void _syncToAllServices(ServiceType current) {
    final currentList = List<String>.from(_editingTemplates[current] ?? []);
    setState(() {
      for (final t in ServiceType.active) {
        _editingTemplates[t] = List.from(currentList);
      }
      _sharedAcrossServices = true;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已将「${current.label}」的小组同步至所有聚会，并开启全教会共用')),
    );
  }

  Widget _buildGroupList(List<String> groups, ServiceType type) {
    final displayGroups = _sharedAcrossServices ? _unifiedGroups : groups;
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: displayGroups.length + 1,
      itemBuilder: (context, index) {
        if (index == displayGroups.length) {
          return ListTile(
            leading: const Icon(Icons.add),
            title: const Text('新增小组'),
            onTap: () => _promptAddGroup(type),
          );
        }
        return ListTile(
          title: Text(displayGroups[index]),
          onTap: () => _promptEditGroup(index, type),
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _confirmRemoveGroup(index, type),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<GroupSettingsProvider>();
    if (!_initialized && provider.isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('小组设置')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (!_initialized && provider.error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('小组设置')),
        body: Center(child: Text(provider.error!)),
      );
    }

    final hasMultipleServices = ServiceType.active.length > 1;

    final actions = [
      if (hasMultipleServices)
        TextButton.icon(
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.primary,
          ),
          icon: Icon(
            _sharedAcrossServices ? Icons.link : Icons.link_off,
            size: 18,
          ),
          label: Text(_sharedAcrossServices ? '全教会共用' : '各聚会独立'),
          onPressed: () {
            setState(() {
              _sharedAcrossServices = !_sharedAcrossServices;
              if (_sharedAcrossServices) {
                final merged = _unifiedGroups;
                for (final t in ServiceType.active) {
                  _editingTemplates[t] = List.from(merged);
                }
              }
            });
          },
        ),
      IconButton(
        icon: const Icon(Icons.check),
        onPressed: () async {
          final settingsProvider = context.read<GroupSettingsProvider>();
          final userAdminProvider = context.read<UserAdminProvider>();
          await settingsProvider.updateTemplates(_editingTemplates);
          await userAdminProvider.cleanupUserSmallGroups(_editingTemplates);
          if (!context.mounted) return;
          Navigator.pop(context);
        },
      ),
    ];

    return DefaultTabController(
      length: ServiceType.active.length,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('小组设置'),
          bottom: TabBar(
            isScrollable: ServiceType.active.length > 3,
            tabs: ServiceType.active
                .map((type) => Tab(text: type.label))
                .toList(),
          ),
          actions: actions,
        ),
        body: TabBarView(
          children: ServiceType.active.map((type) {
            final groups = _editingTemplates[type] ?? [];
            return Column(
              children: [
                if (hasMultipleServices)
                  Card(
                    margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    color: _sharedAcrossServices
                        ? Theme.of(
                            context,
                          ).colorScheme.primaryContainer.withAlpha(80)
                        : Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest.withAlpha(80),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            _sharedAcrossServices ? Icons.link : Icons.link_off,
                            size: 18,
                            color: _sharedAcrossServices
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _sharedAcrossServices
                                  ? '已开启全教会共用：${ServiceType.active.map((t) => t.label).join('、')} 同步共用小组'
                                  : '当前为「${type.label}」独立小组名单',
                              style: TextStyle(
                                fontSize: 12,
                                color: _sharedAcrossServices
                                    ? Theme.of(
                                        context,
                                      ).colorScheme.onPrimaryContainer
                                    : Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          if (!_sharedAcrossServices)
                            TextButton.icon(
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                              ),
                              icon: const Icon(Icons.copy_all, size: 16),
                              label: const Text(
                                '同步到所有聚会',
                                style: TextStyle(fontSize: 12),
                              ),
                              onPressed: () => _syncToAllServices(type),
                            ),
                        ],
                      ),
                    ),
                  ),
                Expanded(child: _buildGroupList(groups, type)),
              ],
            );
          }).toList(),
        ),
      ),
    );
  }
}
