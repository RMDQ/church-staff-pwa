import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:church_staff_pwa/core/types/service_type.dart';
import '../providers/roster_provider.dart';
import '../../../auth/presentation/providers/user_admin_provider.dart';
import '../../../../core/widgets/settings_bottom_sheet.dart';
import '../../../../core/widgets/text_controller_scope.dart';
import '../write_failure.dart';

/// 部分失败时接在后面的话：设定本身写进去了，只有几天的服事表没同步到新
/// 名称。再存一次会补上 —— 改过的那几天已经没有旧名称可以换，不会重复改。
const _partialSaveNote = '设定本身已储存，再按一次储存会补上';

class RoleSettingsScreen extends StatefulWidget {
  const RoleSettingsScreen({super.key});

  @override
  State<RoleSettingsScreen> createState() => _RoleSettingsScreenState();
}

class _RoleSettingsScreenState extends State<RoleSettingsScreen> {
  late Map<ServiceType, List<String>> _editingTemplates;
  late Map<ServiceType, Map<String, String>> _renamedRolesByType;
  late final Map<ServiceType, ScrollController> _scrollControllers;

  @override
  void initState() {
    super.initState();
    final provider = context.read<RosterProvider>();
    _editingTemplates = Map.fromIterables(
      provider.templates.keys,
      provider.templates.values.map((list) => List<String>.from(list)),
    );
    _renamedRolesByType = {
      for (final type in ServiceType.values) type: <String, String>{},
    };
    _scrollControllers = {
      for (final type in ServiceType.values) type: ScrollController(),
    };
  }

  @override
  void dispose() {
    for (final controller in _scrollControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _promptAddRole(ServiceType type) async {
    // controller 由 TextControllerScope 在 bottom sheet 子树卸载时 dispose。
    final controller = TextEditingController();
    final name = await _showRoleNameDialog(
      title: '新增项目',
      controller: controller,
      existing: _editingTemplates[type] ?? const <String>[],
    );
    if (name == null) return;
    setState(() {
      (_editingTemplates[type] ??= []).add(name);
    });
  }

  void _removeRole(ServiceType type, int index) {
    setState(() {
      _editingTemplates[type]?.removeAt(index);
    });
  }

  Future<void> _promptEditRole(ServiceType type, int index) async {
    final current = _editingTemplates[type]?[index] ?? '';
    final controller = TextEditingController(text: current);
    final name = await _showRoleNameDialog(
      title: '编辑项目',
      controller: controller,
      existing: _editingTemplates[type] ?? const <String>[],
      currentName: current,
    );
    if (name == null) return;
    _trackRoleRename(type, current, name);
    _updateRole(type, index, name);
  }

  void _trackRoleRename(ServiceType type, String oldName, String newName) {
    final from = oldName.trim();
    final to = newName.trim();
    if (from.isEmpty || to.isEmpty || from == to) return;

    final mapping = _renamedRolesByType[type]!;
    var original = from;
    for (final entry in mapping.entries) {
      if (entry.value == from) {
        original = entry.key;
        break;
      }
    }

    mapping.remove(from);
    if (original == to) {
      mapping.remove(original);
      return;
    }
    mapping[original] = to;
  }

  Future<void> _confirmRemoveRole(ServiceType type, int index) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: const Text('今天以后每一周的服事表都会拿掉这一项，已经排的人也会一起删掉。已经过去的服事表不会动。'),
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
      _removeRole(type, index);
    }
  }

