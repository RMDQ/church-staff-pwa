import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../domain/entities/event_option.dart';
import 'package:church_staff_pwa/core/types/service_type.dart';
import '../providers/roster_provider.dart';
import '../../../../core/widgets/settings_bottom_sheet.dart';
import '../../../../core/widgets/text_controller_scope.dart';
import '../write_failure.dart';
import '../widgets/event_color_picker.dart';

/// 部分失败时接在后面的话：设定本身写进去了，只有几天的服事表没同步到新
/// 名称。再存一次会补上 —— 改过的那几天已经没有旧名称可以换，不会重复改。
const _partialSaveNote = '设定本身已储存，再按一次储存会补上';

class EventSettingsScreen extends StatefulWidget {
  const EventSettingsScreen({super.key});

  @override
  State<EventSettingsScreen> createState() => _EventSettingsScreenState();
}

class _EventSettingsScreenState extends State<EventSettingsScreen> {
  late Map<ServiceType, List<EventOption>> _editingOptions;
  late Map<ServiceType, Map<String, String>> _renamedEventsByType;
  late final Map<ServiceType, ScrollController> _scrollControllers;

  @override
  void initState() {
    super.initState();
    final provider = context.read<RosterProvider>();
    _editingOptions = Map.fromEntries(
      provider.eventOptionsByType.entries.map(
        (entry) => MapEntry(entry.key, List<EventOption>.from(entry.value)),
      ),
    );
    _renamedEventsByType = {
      for (final type in ServiceType.values) type: <String, String>{},
    };
    _scrollControllers = {
      for (final type in ServiceType.values) type: ScrollController(),
    };
    for (final type in ServiceType.values) {
      _editingOptions.putIfAbsent(type, () => <EventOption>[]);
    }
  }

  @override
  void dispose() {
    for (final controller in _scrollControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _promptAddEvent(ServiceType type) async {
    // controller 由 TextControllerScope 在 bottom sheet 子树卸载时 dispose。
    final controller = TextEditingController();
    final result = await _showEventDialog(
      title: '新增事件',
      controller: controller,
      existing: _editingOptions[type] ?? const <EventOption>[],
      // 预设给这个崇拜用得最少的颜色，跟汇入时自动加进清单的挑法一样。
      initialColor: pickEventColor(
        _editingOptions[type] ?? const <EventOption>[],
      ),
    );
    if (result == null) return;
    setState(() => _editingOptions[type]?.add(result));
  }

  Future<void> _promptEditEvent(ServiceType type, int index) async {
    final current = _editingOptions[type]?[index];
    if (current == null) return;
    final controller = TextEditingController(text: current.name);
    final result = await _showEventDialog(
      title: '编辑事件',
      controller: controller,
      existing: _editingOptions[type] ?? const <EventOption>[],
      currentName: current.name,
      initialColor: current.color,
    );
    if (result == null) return;
    _trackEventRename(type, current.name, result.name);
    setState(() => _editingOptions[type]?[index] = result);
  }

  void _trackEventRename(ServiceType type, String oldName, String newName) {
    final from = oldName.trim();
    final to = newName.trim();
    if (from.isEmpty || to.isEmpty || from == to) return;

    final mapping = _renamedEventsByType[type]!;
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

  Future<void> _confirmRemoveEvent(ServiceType type, int index) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: const Text('确定要删除此事件吗？'),
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
      setState(() => _editingOptions[type]?.removeAt(index));
    }
  }

  Future<EventOption?> _showEventDialog({
    required String title,
    required TextEditingController controller,
    required List<EventOption> existing,
    String? currentName,
    required int initialColor,
  }) {
    controller.selection = TextSelection.collapsed(
      offset: controller.text.length,
    );
    return showModalBottomSheet<EventOption>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) {
        String? errorText;
        int selectedColor = initialColor;
        String? validateValue(String value) {
          final trimmed = value.trim();
          if (trimmed.isEmpty) return '请输入名称';
          final isDuplicate = existing.any(
            (name) =>
                name.name.trim() == trimmed &&
                name.name.trim() != currentName?.trim(),
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
          Navigator.pop(
            context,
            EventOption(name: value.trim(), color: selectedColor),
          );
        }

        return TextControllerScope(
          controller: controller,
          child: StatefulBuilder(
            builder: (context, setState) {
              return SettingsBottomSheet(
                title: title,
                onSubmit: () => submit(setState),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: controller,
                      decoration: InputDecoration(
                        labelText: '事件名称',
                        hintText: '例：圣餐主日',
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
                    const SizedBox(height: 16),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '标签颜色',
                        style: TextStyle(color: Colors.grey.shade700),
                      ),
                    ),
                    const SizedBox(height: 8),
                    EventColorPicker(
                      selected: selectedColor,
                      onSelected: (color) =>
                          setState(() => selectedColor = color),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: ServiceType.active.length,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('事件选项设定'),
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
                final messenger = ScaffoldMessenger.of(context);
                try {
                  await rosterProvider.updateEventOptions(
                    _editingOptions,
                    renamedEventsByType: _renamedEventsByType,
                  );
                } catch (e) {
                  // 留在这页：改到一半的设定还在，再按一次就能重送。
                  showWriteFailure(
                    messenger,
                    '储存',
                    e,
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
            final options = _editingOptions[type] ?? const <EventOption>[];
            final scrollController = _scrollControllers[type]!;
            return Column(
              children: [
                Expanded(
                  child: Scrollbar(
                    controller: scrollController,
                    thumbVisibility: true,
                    trackVisibility: true,
                    child: PrimaryScrollController(
                      controller: scrollController,
                      child: ReorderableListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: options.length,
                        onReorder: (oldIndex, newIndex) {
                          setState(() {
                            if (newIndex > oldIndex) {
                              newIndex -= 1;
                            }
                            final item = options.removeAt(oldIndex);
                            options.insert(newIndex, item);
                            _editingOptions[type] = List<EventOption>.from(
                              options,
                            );
                          });
                        },
                        itemBuilder: (context, index) {
                          return ListTile(
                            key: ValueKey(
                              'event_${type.name}_${index}_${options[index].name}',
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                            ),
                            horizontalTitleGap: 12,
                            minLeadingWidth: 24,
                            leading: SizedBox(
                              width: 24,
                              child: Center(
                                child: Container(
                                  width: 20,
                                  height: 20,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Color(options[index].color),
                                    border: Border.all(
                                      color: Color(
                                        options[index].color,
                                      ).withValues(alpha: 0.8),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            title: Text(options[index].name),
                            onTap: () => _promptEditEvent(type, index),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () =>
                                      _confirmRemoveEvent(type, index),
                                ),
                                ReorderableDragStartListener(
                                  index: index,
                                  child: const SizedBox(
                                    width: 24,
                                    child: Center(
                                      child: Icon(Icons.drag_handle),
                                    ),
                                  ),
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
                    title: const Text('新增事件'),
                    onTap: () => _promptAddEvent(type),
                  ),
                ),
              ],
            );
          }).toList(),
        ),
      ),
    );
  }
}
