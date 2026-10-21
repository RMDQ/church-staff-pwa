import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';

import 'package:church_staff_pwa/core/types/service_type.dart';
import '../../../auth/domain/entities/user.dart';
import '../../../../core/utils/error_messages.dart';
import '../../domain/roster_import.dart';

/// 一切顺利时的 snackbar 文字。
///
/// 只有 [RosterImportSummary.hasIssues] 为 false 时才会用到 —— 有任何未匹配
/// 都改开汇入结果视窗，因为那里才有补设定的按钮。
///
/// 外来讲员不算问题、不会开汇入结果视窗，但名字要让人看得到 —— 不然
/// 「讲员有没有排上去」只能自己去翻服事表。
String importResultMessage(RosterImportSummary summary) {
  if (summary.updated == 0) return '找不到可更新的日期';
  final guests = summary.guestSpeakerNames;
  return [
    '已更新 ${summary.updated} 笔服事表',
    if (guests.isNotEmpty) '外来讲员：${guests.join('、')}',
  ].join('。');
}

/// 补设定失败、而且原因是使用者看得懂也能处理的。
///
/// 一般例外会经过 mapErrorToUserMessage 变成「操作失败，请稍后再试」——
/// 对「有两位同工都叫王大明」这种讯息来说那等于把唯一有用的资讯丢掉，使用者
/// 只会一直按重试。这类原因用这个型别丢出来，原文直接显示。
class ImportFixException implements Exception {
  const ImportFixException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 把某个服事加进某个人的服事设定。失败时丢例外，由呼叫端显示讯息。
typedef AddMinistryToUser =
    Future<void> Function(String userName, List<String> roles);

/// 把一个活动加进这个崇拜的活动清单（颜色自动挑）。失败时丢例外。
typedef AddEventOption = Future<void> Function(String eventName);

/// 依姓名把服事加进该同工在 [type] 这个崇拜的服事设定。
///
/// 抽成纯函式是为了能单独测 —— 补设定不能覆盖掉他既有的服事，也不能把他在
/// 别的崇拜的设定弄掉，这两件事出错都要等到下次排班才会发现。
User addMinistriesToUser(User user, ServiceType type, List<String> roles) {
  final zones = List<UserZoneInfo>.from(user.zones);
  final index = zones.indexWhere((zone) => zone.serviceType == type);

  if (index < 0) {
    // 这个人在这个崇拜还没有任何设定，开一笔新的。
    return user.copyWith(
      zones: [
        ...zones,
        UserZoneInfo(serviceType: type, ministries: [...roles]),
      ],
    );
  }

  // 保留既有顺序，只把还没有的接在后面。
  final merged = List<String>.from(zones[index].ministries);
  for (final role in roles) {
    if (!merged.contains(role)) merged.add(role);
  }
  zones[index] = zones[index].copyWith(ministries: merged);
  return user.copyWith(zones: zones);
}

// ── Dialog ──────────────────────────────────────────────────────────────────

class RosterImportSummaryDialog extends StatefulWidget {
  const RosterImportSummaryDialog({
    super.key,
    required this.summary,
    required this.type,
    required this.onAddMinistry,
    this.onAddEvent,
  });

  final RosterImportSummary summary;
  final ServiceType type;

  /// null 表示这个人没有改别人设定的权限（补设定写的是 `users/{uid}`，那是
  /// admin only）。服事表编辑者进得来这个汇入流程，但补不了设定 —— 与其给他
  /// 一颗按下去必定失败的按钮，不如不要给，并且说清楚要找谁。
  final AddMinistryToUser? onAddMinistry;

  /// null 表示不能改活动清单（`settings/` 是 admin only），理由同上。
  final AddEventOption? onAddEvent;

  @override
  State<RosterImportSummaryDialog> createState() =>
      _RosterImportSummaryDialogState();
}

enum _ActionState { idle, running, done, failed }

/// 汇入结果上可以按的是哪一种补救。
enum _ActionKind { addMinistry, addEvent }

/// 一列的身分。同一个人有多个服事，状态要能分开记，所以 key 不能只用姓名；
/// 活动跟人分开记，活动名称刚好跟某个人名一样也不会连动。用 record 而不是
/// 把几段字串接起来：接起来就得挑一个不会出现在名字里的分隔符。
typedef _RowKey = ({_ActionKind kind, String name, String? role});

/// 单笔补设定的等待上限。公开出来让测试不必真的等。
const Duration fixTimeout = Duration(seconds: 20);

class _RosterImportSummaryDialogState extends State<RosterImportSummaryDialog> {
  final Map<_RowKey, _ActionState> _actionStates = {};
  final Map<_RowKey, String> _actionErrors = {};

