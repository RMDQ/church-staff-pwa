import 'dart:developer';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../domain/entities/event_option.dart';
import '../../domain/entities/service_roster.dart';
import 'package:church_staff_pwa/core/types/service_type.dart';
import '../../../auth/presentation/providers/user_admin_provider.dart';
import '../providers/roster_provider.dart';
import '../../../../core/utils/error_messages.dart';
import '../../../../core/widgets/settings_bottom_sheet.dart';
import '../write_failure.dart';
import 'duty_row.dart';
import '../../domain/staff_directory.dart';
import '../../domain/staff_order.dart';
import 'event_color_picker.dart';

part '_roster_people_dialog.dart';
part '_special_event_dialog.dart';
part '_swap_duty_dialog.dart';

/// 写一张服事表。失败时就地跳 snackbar，不动整页 —— provider 的写入失败
/// 一律往上丢（见 [RosterProvider.updateRoster]），不会变成整页的错误画面。
///
/// [ranking] 是选人视窗里拖过的顺序，provider 会先存它再存这一天。
Future<void> _saveRoster(
  BuildContext context,
  ServiceRoster roster, {
  StaffRanking? ranking,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await context.read<RosterProvider>().updateRoster(roster, ranking: ranking);
  } catch (e) {
    showWriteFailure(messenger, '更新', e);
  }
}

class RosterCard extends StatelessWidget {
  static final _dateFormat = DateFormat('yyyy/MM/dd (EEEEE)', 'zh_TW');

  final ServiceRoster roster;
  final bool initiallyExpanded;

  const RosterCard({
    super.key,
    required this.roster,
    this.initiallyExpanded = false,
  });

  @override
  Widget build(BuildContext context) {
    // 只订阅 isEditMode。用 watch() 订阅整个 provider 的话，任何一次
    // notifyListeners（背景 refetch 的 loading 开关、其他日期被编辑…）
    // 都会重建画面上每一张卡片。
    final isEditMode = context.select<RosterProvider, bool>(
      (provider) => provider.isEditMode,
    );
    // 事件标签颜色是从 provider 查的（不存在 roster 里），所以选项换过时
    // 这张卡片也要重建。订阅版本号即可，不必订阅整个 provider。
    context.select<RosterProvider, int>(
      (provider) => provider.eventOptionsRevision,
    );
    final rosterProvider = context.read<RosterProvider>();

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      elevation: isEditMode ? 4.0 : 2.0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isEditMode
            ? BorderSide(
                color: Theme.of(context).colorScheme.primary,
                width: 2.0,
              )
            : BorderSide.none,
      ),
      child: ExpansionTile(
        key: PageStorageKey(roster.id),
        initiallyExpanded: initiallyExpanded,
        leading: Icon(
          isEditMode ? Icons.edit_note : Icons.event_note,
          color: isEditMode
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.primary,
        ),
        title: Text(
          _dateFormat.format(roster.date),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(roster.displayName),
            if (roster.specialEvents.isNotEmpty || isEditMode)
              const SizedBox(width: 8),
            if (roster.specialEvents.isNotEmpty || isEditMode)
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 2,
                  children: [
                    ...roster.specialEvents.map((event) {
                      final color = Color(
                        rosterProvider.eventColorOf(roster, event),
                      );
                      final label = Text(
                        event,
                        style: TextStyle(
                          color: color,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      );
                      if (!isEditMode) {
                        return Chip(
                          label: label,
                          backgroundColor: color.withValues(alpha: 0.12),
                          side: BorderSide(color: color.withValues(alpha: 0.4)),
                          padding: EdgeInsets.zero,
                          labelPadding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 0,
                          ),
                          visualDensity: const VisualDensity(
                            horizontal: -2,
                            vertical: -3,
                          ),
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        );
                      }
                      return InputChip(
                        label: label,
                        backgroundColor: color.withValues(alpha: 0.12),
                        side: BorderSide(color: color.withValues(alpha: 0.4)),
                        onDeleted: () =>
                            _confirmRemoveSpecialEvent(context, event),
                        deleteIcon: const Icon(Icons.close, size: 16),
                        padding: EdgeInsets.zero,
                        labelPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 0,
                        ),
                        visualDensity: const VisualDensity(
                          horizontal: -2,
                          vertical: -3,
                        ),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      );
                    }),
                    if (isEditMode)
                      ActionChip(
                        label: const Text('新增事件'),
                        onPressed: () => _showAddSpecialEventDialog(context),
                        padding: EdgeInsets.zero,
                        labelPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 0,
                        ),
                        visualDensity: const VisualDensity(
                          horizontal: -2,
                          vertical: -3,
                        ),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        labelStyle: TextStyle(
                          color: Colors.orange[800],
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
        trailing: isEditMode ? const Icon(Icons.drag_handle) : null,
        // 服事项目列表放在独立 widget 里。ExpansionTile 收合完成后会把 body
        // 整个从树上拿掉，所以收合状态下这些列根本不会被 build —— 卷动时
        // 每张卡片只配置一个 widget，而不是十几列 Row/Text/IconButton。
        children: [_RosterCardBody(card: this, isEditMode: isEditMode)],
      ),
    );
  }

