part of 'roster_card.dart';

// ---------------------------------------------------------------------------
// _PeopleOptions – data class used by RosterCard and _RosterPeopleDialog
// ---------------------------------------------------------------------------

/// 选人视窗送出的一项服事。
///
/// [ranking] 只在有人拖过顺序时才有值：候选名单里名单上的同工由前到后，要
/// 存成这个服事项目的同工排序。没拖过就是 null，不必写排序。
typedef _PeopleSelection = ({
  String role,
  List<String> people,
  StaffRanking? ranking,
  Map<String, String> personIdsByName,
});

class _PeopleOptions {
  final List<String> options;
  final Set<String> allUserNames;
  final Map<String, String> userIdsByName;

  const _PeopleOptions({
    required this.options,
    required this.allUserNames,
    required this.userIdsByName,
  });
}

// ---------------------------------------------------------------------------
// _RosterPeopleDialog
// ---------------------------------------------------------------------------

class _RosterPeopleDialog extends StatefulWidget {
  final String title;
  final ServiceType rosterType;
  final String? initialRoleText;
  final List<String> roleOptions;
  final String? initialRole;

  /// 候选名单，已经照同工排序排好（见 [RosterProvider.staffOrderFor]）。
  final Future<_PeopleOptions> Function(String? role) peopleLoader;
  final List<String> initialPeople;
  final Map<String, String> initialPersonIdsByName;

  final void Function(_PeopleSelection selection) onSubmit;
  final String submitLabel;
  final bool roleEditable;
  final bool useBottomSheet;

  /// 有值时，视窗里会多一颗「与其他日期交换」。编辑既有服事项目才给 ——
  /// 还不存在的项目没有东西可以拿去换。
  final VoidCallback? onSwap;

  const _RosterPeopleDialog({
    required this.title,
    required this.rosterType,
    this.initialRoleText,
    required this.roleOptions,
    required this.initialRole,
    required this.peopleLoader,
    required this.initialPeople,
    this.initialPersonIdsByName = const {},
    required this.onSubmit,
    required this.submitLabel,
    this.roleEditable = true,
    this.useBottomSheet = false,
    this.onSwap,
  });

  @override
  State<_RosterPeopleDialog> createState() => _RosterPeopleDialogState();
}

class _RosterPeopleDialogState extends State<_RosterPeopleDialog> {
  late Set<String> _selectedPeople;
  late Set<String> _customNames;
  final Set<String> _removedCustomNames = {};
  List<String> _options = const [placeholderPerson];
  bool _optionsInitialized = false;

  /// 拖过顺序了吗。拖曳改的是这个服事项目在每一周的顺序，不只这一天。
  bool _orderChanged = false;
  Set<String> _allUserNames = const {};
  Map<String, String> _userIdsByName = const {};
  String? _selectedRole;
  late Future<_PeopleOptions> _peopleFuture;
  late final TextEditingController _customController;
  late final TextEditingController _roleController;
  late final ScrollController _peopleScrollController;

