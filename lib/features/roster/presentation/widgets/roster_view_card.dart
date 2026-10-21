import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../domain/entities/service_roster.dart';
import 'duty_row.dart';

class RosterViewCard extends StatelessWidget {
  final ServiceRoster roster;
  final bool initiallyExpanded;
  final int Function(ServiceRoster roster, String event) resolveEventColor;

  const RosterViewCard({
    super.key,
    required this.roster,
    required this.resolveEventColor,
    this.initiallyExpanded = false,
  });

  static final _dateFormat = DateFormat('yyyy/MM/dd (EEEEE)', 'zh_TW');

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      elevation: 2.0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ExpansionTile(
        key: PageStorageKey(roster.id),
        initiallyExpanded: initiallyExpanded,
        leading: Icon(
          Icons.event_note,
          color: Theme.of(context).colorScheme.primary,
        ),
        title: Text(
          _dateFormat.format(roster.date),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(roster.displayName),
            if (roster.specialEvents.isNotEmpty) const SizedBox(width: 8),
            if (roster.specialEvents.isNotEmpty)
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 2,
                  children: [
                    ...roster.specialEvents.map((event) {
                      final color = Color(resolveEventColor(roster, event));
                      return Chip(
                        label: Text(
                          event,
                          style: TextStyle(
                            color: color,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
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
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      );
                    }),
                  ],
                ),
              ),
          ],
        ),
        // 收合状态下 ExpansionTile 会把 body 从树上移除，所以独立成 widget
        // 之后，看不到的服事列表就不会被 build。卷动时每张卡片只配置一个
        // widget 物件，而不是十几列 Row/Text。
        children: [_RosterViewCardBody(roster: roster)],
      ),
    );
  }
}

/// [RosterViewCard] 展开后的服事项目列表。
class _RosterViewCardBody extends StatelessWidget {
  const _RosterViewCardBody({required this.roster});

  final ServiceRoster roster;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        children: roster.duties.map((duty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            // dense：这里没有按钮要撑触控目标，列高就跟著文字走，一页多看
            // 得到几天。切换模式时的位移是靠锚定日期修的（见 [ScrollAnchor]），
            // 不必为此把检视模式撑到跟编辑模式一样高。
            child: DutyRow(role: duty.role, people: duty.people, dense: true),
          );
        }).toList(),
      ),
    );
  }
}
