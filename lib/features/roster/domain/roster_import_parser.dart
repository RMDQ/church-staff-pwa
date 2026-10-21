// 汇入的内部实作：把 JSON 读成逐日的服事与活动，并记下哪些名字没对上。
//
// app 里只有 roster_import.dart（planRosterImport）用它 —— 对到现有服事表、
// 样板排序、报告都在那边，直接呼叫这里等于绕过那些检查。
// test/roster_import_plan_test.dart 有一个测试守著这件事。直接用它的只有它
// 自己的测试，和 scripts/preview-roster-import.py（要逐日印出排序结果）。

import 'dart:convert';

import 'entities/event_option.dart';
import 'entities/service_roster.dart';
import 'staff_directory.dart';

// ── Public result type ──────────────────────────────────────────────────────

class RosterImportParseResult {
  /// Fatal error — stop everything if this is non-null.
  final String? error;

  /// dutiesByDate: only dates where "duties" key existed AND parsed OK.
  final Map<String, List<RosterEntry>> dutiesByDate;

  /// Dates where the "duties" key was present in JSON (may be empty list if
  /// duties array was empty — but the validator rejects that, so in practice
  /// only non-empty arrays appear here).
  final Set<String> dutiesProvidedDates;

  /// eventsByDate: only dates where "events" key existed (empty array included).
  final Map<String, List<String>> eventsByDate;

  /// Dates where the "events" key was present in JSON (includes empty array).
  final Set<String> eventsProvidedDates;

  /// Per-date color overrides — only includes events where JSON explicitly
  /// provided a color value.
  final Map<String, Map<String, int>> colorsByDate;

  /// Names that did not appear in the candidate-name list.
  ///
  /// 不含 [guestSpeakerNames] —— 那些人另外列，不算问题。
  final List<String> notInRosterNames;

  /// 只出现在「信息」这一格、名单里没有、也没有很像的人：外来讲员。
  ///
  /// 名字一样照写进服事表，只是报告上不把他们当成要处理的事。讲员一年可能
  /// 就来一次，没有帐号是正常的；跟「新同工还没开帐号」混在同一段，真正要
  /// 注意的那几个名字就被淹掉了。
  final List<String> guestSpeakerNames;

  /// Names whose role assignment did not match the allowed-by-role map.
  final List<String> roleMismatchNames;

  /// Detail: role(s) that triggered the mismatch, keyed by person name.
  final Map<String, Set<String>> roleMismatchDetails;

  /// Names that matched more than one candidate: a suffix several people share,
  /// or a full name two people on the list both have.
  final List<String> otherNames;

  /// 表上原字 → 名单里跟它只差一个字的那几位。**只是提示，没有套用。**
  ///
  /// 这些名字一律照表上原文写进服事表，没有 uid —— 也就是同时会出现在
  /// [notInRosterNames]。列出候选是为了让管理者一眼看出「这是不是某位的
  /// 别写法」，该不该改由他决定。
  final Map<String, List<String>> nearMatchSuggestions;

  /// Event names that were not found in the supplied catalog.
  final List<String> notInEventCatalog;

  const RosterImportParseResult({
    this.error,
    this.dutiesByDate = const {},
    this.dutiesProvidedDates = const {},
    this.eventsByDate = const {},
    this.eventsProvidedDates = const {},
    this.colorsByDate = const {},
    this.notInRosterNames = const [],
    this.guestSpeakerNames = const [],
    this.roleMismatchNames = const [],
    this.roleMismatchDetails = const {},
    this.otherNames = const [],
    this.nearMatchSuggestions = const {},
    this.notInEventCatalog = const [],
  });

  /// Convenience: fatal-error constructor.
  const RosterImportParseResult.fatal(String message)
    : error = message,
      dutiesByDate = const {},
      dutiesProvidedDates = const {},
      eventsByDate = const {},
      eventsProvidedDates = const {},
      colorsByDate = const {},
      notInRosterNames = const [],
      guestSpeakerNames = const [],
      roleMismatchNames = const [],
      roleMismatchDetails = const {},
      otherNames = const [],
      nearMatchSuggestions = const {},
      notInEventCatalog = const [];
}

/// 常由外面的人来担任的服事。三个崇拜的讲道在服事项目样板里都叫「信息」。
///
/// 只放这一项：其他服事由没帐号的人担任时，多半是新同工还没开帐号，
/// 那正是汇入报告要让人看到的。
///
/// 写死而不是做成设定：三个崇拜都叫这个名字，为一个不会变的值多做一个
/// 设定画面不划算。**服事项目设定里把「信息」改名的话，这里要跟著改**，
/// 否则讲员会回到「名单里没有这个人」—— 没有测试会替你抓到这件事。
const Set<String> guestSpeakerRoles = {'信息'};