  Future<void> _showAddDutyDialog(BuildContext context) async {
    Future<_PeopleOptions> peopleLoader(String? role) =>
        _loadSelectablePeople(context, roster.type, const [], role);
    final roleOptions =
        context.read<RosterProvider>().templates[roster.type] ??
        const <String>[];

    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return _RosterPeopleDialog(
          title: '新增服事项目',
          rosterType: roster.type,
          roleOptions: roleOptions,
          initialRole: roleOptions.isNotEmpty ? roleOptions.first : null,
          peopleLoader: peopleLoader,
          initialPeople: const [placeholderPerson],
          initialPersonIdsByName: const {},
          onSubmit: (selection) => _addDuty(context, selection),
          submitLabel: '新增',
          useBottomSheet: true,
        );
      },
    );
  }

  void _addDuty(BuildContext context, _PeopleSelection selection) {
    final newDuties = List<RosterEntry>.from(roster.duties);
    newDuties.add(
      RosterEntry(
        role: selection.role,
        people: selection.people,
        personIdsByName: selection.personIdsByName,
      ),
    );

    final newRoster = roster.copyWith(duties: newDuties);
    _saveRoster(context, newRoster, ranking: selection.ranking);
  }

  void _removeDuty(BuildContext context, int index) {
    final newDuties = List<RosterEntry>.from(roster.duties);
    newDuties.removeAt(index);

    final newRoster = roster.copyWith(duties: newDuties);
    _saveRoster(context, newRoster);
  }

  Future<void> _confirmRemoveDuty(
    BuildContext context,
    int index,
    String role,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除「$role」吗？'),
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

    if (!context.mounted) return;
    if (confirmed == true) {
      _removeDuty(context, index);
    }
  }

  /// 开启交换 sheet。
  ///
  /// 候选人只找同一个牧区、同一个服事项目 —— 跨项目的调动（破冰换成敬拜主领）
  /// 不是交换而是重排，走原本的编辑流程比较不会换到对方没受训的项目上。
  ///
  /// 已经排在这一天同一个项目里的人会先滤掉：换过来只会让同一天出现两次同名，
  /// 而且对方那天反而少一个人。
  Future<void> _showSwapDutyDialog(
    BuildContext context,
    int index,
    RosterEntry duty,
  ) async {
    // 从编辑视窗按进来时这张卡片可能已经不在树上（例如那天被删掉），
    // read 之前先问，否则丢的是 ProviderNotFound 而不是安静地不做事。
    if (!context.mounted) return;
    final provider = context.read<RosterProvider>();
    final role = duty.role.trim();
    final alreadyHere = duty.people.map((p) => p.trim()).toSet();

    final candidates = <_SwapCandidate>[];
    for (final other in provider.getRostersByType(roster.type)) {
      if (other.id == roster.id) continue;
      for (var i = 0; i < other.duties.length; i++) {
        final otherDuty = other.duties[i];
        if (otherDuty.role.trim() != role) continue;
        final people = otherDuty.people.isEmpty
            ? const [placeholderPerson]
            : otherDuty.people;
        for (final person in people) {
          if (alreadyHere.contains(person.trim())) continue;
          candidates.add(
            _SwapCandidate(roster: other, dutyIndex: i, person: person),
          );
        }
      }
    }

    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => _SwapDutyDialog(
        roster: roster,
        dutyIndex: index,
        duty: duty,
        candidates: candidates,
      ),
    );
  }

  Future<void> _showEditDialog(
    BuildContext context,
    int index,
    RosterEntry duty,
  ) async {
    Future<_PeopleOptions> peopleLoader(String? role) => _loadSelectablePeople(
      context,
      roster.type,
      duty.people,
      role ?? duty.role,
    );

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      // 参数改名为 sheetContext，让底下的 onSwap 明确地闭包在卡片的 context 上
      // 而不是这张 sheet 的 —— sheet 被 pop 掉之后才轮到 onSwap 执行。
      builder: (sheetContext) {
        return _RosterPeopleDialog(
          title: '编辑 ${duty.role}',
          rosterType: roster.type,
          initialRoleText: duty.role,
          roleOptions: const [],
          initialRole: duty.role,
          peopleLoader: peopleLoader,
          initialPeople: duty.people.isEmpty
              ? const [placeholderPerson]
              : duty.people,
          initialPersonIdsByName: duty.personIdsByName,
          onSubmit: (selection) => _updateDuty(context, index, selection),
          submitLabel: '储存',
          roleEditable: false,
          useBottomSheet: true,
          onSwap: () => _showSwapDutyDialog(context, index, duty),
        );
      },
    );
  }

  void _updateDuty(
    BuildContext context,
    int index,
    _PeopleSelection selection,
  ) {
    final newDuties = List<RosterEntry>.from(roster.duties);
    newDuties[index] = newDuties[index].copyWith(
      people: selection.people,
      personIdsByName: selection.personIdsByName,
    );

    final newRoster = roster.copyWith(duties: newDuties);
    _saveRoster(context, newRoster, ranking: selection.ranking);
  }

  Future<void> _showAddSpecialEventDialog(BuildContext context) async {
    final provider = context.read<RosterProvider>();
    final existing = roster.specialEvents.toSet();
    final options = provider
        .eventOptionsFor(roster.type)
        .where((e) => e.name.trim().isNotEmpty)
        .toList();

    final result = await showDialog<_SpecialEventDialogResult>(
      context: context,
      builder: (context) =>
          _SpecialEventDialog(options: options, existing: existing),
    );

    if (!context.mounted) return;
    if (result == null || result.events.isEmpty) return;
    final events = List<String>.from(roster.specialEvents);
    for (final event in result.events) {
      if (!events.contains(event)) {
        events.add(event);
      }
    }
    final mergedColors = {...roster.customEventColors, ...result.customColors};
    _saveRoster(
      context,
      roster.copyWith(specialEvents: events, customEventColors: mergedColors),
    );
  }

  void _removeSpecialEvent(BuildContext context, String event) {
    final events = List<String>.from(roster.specialEvents)..remove(event);
    final colors = Map<String, int>.from(roster.customEventColors)
      ..remove(event);
    _saveRoster(
      context,
      roster.copyWith(specialEvents: events, customEventColors: colors),
    );
  }

  Future<void> _confirmRemoveSpecialEvent(
    BuildContext context,
    String event,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除「$event」吗？'),
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

    if (!context.mounted) return;
    if (confirmed == true) {
      _removeSpecialEvent(context, event);
    }
  }

  Future<_PeopleOptions> _loadSelectablePeople(
    BuildContext context,
    ServiceType rosterType,
    List<String> extras,
    String? role,
  ) async {
    final provider = context.read<RosterProvider>();
    final staff = StaffDirectory.fromUsers(
      await context.read<UserAdminProvider>().getUsers(),
      rosterType,
    );
    final roleKey = role?.trim() ?? '';
    final extrasSet = extras
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet();
    final rosterPeople = roleKey.isEmpty
        ? <String>{}
        : provider
              .getRostersByType(rosterType)
              .expand((roster) => roster.duties)
              .where((duty) => duty.role.trim() == roleKey)
              .expand((duty) => duty.people)
              .map((name) => name.trim())
              .where((name) => name.isNotEmpty && name != placeholderPerson)
              .toSet();
    final names = roleKey.isEmpty
        ? const <String>[]
        : staff.namesForRole(roleKey);
    final Set<String> merged = {...names, ...rosterPeople, ...extrasSet};
    final List<String> result = [placeholderPerson];
    // 照同工排序排：视窗里的先后就是这一项服事每一周的先后，拖曳改的也是它。
    result.addAll(
      provider
          .staffOrderFor(rosterType)
          .sort(
            roleKey,
            merged.where((name) => name != placeholderPerson).toList(),
          ),
    );
    return _PeopleOptions(
      options: result,
      allUserNames: staff.names.toSet(),
      userIdsByName: staff.idByName,
    );
  }
}