  Future<String?> _showRoleNameDialog({
    required String title,
    required TextEditingController controller,
    required List<String> existing,
    String? currentName,
  }) async {
    controller.selection = TextSelection.collapsed(
      offset: controller.text.length,
    );
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
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

        void submit(StateSetter setState) {
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
            builder: (context, setState) {
              return SettingsBottomSheet(
                title: title,
                onSubmit: () => submit(setState),
                child: TextField(
                  controller: controller,
                  decoration: InputDecoration(
                    labelText: '服事项目名称',
                    hintText: '例：敬拜主领',
                    hintStyle: TextStyle(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.35),
                    ),
                    floatingLabelBehavior: FloatingLabelBehavior.always,
                    border: const OutlineInputBorder(),
                    errorText: errorText,
                  ),
                  onChanged: (value) =>
                      setState(() => errorText = validateValue(value)),
                  onSubmitted: (_) => submit(setState),
                ),
              );
            },
          ),
        );
      },
    );
    return result;
  }

  void _updateRole(ServiceType type, int index, String value) {
    setState(() {
      _editingTemplates[type]?[index] = value;
    });
  }

  /// 有没有还没按 ✓ 的变更。
  bool get _hasUnsavedChanges {
    final saved = context.read<RosterProvider>().templates;
    for (final type in ServiceType.values) {
      final editing = _editingTemplates[type] ?? const <String>[];
      final original = saved[type] ?? const <String>[];
      if (editing.length != original.length) return true;
      for (var i = 0; i < editing.length; i++) {
        if (editing[i] != original[i]) return true;
      }
    }
    return false;
  }

  Future<void> _confirmDiscard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('还没储存'),
        content: const Text('刚才的变更还没储存。要储存的话，请按右上角 ✓。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('继续编辑'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('不储存，离开'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    // 新增完项目按左上角返回，以前会不声不响地丢掉。✓ 的 Navigator.pop
    // 不经过 PopScope，存好之后照常离开。
    return PopScope(
      canPop: !_hasUnsavedChanges,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmDiscard();
      },
      child: DefaultTabController(
        length: ServiceType.active.length,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('服事项目设定'),
            bottom: TabBar(
              isScrollable: ServiceType.active.length > 3,
              tabs: ServiceType.active
                  .map((type) => Tab(text: type.label))
                  .toList(),
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.check),
                onPressed: () async {
                  final rosterProvider = context.read<RosterProvider>();
                  final userAdminProvider = context.read<UserAdminProvider>();
                  final messenger = ScaffoldMessenger.of(context);
                  // 失败一律留在这页：改到一半的设定还在，再按一次就能重送。
                  PartialUpdateException? partial;
                  try {
                    await rosterProvider.updateTemplates(
                      _editingTemplates,
                      renamedRolesByType: _renamedRolesByType,
                    );
                  } on PartialUpdateException catch (e) {
                    // 样板已经写进去了，只是有几天的服事表没改到名。同工设定
                    // 照样要跟著新样板清，不然两边对不上。
                    partial = e;
                  } catch (e) {
                    // 样板没写进去就不清同工设定。以前写失败也照清，同工的服事
                    // 被新样板删掉，样板本身却还是旧的。
                    showWriteFailure(messenger, '储存', e);
                    return;
                  }
                  try {
                    await userAdminProvider.cleanupUserMinistries(
                      _editingTemplates,
                    );
                  } catch (e) {
                    showWriteFailure(messenger, '储存', e);
                    return;
                  }
                  if (partial != null) {
                    showWriteFailure(
                      messenger,
                      '储存',
                      partial,
                      partialNote: _partialSaveNote,
                    );
                    return;
                  }
                  if (!context.mounted) return;
                  Navigator.pop(context);
                },
              ),
            ],
          ),
          body: TabBarView(
            children: ServiceType.active.map((type) {
              final roles = _editingTemplates[type] ?? [];
              final scrollController = _scrollControllers[type]!;
              return Column(
                children: [
                  // 新教会第一次打开是一片空白，连「新增项目」在左下角都不容易看到。
                  if (roles.isEmpty)
                    Expanded(
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text(
                            '这个聚会还没有服事项目。\n按左下角「新增项目」加入，例如「招待」「司琴」，'
                            '全部加好后按右上角 ✓ 储存。',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ),
                      ),
                    )
                  else
                    Expanded(
                      child: Scrollbar(
                        controller: scrollController,
                        thumbVisibility: true,
                        trackVisibility: true,
                        child: PrimaryScrollController(
                          controller: scrollController,
                          child: ReorderableListView.builder(
                            padding: const EdgeInsets.all(16),
                            itemCount: roles.length,
                            onReorder: (oldIndex, newIndex) {
                              setState(() {
                                if (newIndex > oldIndex) {
                                  newIndex -= 1;
                                }
                                final item = roles.removeAt(oldIndex);
                                roles.insert(newIndex, item);
                                _editingTemplates[type] = List<String>.from(
                                  roles,
                                );
                              });
                            },
                            itemBuilder: (context, index) {
                              return ListTile(
                                key: ValueKey(
                                  'role_${type.name}_${roles[index]}',
                                ),
                                title: Text(roles[index]),
                                onTap: () => _promptEditRole(type, index),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.delete_outline),
                                      onPressed: () =>
                                          _confirmRemoveRole(type, index),
                                    ),
                                    ReorderableDragStartListener(
                                      index: index,
                                      child: const Icon(Icons.drag_handle),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  SafeArea(
                    top: false,
                    child: ListTile(
                      leading: const Icon(Icons.add),
                      title: const Text('新增项目'),
                      onTap: () => _promptAddRole(type),
                    ),
                  ),
                ],
              );
            }).toList(),
          ),
        ),
      ),
    );
  }
}