/// 名称里带著自己日期的活动，例如「感恩聚餐（12/26 六）」。
///
/// 主日的辨识规则会把「表旁边写在星期六」这种活动放到之后那个主日，名称
/// 后面带上它真正的日期。这种活动一次性、名字每次都不同，**不该**进活动
/// 清单：放进去也永远对不上下一次的名称。所以不列进「活动没有固定颜色」，
/// 也就不会有人对它按「加入活动清单」。
bool isDatedOneOffEvent(String name) =>
    RegExp(r'[（(]\s*\d{1,2}/\d{1,2}').hasMatch(name);

// ── Helper types ────────────────────────────────────────────────────────────

class EventParseOutcome {
  final String? error;
  final List<String> names;

  /// Only includes entries where the caller explicitly supplied a color.
  final Map<String, int> colorOverrides;

  const EventParseOutcome({
    this.error,
    this.names = const [],
    this.colorOverrides = const {},
  });
  const EventParseOutcome.err(String message)
    : error = message,
      names = const [],
      colorOverrides = const {};
}

// ── Top-level pure parser ───────────────────────────────────────────────────

/// Parse the raw JSON string for roster import.
///
/// [input]         — raw text from the text field.
/// [staff]         — who is on the staff list and what they may serve.
/// [catalogByName] — map of event name → EventOption (for the relevant type).
RosterImportParseResult parseRosterImportJson({
  required String input,
  required StaffDirectory staff,
  required Map<String, EventOption> catalogByName,
}) {
  if (input.trim().isEmpty) {
    return const RosterImportParseResult.fatal('请贴上 JSON 内容');
  }

  dynamic decoded;
  try {
    decoded = jsonDecode(input);
  } catch (_) {
    return const RosterImportParseResult.fatal('JSON 格式错误');
  }

  if (decoded is! List) {
    return const RosterImportParseResult.fatal('JSON 最外层需为阵列');
  }

  final dutiesByDate = <String, List<RosterEntry>>{};
  final dutiesProvidedDates = <String>{};
  final eventsByDate = <String, List<String>>{};
  final eventsProvidedDates = <String>{};
  final colorsByDate = <String, Map<String, int>>{};
  final duplicateDates = <String>[];

  final notInRosterNames = <String>[];
  // 没对到的人各自出现在哪些服事 —— 用来分出外来讲员。
  final notInRosterRoles = <String, Set<String>>{};
  final roleMismatchNames = <String>[];
  final roleMismatchDetails = <String, Set<String>>{};
  final otherNames = <String>[];
  final nearMatchSuggestions = <String, List<String>>{};
  final notInEventCatalog = <String>[];

  for (var i = 0; i < decoded.length; i++) {
    final rowNum = i + 1;
    final item = decoded[i];
    if (item is! Map) {
      return RosterImportParseResult.fatal('第 $rowNum 笔不是物件');
    }

    // ── date ──────────────────────────────────────────────────────────────
    final dateValue = item['date'];
    if (dateValue is! String) {
      return RosterImportParseResult.fatal('第 $rowNum 笔缺少 date');
    }
    final parsedDate = _parseDateKey(dateValue);
    if (parsedDate == null) {
      return RosterImportParseResult.fatal('第 $rowNum 笔 date 格式错误');
    }

    // ── duties (optional key) ─────────────────────────────────────────────
    final hasDutiesKey = item.containsKey('duties');
    List<RosterEntry>? parsedDuties;
    if (hasDutiesKey) {
      final dutiesValue = item['duties'];
      if (dutiesValue is! List) {
        return RosterImportParseResult.fatal('第 $rowNum 笔 duties 格式错误');
      }
      final duties = <RosterEntry>[];
      for (var j = 0; j < dutiesValue.length; j++) {
        final dutyNum = j + 1;
        final duty = dutiesValue[j];
        if (duty is! Map) {
          return RosterImportParseResult.fatal(
            '第 $rowNum 笔 duties 第 $dutyNum 笔不是物件',
          );
        }
        final roleValue = duty['role'];
        if (roleValue is! String || roleValue.trim().isEmpty) {
          return RosterImportParseResult.fatal(
            '第 $rowNum 笔 duties 第 $dutyNum 笔 role 缺失',
          );
        }
        final peopleValue = duty['people'];
        if (peopleValue is! List) {
          return RosterImportParseResult.fatal(
            '第 $rowNum 笔 duties 第 $dutyNum 笔 people 格式错误',
          );
        }
        // 非字串的元素（null、数字）以前被 whereType 静静滤掉 —— 跟这次要
        // 消灭的「名字无声失踪」是同一件事，只是更难察觉：它连报告都不会进。
        // 这种资料就是坏掉的，直接让整份汇入停下来说明是哪一笔。
        for (var k = 0; k < peopleValue.length; k++) {
          if (peopleValue[k] is! String) {
            return RosterImportParseResult.fatal(
              '第 $rowNum 笔 duties 第 $dutyNum 笔 people 第 ${k + 1} 个不是文字',
            );
          }
        }
        final people = peopleValue
            .cast<String>()
            .map((name) => name.trim())
            // 空字串不是名字，跳过。这是唯一会被静静略过的东西。
            .where((name) => name.isNotEmpty)
            .map((name) {
              final result = staff.resolve(name, roleValue.trim());
              // 没对到的名字一律照样写进服事表，只记进报告，不丢掉。
              //
              // 以前是丢掉的，那格于是变成「待定」，同一格还有别人时甚至什么
              // 痕迹都没有 —— 墙上的表写著两个人，app 显示一个，肉眼分不出来。
              // 临时支援别的崇拜是正常状况，不该被当成错误资料删掉。
              //
              // 首页的「我的服事」在 uid 对不上时会退回姓名比对，所以名字留著
              // 本人就看得到自己被排到；名字删掉才是真的把人弄丢。
              if (result.suggestions.isNotEmpty) {
                // 名单里很像的那几位。名字照原文写进去了，这只是提示。
                nearMatchSuggestions[name] = result.suggestions;
              }
              switch (result.status) {
                case NameMatchStatus.matched:
                  return result.name;
                case NameMatchStatus.roleMismatch:
                  // 人是名单上的真人，uid 也查得到（下面的 personIdsByName
                  // 会自动带上），只是没设定这个服事。
                  roleMismatchNames.add(result.name);
                  _addRoleMismatch(
                    roleMismatchDetails,
                    result.name,
                    roleValue.trim(),
                  );
                  return result.name;
                case NameMatchStatus.notInList:
                  // 名单上没有这个人 —— 存纯文字，没有 uid，收不到通知。
                  notInRosterNames.add(name);
                  notInRosterRoles
                      .putIfAbsent(name, () => <String>{})
                      .add(roleValue.trim());
                  return name;
                case NameMatchStatus.other:
                  // 对到两个以上同名的人，系统无从判断是谁，原字串照留。
                  otherNames.add(name);
                  return name;
              }
            })
            .whereType<String>()
            .toList();
        duties.add(
          RosterEntry(
            role: roleValue.trim(),
            people: people.isEmpty ? const [placeholderPerson] : people,
            personIdsByName: staff.idsOf(people),
          ),
        );
      }
      // duties key 存在但 array 为空 → reject
      if (duties.isEmpty) {
        return RosterImportParseResult.fatal('第 $rowNum 笔 duties 不可为空');
      }
      parsedDuties = duties;
    }

    // ── events (optional key) ─────────────────────────────────────────────
    final hasEventsKey = item.containsKey('events');
    List<String>? parsedEventNames;
    Map<String, int>? parsedColorOverrides;
    if (hasEventsKey) {
      final outcome = parseEventsList(rowNum, item['events'], catalogByName);
      if (outcome.error != null) {
        return RosterImportParseResult.fatal(outcome.error!);
      }
      parsedEventNames = outcome.names;
      parsedColorOverrides = outcome.colorOverrides;

      // Collect catalog misses
      for (final name in outcome.names) {
        if (!catalogByName.containsKey(name) &&
            !isDatedOneOffEvent(name) &&
            !notInEventCatalog.contains(name)) {
          notInEventCatalog.add(name);
        }
      }
    }

    // ── at least one of duties / events must be provided ─────────────────
    if (!hasDutiesKey && !hasEventsKey) {
      return RosterImportParseResult.fatal('第 $rowNum 笔需至少包含 duties 或 events');
    }

    // ── duplicate date detection ──────────────────────────────────────────
    final alreadyExists =
        dutiesProvidedDates.contains(parsedDate) ||
        eventsProvidedDates.contains(parsedDate) ||
        dutiesByDate.containsKey(parsedDate) ||
        eventsByDate.containsKey(parsedDate);
    if (alreadyExists) {
      duplicateDates.add(parsedDate);
    }

    if (hasDutiesKey && parsedDuties != null) {
      dutiesByDate[parsedDate] = parsedDuties;
      dutiesProvidedDates.add(parsedDate);
    }
    if (hasEventsKey) {
      eventsByDate[parsedDate] = parsedEventNames ?? const [];
      eventsProvidedDates.add(parsedDate);
      colorsByDate[parsedDate] = parsedColorOverrides ?? const {};
    }
  }

  if (duplicateDates.isNotEmpty) {
    return RosterImportParseResult.fatal('重复日期：${duplicateDates.join(', ')}');
  }

  final unmatched = uniqueNames(notInRosterNames);
  bool isGuestSpeaker(String name) =>
      notInRosterRoles[name]!.every(guestSpeakerRoles.contains) &&
      // 名单里有很像的，多半是某位同工的名字被读错一个字，不是外人。
      (nearMatchSuggestions[name] ?? const []).isEmpty;

  return RosterImportParseResult(
    dutiesByDate: dutiesByDate,
    dutiesProvidedDates: dutiesProvidedDates,
    eventsByDate: eventsByDate,
    eventsProvidedDates: eventsProvidedDates,
    colorsByDate: colorsByDate,
    notInRosterNames: [
      for (final name in unmatched)
        if (!isGuestSpeaker(name)) name,
    ],
    guestSpeakerNames: [
      for (final name in unmatched)
        if (isGuestSpeaker(name)) name,
    ],
    roleMismatchNames: uniqueNames(roleMismatchNames),
    roleMismatchDetails: roleMismatchDetails,
    otherNames: uniqueNames(otherNames),
    nearMatchSuggestions: nearMatchSuggestions,
    notInEventCatalog: notInEventCatalog,
  );
}