  /// 一次只跑一笔。每笔新增都是「读出这个人 → 加一项 → 整份写回」，同一个人
  /// 的两个服事若同时送出，两边都会读到修改前的资料，后写的那笔会把先写的
  /// 盖掉 —— 使用者会看到两行都变成已新增，实际上只进去一项。
  ///
  /// 这条链永远不会 reject（失败在各自的 try 里收掉），所以一笔失败不会把
  /// 后面排队的一起卡死。
  Future<void> _queue = Future<void>.value();

  static _RowKey _ministryKey(String name, String role) =>
      (kind: _ActionKind.addMinistry, name: name, role: role);

  static _RowKey _eventKey(String name) =>
      (kind: _ActionKind.addEvent, name: name, role: null);

  Future<void> _fix(String name, String role) async {
    final onAddMinistry = widget.onAddMinistry;
    // 没有权限时按钮根本不会渲染，走到这里代表呼叫端搞错了 —— 静静地什么都
    // 不做比抛 null 例外好，这是对话框不是后端。
    if (onAddMinistry == null) return;
    await _runQueued(
      _ministryKey(name, role),
      () => onAddMinistry(name, [role]),
    );
  }

  Future<void> _addEvent(String name) async {
    final onAddEvent = widget.onAddEvent;
    if (onAddEvent == null) return;
    await _runQueued(_eventKey(name), () => onAddEvent(name));
  }

  /// 排进 [_queue] 跑一笔写入，并把状态记在 [key] 那一列。
  ///
  /// 活动也走同一条队伍，理由跟补设定一样：活动清单是整份文件写回去的，
  /// 两个活动同时加，后写的那笔会把先加的盖掉。
  Future<void> _runQueued(_RowKey key, Future<void> Function() write) async {
    setState(() {
      _actionStates[key] = _ActionState.running;
      _actionErrors.remove(key);
    });

    final previous = _queue;
    final done = Completer<void>();
    _queue = done.future;
    try {
      await previous;
      // 逾时是这条链的活命条件，不只是体贴。这是 PWA，断线时 Firestore 的
      // 写入 future 不会 resolve —— 没有逾时的话 done 永远不 complete，之后
      // 每一列都会卡在 await previous 上无限转圈，连错误讯息都没有。
      //
      // 逾时不会取消已经送出的写入，但两种写入都是幂等的（补设定不会重复加，
      // 同名活动已经在清单里就不再写），重试安全。
      await write().timeout(fixTimeout);
      if (mounted) setState(() => _actionStates[key] = _ActionState.done);
    } catch (e, st) {
      log('汇入结果补设定失败', error: e, stackTrace: st);
      if (mounted) {
        setState(() {
          _actionStates[key] = _ActionState.failed;
          _actionErrors[key] = e is ImportFixException
              ? e.message
              : mapErrorToUserMessage(e);
        });
      }
    } finally {
      done.complete();
    }
  }