/// [RosterCard] 展开后的服事项目列表。
///
/// 刻意独立成一个 widget：留在 RosterCard.build 里的话，即使卡片是收合的，
/// 每次 rebuild 仍然要配置整棵列表的 widget 物件。
class _RosterCardBody extends StatelessWidget {
  const _RosterCardBody({required this.card, required this.isEditMode});

  final RosterCard card;
  final bool isEditMode;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final roster = card.roster;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        children: [
          ...roster.duties.asMap().entries.map((entry) {
            final int index = entry.key;
            final RosterEntry duty = entry.value;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: InkWell(
                onTap: isEditMode
                    ? () => card._showEditDialog(context, index, duty)
                    : null,
                borderRadius: BorderRadius.circular(8),
                splashColor: colorScheme.primary.withValues(alpha: 0.08),
                highlightColor: colorScheme.primary.withValues(alpha: 0.04),
                child: DutyRow(
                  role: duty.role,
                  people: duty.people,
                  roleColor: Colors.grey[700],
                  trailing: [
                    if (isEditMode)
                      IconButton(
                        tooltip: '删除服事项目',
                        constraints: const BoxConstraints(
                          minWidth: 44,
                          minHeight: kDutyRowMinHeight,
                        ),
                        icon: Icon(
                          Icons.delete_outline,
                          size: 20,
                          color: colorScheme.error,
                        ),
                        onPressed: () =>
                            card._confirmRemoveDuty(context, index, duty.role),
                      ),
                  ],
                ),
              ),
            );
          }),
          if (isEditMode)
            Padding(
              padding: const EdgeInsets.only(top: 8.0),
              child: TextButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('新增服事项目'),
                onPressed: () => card._showAddDutyDialog(context),
              ),
            ),
        ],
      ),
    );
  }
}