// ── orderDutiesByTemplate ───────────────────────────────────────────────────

/// 依「服事项目样板」的角色顺序重排汇入进来的服事项目。
///
/// JSON 自己的顺序刻意不采用。样板是唯一的排序依据 —— 不管 JSON 是谁产生的、
/// 用什么顺序写，同一个类别的服事表在画面上的项目顺序都一致。
///
/// 样板里没有的角色一律接在最后，彼此之间才维持 JSON 的相对顺序。
///
/// [templateRoles] 为空时所有角色并列，等于整份退回 JSON 顺序 —— 呼叫端必须
/// 先确认样板真的载入过再进来，否则同一份 JSON 汇入两次会排出两种结果。
List<RosterEntry> orderDutiesByTemplate(
  List<RosterEntry> duties,
  List<String> templateRoles,
) {
  final roleOrder = <String, int>{};
  for (var i = 0; i < templateRoles.length; i++) {
    // 样板理论上不会有重复角色（设定画面挡掉了），真的有的话取第一次出现的
    // 位置，跟人看样板的直觉一致。
    roleOrder.putIfAbsent(templateRoles[i], () => i);
  }

  // 先把 JSON 的原始索引绑上去再排。Dart 的 List.sort 不保证稳定，同一个角色
  // 在 JSON 里出现两次时，不自己 tie-break 的话相对顺序是未定义的。
  // 用索引而不是 indexOf：indexOf 走的是 ==，将来 RosterEntry 若加上值相等，
  // 两个相等的项目会拿到同一个索引，tie-break 就失效了。
  final indexed = <MapEntry<int, RosterEntry>>[
    for (var i = 0; i < duties.length; i++) MapEntry(i, duties[i]),
  ];
  indexed.sort((a, b) {
    final ai = roleOrder[a.value.role] ?? templateRoles.length;
    final bi = roleOrder[b.value.role] ?? templateRoles.length;
    if (ai != bi) return ai.compareTo(bi);
    return a.key.compareTo(b.key);
  });

  return [for (final entry in indexed) entry.value];
}

