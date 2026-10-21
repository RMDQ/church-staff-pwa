part of 'roster_card.dart';

// ---------------------------------------------------------------------------
// 交换服事
//
// 换班在教会里是最常见的异动（「1/1 的破冰跟 1/8 换一下」），但在编辑画面上
// 它原本要拆成两次独立的编辑：找到 1/1、取消勾自己、勾对方、存档，再卷到
// 1/8 反过来做一次。中间任一步失败，就会留下一个人被排两天、另一个人的那天
// 空著的状态。
//
// 这个 sheet 把它压成一次操作，并且交给 [RosterProvider.swapDutyPeople] 以
// 单一 batch 写入 —— 要嘛两天都换好，要嘛两天都没动。
// ---------------------------------------------------------------------------

/// 一个可以换过去的对象：某一天、某个服事项目上的某个人。
///
/// 刻意摊平到「人」这一层而不是「那一天」：一个项目上可能排了两个人，若以天
/// 为单位，使用者选完日期还要再选一次人。摊平之后清单直接就是可选的结果。
class _SwapCandidate {
  final ServiceRoster roster;
  final int dutyIndex;
  final String person;

  const _SwapCandidate({
    required this.roster,
    required this.dutyIndex,
    required this.person,
  });
}

class _SwapDutyDialog extends StatefulWidget {
  final ServiceRoster roster;
  final int dutyIndex;
  final RosterEntry duty;
  final List<_SwapCandidate> candidates;

  const _SwapDutyDialog({
    required this.roster,
    required this.dutyIndex,
    required this.duty,
    required this.candidates,
  });

  @override
  State<_SwapDutyDialog> createState() => _SwapDutyDialogState();
}

class _SwapDutyDialogState extends State<_SwapDutyDialog> {
  static final _shortDateFormat = DateFormat('MM/dd (EEEEE)', 'zh_TW');

  late String _sourcePerson;
  int? _selectedIndex;
  bool _isSubmitting = false;
  String? _errorText;

  List<String> get _sourcePeople => widget.duty.people.isEmpty
      ? const [placeholderPerson]
      : widget.duty.people;

  /// 可选的对象，滤掉「那一天的同一项已经有 [_sourcePerson]」的选项。
  ///
  /// 换过去会让对方那天出现两次同名，去重之后吃掉一个 —— 结果是那天平白少
  /// 一个人。候选清单建立时只滤得掉「来源这天已经有的人」，反方向要等使用者
  /// 选定要换谁才知道，所以滤在这里，并随 [_sourcePerson] 改变。
  List<_SwapCandidate> get _visibleCandidates {
    final source = _sourcePerson.trim();
    return widget.candidates.where((candidate) {
      final duty = candidate.roster.duties[candidate.dutyIndex];
      return !duty.people.any((person) => person.trim() == source);
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    _sourcePerson = _sourcePeople.first;
  }

  Future<void> _submit() async {
    final index = _selectedIndex;
    final candidates = _visibleCandidates;
    if (index == null || index >= candidates.length) return;
    final target = candidates[index];

    setState(() {
      _isSubmitting = true;
      _errorText = null;
    });

    final messenger = ScaffoldMessenger.of(context);
    final summary =
        '${_shortDateFormat.format(widget.roster.date)} $_sourcePerson'
        ' ⇄ '
        '${_shortDateFormat.format(target.roster.date)} ${target.person}';

    try {
      await context.read<RosterProvider>().swapDutyPeople(
        sourceRosterId: widget.roster.id,
        sourceDutyIndex: widget.dutyIndex,
        sourcePerson: _sourcePerson,
        targetRosterId: target.roster.id,
        targetDutyIndex: target.dutyIndex,
        targetPerson: target.person,
      );
    } catch (e, st) {
      log('交换服事失败', error: e, stackTrace: st);
      if (!mounted) return;
      // 留在 sheet 上显示错误，不 pop：关掉之后使用者得从头再选一次日期。
      setState(() {
        _isSubmitting = false;
        _errorText = '交换失败：${mapErrorToUserMessage(e)}';
      });
      return;
    }

    if (!mounted) return;
    Navigator.of(context).pop();
    messenger.showSnackBar(SnackBar(content: Text('已交换：$summary')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final role = widget.duty.role;
    final candidates = _visibleCandidates;
    final hasCandidates = candidates.isNotEmpty;

    return SettingsBottomSheet(
      title: '交换服事',
      submitLabel: '交换',
      isSubmitting: _isSubmitting,
      onSubmit: (!hasCandidates || _selectedIndex == null || _isSubmitting)
          ? null
          : _submit,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${RosterCard._dateFormat.format(widget.roster.date)} · $role',
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 12),
          // 一个项目只排一个人时不必问「要换谁」—— 那颗 chip 没有第二个选项，
          // 只是多一行要读的东西。
          if (_sourcePeople.length > 1) ...[
            Text(
              '要换谁',
              style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: _sourcePeople.map((person) {
                return ChoiceChip(
                  label: Text(person),
                  selected: _sourcePerson == person,
                  onSelected: _isSubmitting
                      ? null
                      // 换了要换的人，可选对象也跟著变，旧的选取索引指到别人。
                      : (_) => setState(() {
                          _sourcePerson = person;
                          _selectedIndex = null;
                        }),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
          ],
          Text(
            '换到哪一天的「$role」',
            style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
          ),
          const SizedBox(height: 6),
          if (!hasCandidates)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                '其他日期没有可以交换的「$role」',
                style: TextStyle(color: theme.colorScheme.error),
              ),
            )
          else
            SizedBox(
              height: 280,
              child: ListView.builder(
                itemCount: candidates.length,
                itemBuilder: (context, index) {
                  final candidate = candidates[index];
                  final selected = _selectedIndex == index;
                  return ListTile(
                    dense: true,
                    selected: selected,
                    leading: Icon(
                      selected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 20,
                      color: selected
                          ? theme.colorScheme.primary
                          : Colors.grey.shade500,
                    ),
                    title: Text(_shortDateFormat.format(candidate.roster.date)),
                    trailing: Text(
                      candidate.person,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    onTap: _isSubmitting
                        ? null
                        : () => setState(() => _selectedIndex = index),
                  );
                },
              ),
            ),
          if (_selectedIndex != null &&
              _selectedIndex! < candidates.length) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${_shortDateFormat.format(widget.roster.date)} $_sourcePerson'
                '   ⇄   '
                '${_shortDateFormat.format(candidates[_selectedIndex!].roster.date)}'
                ' ${candidates[_selectedIndex!].person}',
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
          if (_errorText != null) ...[
            const SizedBox(height: 8),
            Text(
              _errorText!,
              style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}