  @override
  void initState() {
    super.initState();
    _customController = TextEditingController();
    _roleController = TextEditingController(text: widget.initialRoleText ?? '');
    _peopleScrollController = ScrollController();
    _selectedPeople = widget.initialPeople
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet();
    if (_selectedPeople.isEmpty) {
      _selectedPeople = {placeholderPerson};
    }
    _customNames = widget.initialPeople
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty && e != placeholderPerson)
        .toSet();
    _selectedRole = widget.initialRole;
    _peopleFuture = widget.peopleLoader(_selectedRole);
    _initialSelection = Set<String>.from(_selectedPeople);
  }

  /// 进场时勾了谁。按「与其他日期交换」会关掉这张视窗，关掉之前要拿它比对
  /// 有没有还没存的改动。
  late final Set<String> _initialSelection;

  /// 勾选或顺序跟进场时不一样了吗。
  bool get _hasUnsavedChanges {
    // 名单还没载进来时 _options 只有一个「待定」，这时候算出来的勾选一定跟
    // 进场时不一样，会误判成「改过」而多跳一次确认。
    if (!_optionsInitialized) return false;
    final selected = _buildSelectedPeople(_options);
    // 「没有人」在 _buildSelectedPeople 会被补成 ['待定']，而 _initialSelection
    // 是原始勾选（可能是空的），两边都先把占位符拿掉才比得准。
    final selectedSet = selected.where((n) => n != placeholderPerson).toSet();
    final initialSet = _initialSelection
        .where((n) => n != placeholderPerson)
        .toSet();
    if (!setEquals(selectedSet, initialSet)) return true;
    return _orderChanged;
  }

  /// 未存的改动要被丢掉时先问一声。交换会重写这一项的人，带不过去。
  Future<bool> _confirmDiscardChanges() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('尚未储存'),
        content: const Text('这里改的人员还没储存，去交换会丢掉这些改动。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('留在这里'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('丢掉并交换'),
          ),
        ],
      ),
    );
    return discard == true;
  }

  @override
  void dispose() {
    _customController.dispose();
    _roleController.dispose();
    _peopleScrollController.dispose();
    super.dispose();
  }

  void _toggleSelection(String name) {
    setState(() {
      if (_selectedPeople.contains(name)) {
        _selectedPeople.remove(name);
      } else {
        _selectedPeople.add(name);
      }

      if (name == placeholderPerson &&
          _selectedPeople.contains(placeholderPerson)) {
        _selectedPeople
          ..clear()
          ..add(placeholderPerson);
      } else if (_selectedPeople.length > 1 &&
          _selectedPeople.contains(placeholderPerson)) {
        _selectedPeople.remove(placeholderPerson);
      }

      if (_selectedPeople.isEmpty) {
        _selectedPeople.add(placeholderPerson);
      }
    });
  }

  void _addCustomName([String? raw]) {
    final name = (raw ?? _customController.text).trim();
    if (name.isEmpty) return;
    setState(() {
      if (name == placeholderPerson) {
        _selectedPeople
          ..clear()
          ..add(placeholderPerson);
      } else {
        _selectedPeople.add(name);
        _customNames.add(name);
        _selectedPeople.remove(placeholderPerson);
      }
    });
    _customController.clear();
  }

  void _removeCustomName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    setState(() {
      _customNames.remove(trimmed);
      _selectedPeople.remove(trimmed);
      _removedCustomNames.add(trimmed);
      _options = _options.where((option) => option != trimmed).toList();
      if (_selectedPeople.isEmpty) {
        _selectedPeople.add(placeholderPerson);
      }
    });
  }

  Future<void> _removeCustomNameAcrossRosters(String name, String role) async {
    final trimmed = name.trim();
    final roleKey = role.trim();
    if (trimmed.isEmpty || roleKey.isEmpty) return;
    final provider = context.read<RosterProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final updates = <ServiceRoster>[];
    for (final roster in provider.getRostersByType(widget.rosterType)) {
      var changed = false;
      final updatedDuties = roster.duties.map((duty) {
        if (duty.role.trim() != roleKey) return duty;
        if (!duty.people.contains(trimmed)) return duty;
        final people = duty.people.where((p) => p != trimmed).toList();
        final personIdsByName = Map<String, String>.from(duty.personIdsByName)
          ..remove(trimmed);
        changed = true;
        if (people.isEmpty) {
          return duty.copyWith(
            people: const [placeholderPerson],
            personIdsByName: personIdsByName,
          );
        }
        return duty.copyWith(people: people, personIdsByName: personIdsByName);
      }).toList();
      if (changed) updates.add(roster.copyWith(duties: updatedDuties));
    }
    // 一次送出而不是逐笔 await：逐笔的话中间一笔失败，后面几天就默默没改。
    // updateRosters 会把成功的先写回画面，再把失败的报上来。
    try {
      await provider.updateRosters(updates);
    } catch (e) {
      showWriteFailure(messenger, '删除', e);
    }
  }

  Future<void> _confirmRemoveCustomName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除「$trimmed」吗？'),
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
      final role = (_selectedRole ?? widget.initialRole ?? '').trim();
      _removeCustomName(trimmed);
      await _removeCustomNameAcrossRosters(trimmed, role);
    }
  }

  Future<void> _showCustomInputSheet() async {
    _customController.clear();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SettingsBottomSheet(
          title: '新增名单以外的人员',
          submitLabel: '加入',
          onSubmit: () {
            _addCustomName();
            Navigator.of(context).pop();
          },
          child: TextField(
            controller: _customController,
            decoration: InputDecoration(
              hintText: '例：外请讲员',
              isDense: true,
              filled: true,
              fillColor: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
              hintStyle: TextStyle(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.35),
              ),
            ),
            textInputAction: TextInputAction.done,
            onSubmitted: (value) {
              _addCustomName(value);
              Navigator.of(context).pop();
            },
          ),
        );
      },
    );
  }

  List<String> _buildSelectedPeople(List<String> options) {
    final selected = options.where(_selectedPeople.contains).toList();
    if (selected.isEmpty) {
      return [placeholderPerson];
    }
    return selected;
  }

  List<String> _mergeOptions(List<String> baseOptions) {
    final merged = <String>{};
    for (final name in baseOptions) {
      final trimmed = name.trim();
      if (trimmed.isNotEmpty) merged.add(trimmed);
    }
    for (final name in _selectedPeople) {
      final trimmed = name.trim();
      if (trimmed.isNotEmpty) merged.add(trimmed);
    }
    for (final name in _customNames) {
      final trimmed = name.trim();
      if (trimmed.isNotEmpty) merged.add(trimmed);
    }
    final result = <String>[];
    if (merged.contains(placeholderPerson) ||
        baseOptions.contains(placeholderPerson)) {
      result.add(placeholderPerson);
    }
    final baseOrdered = baseOptions
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty && name != placeholderPerson)
        .toList();
    final baseSet = baseOrdered.toSet();
    result.addAll(baseOrdered);

    merged.remove(placeholderPerson);
    final remaining = merged.where((name) => !baseSet.contains(name)).toList()
      ..sort();
    result.addAll(remaining);
    return result;
  }

  void _syncOptions(List<String> baseOptions) {
    if (!_optionsInitialized) {
      _options = _mergeOptions(baseOptions);
      _optionsInitialized = true;
      return;
    }

    final merged = _mergeOptions(baseOptions).toSet();
    _options = _options.where(merged.contains).toList();
    final existing = _options.toSet();
    final missing = merged.where((name) => !existing.contains(name)).toList()
      ..sort();
    if (missing.isNotEmpty) {
      _options = [..._options, ...missing];
    }
  }

  bool _isRankable(String name) =>
      name != placeholderPerson && _allUserNames.contains(name);

  void _submit() {
    final role = widget.roleEditable
        ? (_selectedRole ?? '').trim()
        : _roleController.text.trim();
    if (role.isEmpty) return;
    final selected = _buildSelectedPeople(_options);
    final selectedPersonIdsByName = <String, String>{};
    for (final name in selected) {
      final uid = _userIdsByName[name];
      if (uid == null || uid.trim().isEmpty) continue;
      selectedPersonIdsByName[name] = uid;
    }
    widget.onSubmit((
      role: role,
      people: selected,
      // 只收名单上的同工：外请讲员这类名字写进固定排序的话，之后新加入的
      // 同工都会排在他们后面。他们本来就拖不动（见 onReorder）。
      ranking: _orderChanged
          ? StaffRanking(role, _options.where(_allUserNames.contains).toList())
          : null,
      personIdsByName: selectedPersonIdsByName,
    ));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final canSelectRole = widget.roleEditable && widget.roleOptions.isNotEmpty;
    final roleMissing = widget.roleEditable && widget.roleOptions.isEmpty;
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!widget.roleEditable)
          TextField(
            controller: _roleController,
            decoration: const InputDecoration(labelText: '职位名称'),
            enabled: false,
          ),
        if (canSelectRole)
          DropdownButtonFormField<String>(
            initialValue: _selectedRole,
            decoration: const InputDecoration(labelText: '服事项目'),
            items: widget.roleOptions.map((role) {
              return DropdownMenuItem(value: role, child: Text(role));
            }).toList(),
            onChanged: (value) {
              if (value != null) {
                setState(() {
                  _selectedRole = value;
                  _peopleFuture = widget.peopleLoader(_selectedRole);
                  // 换了服事项目就换了一份排序，前一项拖过的顺序不能带过来。
                  _optionsInitialized = false;
                  _orderChanged = false;
                });
              }
            },
          ),
        if (roleMissing)
          Builder(
            builder: (context) => Text(
              '请先按右上角中间的清单图示「服事项目设定」新增项目',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        // 换班的入口。原本是服事列上的一颗 ⇄，但那颗占掉的 44px 让名字栏只
        // 剩 142px，三个名字就被挤成两行 —— 名字才是这个画面天天在看的东西。
        if (widget.onSwap != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () async {
                if (_hasUnsavedChanges && !await _confirmDiscardChanges()) {
                  return;
                }
                if (!mounted) return;
                // 先关掉这张 sheet：两张叠著的话，换完回来的还是旧资料。
                Navigator.of(this.context).pop();
                widget.onSwap!();
              },
              icon: const Icon(Icons.swap_horiz, size: 18),
              label: const Text('与其他日期交换'),
            ),
          ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '选择同工（拖曳排序会套用到每一周）',
            style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 280,
          child: FutureBuilder<_PeopleOptions>(
            future: _peopleFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return Center(child: Text('载入同工名单失败: ${snapshot.error}'));
              }

              final data = snapshot.data;
              _syncOptions(data?.options ?? const [placeholderPerson]);
              if (_removedCustomNames.isNotEmpty) {
                _options = _options
                    .where((name) => !_removedCustomNames.contains(name))
                    .toList();
              }
              _allUserNames = data?.allUserNames ?? const {};
              _userIdsByName = {
                ...widget.initialPersonIdsByName,
                ...(data?.userIdsByName ?? const <String, String>{}),
              };
              final list = Scrollbar(
                controller: _peopleScrollController,
                thumbVisibility: true,
                trackVisibility: true,
                child: ReorderableListView.builder(
                  scrollController: _peopleScrollController,
                  itemCount: _options.length,
                  buildDefaultDragHandles: true,
                  onReorder: (oldIndex, newIndex) {
                    final name = _options[oldIndex];
                    // 待定与名单外的人不进固定排序，拖了也存不起来，干脆
                    // 不给拖 —— 否则画面上排好的位置存完就跳回去。
                    if (!_isRankable(name)) return;
                    setState(() {
                      if (newIndex > oldIndex) {
                        newIndex -= 1;
                      }
                      final moved = _options.removeAt(oldIndex);
                      _options.insert(newIndex, moved);
                      _orderChanged = true;
                    });
                  },
                  itemBuilder: (context, index) {
                    final name = _options[index];
                    final checked = _selectedPeople.contains(name);
                    final isCustom =
                        name != placeholderPerson &&
                        !_allUserNames.contains(name);
                    final canDrag = _isRankable(name);
                    return CheckboxListTile(
                      key: ValueKey('option-$name'),
                      title: Text(name),
                      value: checked,
                      onChanged: (_) => _toggleSelection(name),
                      secondary: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isCustom)
                            IconButton(
                              tooltip: '删除自订项目',
                              constraints: const BoxConstraints(
                                minWidth: 48,
                                minHeight: 48,
                              ),
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () => _confirmRemoveCustomName(name),
                            ),
                          Icon(
                            Icons.drag_handle,
                            size: 18,
                            color: canDrag
                                ? Colors.grey.shade700
                                : Colors.grey.shade300,
                          ),
                        ],
                      ),
                      controlAffinity: ListTileControlAffinity.leading,
                      dense: true,
                    );
                  },
                ),
              );
              // 只剩「待定」时，新手看不出是哪个设定没做，直接说要去哪里勾。
              final hasCandidates = (data?.options ?? const <String>[]).any(
                (name) => name != placeholderPerson,
              );
              if (hasCandidates) return list;
              final role = _selectedRole?.trim() ?? '';
              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      role.isEmpty
                          ? '先选择服事项目，才会列出可以排的同工。'
                          : '还没有同工可排「$role」。请到「我的」→「帐号管理」编辑同工，'
                                '在「${widget.rosterType.label}」牧区的「参与服事」'
                                '勾选「$role」，他就会出现在这里。',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  Expanded(child: list),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _showCustomInputSheet,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('新增名单以外的人员'),
          ),
        ),
      ],
    );

    final actions = Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: roleMissing ? null : _submit,
          child: Text(widget.submitLabel),
        ),
      ],
    );

    if (widget.useBottomSheet) {
      final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
      final maxHeight = MediaQuery.sizeOf(context).height * 0.85;
      return Padding(
        padding: EdgeInsets.fromLTRB(16, 12, 16, 16 + bottomInset),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  widget.title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              const SizedBox(height: 8),
              const Divider(height: 1),
              const SizedBox(height: 12),
              Flexible(
                fit: FlexFit.loose,
                child: SingleChildScrollView(child: content),
              ),
              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 8),
              actions,
            ],
          ),
        ),
      );
    }

    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(width: double.maxFinite, child: content),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: roleMissing ? null : _submit,
          child: Text(widget.submitLabel),
        ),
      ],
    );
  }
}