// ── parseEventsList ─────────────────────────────────────────────────────────

/// Parse the value of an "events" key from a single JSON row.
///
/// [rowIndex] is 1-based row number for error messages.
/// [raw]      is the raw value of item['events'].
/// [catalogByName] is used to decide whether JSON color overrides are needed.
EventParseOutcome parseEventsList(
  int rowIndex,
  dynamic raw,
  Map<String, EventOption> catalogByName,
) {
  if (raw is! List) {
    return EventParseOutcome.err('第 $rowIndex 笔 events 格式错误');
  }

  final names = <String>[];
  final colorOverrides = <String, int>{};
  final seenNames = <String>{};

  for (var k = 0; k < raw.length; k++) {
    final elemNum = k + 1;
    final elem = raw[k];
    String eventName;
    int? explicitColor;

    if (elem is String) {
      eventName = elem.trim();
      if (eventName.isEmpty) {
        return EventParseOutcome.err('第 $rowIndex 笔 events 第 $elemNum 笔名称不可为空');
      }
    } else if (elem is Map) {
      final nameRaw = elem['name'];
      if (nameRaw == null) {
        return EventParseOutcome.err(
          '第 $rowIndex 笔 events 第 $elemNum 笔缺少 name',
        );
      }
      if (nameRaw is! String || nameRaw.trim().isEmpty) {
        return EventParseOutcome.err(
          '第 $rowIndex 笔 events 第 $elemNum 笔 name 格式错误',
        );
      }
      eventName = nameRaw.trim();

      if (elem.containsKey('color')) {
        final colorRaw = elem['color'];
        final parsed = parseColor(colorRaw);
        if (parsed == null) {
          return EventParseOutcome.err(
            '第 $rowIndex 笔 events 第 $elemNum 笔 color 格式错误',
          );
        }
        explicitColor = parsed;
      }
    } else {
      return EventParseOutcome.err('第 $rowIndex 笔 events 第 $elemNum 笔格式错误');
    }

    // Duplicate name check within the same day
    if (seenNames.contains(eventName)) {
      return EventParseOutcome.err('第 $rowIndex 笔 events 名称重复：$eventName');
    }
    seenNames.add(eventName);
    names.add(eventName);

    // Color override: only store if JSON explicitly provided one.
    // If no JSON color but catalog has one → do NOT store (let UI read from catalog).
    if (explicitColor != null) {
      colorOverrides[eventName] = explicitColor;
    }
  }

  return EventParseOutcome(names: names, colorOverrides: colorOverrides);
}