  @override
  Widget build(BuildContext context) {
    final summary = widget.summary;
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('汇入结果'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '已更新 ${summary.updated} 笔服事表',
                style: theme.textTheme.bodyMedium,
              ),
              // 只讲事实，不派工作。这些人多半是临时来支援的，一年可能就这么
              // 一次 —— 把他们永久设成该服事的固定班底反而会弄脏名单。要不要
              // 补设定是管理者当下才知道的判断，画面不该替他决定。
              if (summary.canPromiseAllImported)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '下面的名字都已经排进表里了。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),

              if (summary.roleMismatchDetails.isNotEmpty)
                _Section(
                  title: '没有设定这个服事',
                  note: widget.onAddMinistry == null ? '只有管理员能补进他的服事设定。' : null,
                  // 一个服事一列。同一个人被排到两项时，可能只有其中一项该
                  // 补进设定（另一项是临时支援），绑在一起就只能全补或全不补。
                  children: [
                    for (final entry in summary.roleMismatchDetails.entries)
                      if (entry.value.isEmpty)
                        // 没有具体服事可补时仍然要列出来，不能让这个人从
                        // 报告上消失。没有服事就没有东西可补，所以不给按钮
                        // —— 按了也只是把同一份资料再写一次。
                        _ActionRow(text: entry.key)
                      else
                        for (final role in entry.value)
                          _ActionRow(
                            text: '${entry.key}：$role',
                            state:
                                _actionStates[_ministryKey(entry.key, role)] ??
                                _ActionState.idle,
                            error: _actionErrors[_ministryKey(entry.key, role)],
                            action: widget.onAddMinistry == null
                                ? null
                                : _RowAction(
                                    label: '新增服事至同工',
                                    doneLabel: '已新增',
                                    onPressed: () => _fix(entry.key, role),
                                  ),
                          ),
                  ],
                ),

              if (summary.notInRosterNames.isNotEmpty)
                _Section(
                  title: '名单里没有这个人',
                  note: '他不会在自己的首页看到这次服事。',
                  children: [
                    for (final name in summary.notInRosterNames)
                      // 名单里有很像的就一起列出来。名字是照表上原文写进去
                      // 的，没有自动换成候选那位 —— 还没建帐号的新同工，
                      // 名字常常跟某个真人只差一个字，自动换等于把他的服事
                      // 记到别人头上。要不要改是管理者看了才知道。
                      _PlainRow(
                        text: switch (summary.nearMatchSuggestions[name]) {
                          null => name,
                          final similar when similar.isEmpty => name,
                          final similar =>
                            '$name（名单里有很像的：${similar.join('、')}）',
                        },
                      ),
                  ],
                ),

              // 讲员没有帐号是常态，所以不用「名单里没有这个人」那种口气，
              // 也不拆成一人一行 —— 一行带过，知道名字有写进去就好。
              if (summary.guestSpeakerNames.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(
                    '外来讲员：${summary.guestSpeakerNames.join('、')}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),

              if (summary.otherNames.isNotEmpty)
                _Section(
                  title: '不确定是哪一位',
                  // 这一格没有连到任何帐号 —— 名字照样写上去了，但两位都不会
                  // 在自己的首页看到。不讲清楚的话，管理者只会
                  // 觉得「反正名字有出现」就过去了。
                  note: '这一格没有对到帐号，两位都不会在自己的首页看到。',
                  children: [
                    for (final name in summary.otherNames)
                      _PlainRow(text: name),
                  ],
                ),

              if (summary.missingDates.isNotEmpty)
                _Section(
                  title: '这几天没有汇入',
                  note: '服事表里找不到这些日期。',
                  children: [
                    for (final date in summary.missingDates)
                      _PlainRow(text: date),
                  ],
                ),

              if (summary.notInEventCatalog.isNotEmpty)
                _Section(
                  title: '活动没有固定颜色',
                  note: widget.onAddEvent == null
                      ? '只有管理员能加进活动清单。'
                      // 讲清楚按下去会发生什么：颜色是挑的，不是问的。
                      : '加进活动清单后会自动配一个颜色，之后可以在活动设定改。',
                  children: [
                    for (final name in summary.notInEventCatalog)
                      _ActionRow(
                        text: name,
                        state:
                            _actionStates[_eventKey(name)] ?? _ActionState.idle,
                        error: _actionErrors[_eventKey(name)],
                        action: widget.onAddEvent == null
                            ? null
                            : _RowAction(
                                label: '加入活动清单',
                                doneLabel: '已加入',
                                onPressed: () => _addEvent(name),
                              ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, this.note, required this.children});

  final String title;

  /// 标题已经讲清楚时就不要再补一句 —— 使用者是同工不是工程师，每多一行
  /// 都是一行要读的东西。
  final String? note;

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          if (note != null) ...[
            const SizedBox(height: 2),
            Text(
              note!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 4),
          ...children,
        ],
      ),
    );
  }
}

class _PlainRow extends StatelessWidget {
  const _PlainRow({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: SelectableText('・$text', style: const TextStyle(fontSize: 13)),
    );
  }
}

/// 一列右边那颗「补上」的按钮：按钮上的字、做完之后换成的字、按下去做什么。
/// 三个一定一起出现，所以包在一起，而不是三个各自可以是 null 的参数。
class _RowAction {
  const _RowAction({
    required this.label,
    required this.doneLabel,
    required this.onPressed,
  });

  final String label;

  /// 做完之后那个位置显示的字。同一行左边已经写著是谁、哪一项，所以短短
  /// 一个「已新增」就够。
  final String doneLabel;

  final VoidCallback onPressed;
}

/// 一列文字，右边可能带一颗「补上」的按钮，按下去之后换成状态。
class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.text,
    this.state = _ActionState.idle,
    this.error,
    this.action,
  });

  final String text;
  final _ActionState state;
  final String? error;

  /// null 代表补不了：不是没有东西可补，就是这个人没有权限。两种情况都只列
  /// 出文字，不给按钮 —— 给一颗按下去必定失败的按钮，使用者只会一直重试，
  /// 而错误讯息是泛用的「操作失败，请稍后再试」。
  final _RowAction? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final action = this.action;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('・$text', style: const TextStyle(fontSize: 13)),
              ),
              if (action != null) ...[
                const SizedBox(width: 8),
                switch (state) {
                  _ActionState.running => const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  _ActionState.done => Text(
                    action.doneLabel,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  _ActionState.idle || _ActionState.failed => TextButton(
                    onPressed: action.onPressed,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    child: Text(
                      state == _ActionState.failed ? '重试' : action.label,
                    ),
                  ),
                },
              ],
            ],
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(left: 12, bottom: 4),
              child: Text(
                error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