// ── parseColor ───────────────────────────────────────────────────────────────

/// Parse a color value from JSON.
///
/// Accepts:
///  - int in range [0, 0xFFFFFFFF]
///  - "#RRGGBB"   → 0xFF_RR_GG_BB
///  - "#AARRGGBB" → 0xAA_RR_GG_BB
///  - "0xRRGGBB"  → 0xFF_RR_GG_BB
///  - "0xAARRGGBB"→ 0xAA_RR_GG_BB  (case-insensitive for hex digits)
///
/// Returns null on failure (including named colors like "red").
int? parseColor(dynamic raw) {
  if (raw is int) {
    if (raw >= 0 && raw <= 0xFFFFFFFF) return raw;
    return null;
  }
  if (raw is! String) return null;

  final s = raw.trim();
  if (s.isEmpty) return null;

  // Handle "#RRGGBB" or "#AARRGGBB"
  if (s.startsWith('#')) {
    final hex = s.substring(1);
    if (hex.length == 6) {
      final value = int.tryParse(hex, radix: 16);
      if (value == null) return null;
      return 0xFF000000 | value;
    }
    if (hex.length == 8) {
      return int.tryParse(hex, radix: 16);
    }
    return null;
  }

  // Handle "0xRRGGBB" or "0xAARRGGBB" (case-insensitive)
  if (s.toLowerCase().startsWith('0x')) {
    final hex = s.substring(2);
    if (hex.length == 6) {
      final value = int.tryParse(hex, radix: 16);
      if (value == null) return null;
      return 0xFF000000 | value;
    }
    if (hex.length == 8) {
      return int.tryParse(hex, radix: 16);
    }
    return null;
  }

  return null;
}

// ── Internal helpers ─────────────────────────────────────────────────────────

String? _parseDateKey(String raw) {
  try {
    final parsed = DateTime.parse(raw);
    final y = parsed.year.toString().padLeft(4, '0');
    final m = parsed.month.toString().padLeft(2, '0');
    final d = parsed.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  } catch (_) {
    return null;
  }
}

List<String> uniqueNames(List<String> names) {
  final seen = <String>{};
  final result = <String>[];
  for (final name in names) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || seen.contains(trimmed)) continue;
    seen.add(trimmed);
    result.add(trimmed);
  }
  return result;
}

void _addRoleMismatch(
  Map<String, Set<String>> bucket,
  String name,
  String role,
) {
  final trimmedName = name.trim();
  final trimmedRole = role.trim();
  if (trimmedName.isEmpty || trimmedRole.isEmpty) return;
  bucket.putIfAbsent(trimmedName, () => <String>{});
  bucket[trimmedName]!.add(trimmedRole);
}
