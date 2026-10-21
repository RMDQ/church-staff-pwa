import 'package:church_staff_pwa/core/types/service_type.dart';

import '../../auth/domain/entities/user.dart';
import 'entities/event_option.dart';
import 'entities/service_roster.dart';
import 'roster_import_parser.dart';
import 'staff_directory.dart';
import 'staff_order.dart';

/// 一次汇入的结果：要嘛不能汇，要嘛是要写的服事表加上写完之后的报告。
sealed class RosterImportPlan {
  const RosterImportPlan();
}

/// 整份汇入不能进行。[message] 直接给使用者看。
class RosterImportRejected extends RosterImportPlan {
  const RosterImportRejected(this.message);

  final String message;
}

/// 可以写了。
///
/// [summary] 是**假设 [updates] 全部写成功**的报告 —— 写入失败时呼叫端改报
/// 失败，不显示它。
class RosterImportReady extends RosterImportPlan {
  const RosterImportReady({
    required this.updates,
    required this.summary,
    required this.staffOrder,
  });

  final List<ServiceRoster> updates;
  final RosterImportSummary summary;

  /// 从这次汇入的服事学到的同工排序：图片上谁写前面，谁就排前面。名单外
  /// 的人（外请讲员）不在里面，见 [StaffOrder.where]。
  ///
  /// 要在 [updates] 之前写（`RosterProvider.applyRosterImport` 照这个顺序写）：
  /// 服事表写入时照排序重排，先写服事表的话，会照
  /// 旧的排序把图片上的顺序打乱。只带活动的汇入没有东西可学，是空的。
  final StaffOrder staffOrder;
}

/// 把贴上（或照片辨识出来）的 JSON 对到 [type] 现有的服事表上。
///
/// 不碰 Firestore：输入是现况，输出是要写的东西。画面只剩「读现况、呼叫、
/// 写入、显示」—— 以前这段编排写在 widget 的 State 里，样板排序、报告漏人
/// 那几个 bug 都出在这里，却没有任何测试碰得到。
///
/// [templates] 为 null 代表样板还没载入。[rosters] 只要 [type] 这个崇拜的。
RosterImportPlan planRosterImport({
  required String input,
  required ServiceType type,
  required List<User> users,
  required List<ServiceRoster> rosters,
  required Map<ServiceType, List<String>>? templates,
  required List<EventOption> eventOptions,
}) {
  final staff = StaffDirectory.fromUsers(users, type);
  final parsed = parseRosterImportJson(
    input: input,
    staff: staff,
    catalogByName: {for (final option in eventOptions) option.name: option},
  );
  if (parsed.error case final error?) return RosterImportRejected(error);

  // 服事项目的顺序完全由样板决定，样板不可靠就不能汇 —— 缺席时所有角色
  // 并列，会退回 JSON 的顺序写进 Firestore，画面上看不出哪里不对。
  //
  // 只挡含 duties 的汇入：只带 events 的 JSON 根本不排序，没有理由一起挡。
  //
  // 「载入过」不够：写入空样板之后也算载入过，但这个崇拜的键可能根本不存
  // 在。真正要问的是「这个崇拜的样板拿得到吗」。
  final templateRoles = templates?[type];
  if (parsed.dutiesProvidedDates.isNotEmpty) {
    if (templates == null) {
      return const RosterImportRejected('服事项目样板尚未载入，顺序会排错。请重新整理后再汇入');
    }
    if (templateRoles == null) {
      // 服事项目设定是 admin only，非 admin 连那颗按钮都看不到，所以这里
      // 讲「请管理员」而不是「请先到」—— 后者对他是一条走不通的路。
      return RosterImportRejected('${type.label}还没有服事项目样板，顺序会排错。请管理员到服事项目设定新增');
    }
  }

  final rosterByDate = {
    for (final roster in rosters) rosterDateKey(roster.date): roster,
  };
  final updates = <ServiceRoster>[];
  final missingDates = <String>[];
  // 只从这次真的有带服事的日期学，只带活动的那几天还是旧的服事。
  final importedDuties = <ServiceRoster>[];

  for (final key in {
    ...parsed.dutiesProvidedDates,
    ...parsed.eventsProvidedDates,
  }) {
    final roster = rosterByDate[key];
    if (roster == null) {
      missingDates.add(key);
      continue;
    }

    // 只带 duties 的那天不动活动，只带 events 的那天不动服事 —— JSON 里没有
    // 那个键就是「这次不改」，不是「清空」。有带 events 的那天则整批换成
    // JSON 的活动与颜色：汇入是在重写那一天，不是往上叠。
    final hasDuties = parsed.dutiesProvidedDates.contains(key);
    final hasEvents = parsed.eventsProvidedDates.contains(key);
    final updated = roster.copyWith(
      duties: hasDuties
          ? orderDutiesByTemplate(
              parsed.dutiesByDate[key] ?? const [],
              templateRoles ?? const [],
            )
          : roster.duties,
      specialEvents: hasEvents
          ? (parsed.eventsByDate[key] ?? const <String>[])
          : roster.specialEvents,
      customEventColors: hasEvents
          ? (parsed.colorsByDate[key] ?? const <String, int>{})
          : roster.customEventColors,
    );
    updates.add(updated);
    if (hasDuties) importedDuties.add(updated);
  }

  importedDuties.sort((a, b) => a.date.compareTo(b.date));
  return RosterImportReady(
    updates: updates,
    staffOrder: StaffOrder.learnFrom(importedDuties).where(staff.contains),
    summary: RosterImportSummary(
      updated: updates.length,
      missingDates: missingDates,
      notInRosterNames: parsed.notInRosterNames,
      guestSpeakerNames: parsed.guestSpeakerNames,
      // 刻意从 roleMismatchNames 反向长出来，而不是直接沿用 details：报告只
      // 画得出这里的人，两份清单若对不齐，对不齐的那个人会从报告上整个消失。
      roleMismatchDetails: {
        for (final name in parsed.roleMismatchNames)
          name: (parsed.roleMismatchDetails[name]?.toList() ?? [])..sort(),
      },
      otherNames: parsed.otherNames,
      nearMatchSuggestions: parsed.nearMatchSuggestions,
      notInEventCatalog: parsed.notInEventCatalog,
    ),
  );
}

/// 服事表在汇入 JSON 里的日期写法：`YYYY-MM-DD`。
String rosterDateKey(DateTime date) {
  final y = date.year.toString().padLeft(4, '0');
  final m = date.month.toString().padLeft(2, '0');
  final d = date.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

/// 汇入之后的结果报告。
///
/// 没对到的名字**已经照样写进服事表了**，列在这里是让你知道，不是要你回去
/// 补打名字，也不是叫你去改设定 —— 临时支援别的崇拜是常态，那些人一年可能
/// 就来这么一次，把他们设成固定班底反而会弄脏名单。
///
/// 所以文案一律只陈述事实，不写祈使句。「新增服事至同工」那颗按钮是备著的，不是
/// 建议的动作：真的多了一位固定班底时按一下省得跑一趟帐号管理，其余时候
/// 放著就好。
class RosterImportSummary {
  const RosterImportSummary({
    required this.updated,
    required this.missingDates,
    required this.notInRosterNames,
    required this.roleMismatchDetails,
    required this.otherNames,
    required this.nearMatchSuggestions,
    required this.notInEventCatalog,
    this.guestSpeakerNames = const [],
  });

  final int updated;
  final List<String> missingDates;
  final List<String> notInRosterNames;

  /// 人名 → 他被排到、但设定里没有的服事。
  final Map<String, List<String>> roleMismatchDetails;

  final List<String> otherNames;

  /// 表上原字 → 名单里跟它只差一个字的那几位。**只是提示，没有套用。**
  ///
  /// 这里的名字同时在 [notInRosterNames] 里（没有 uid），所以不必另外算进
  /// [hasIssues] —— 它跟著「名单里没有这个人」那一段一起显示。
  final Map<String, List<String>> nearMatchSuggestions;

  final List<String> notInEventCatalog;

  /// 外来讲员：只排在信息、名单里没有也没有很像的。**不算问题**，所以不进
  /// [hasIssues] 也不进 [hasUnmatchedNames] —— 列出来只是让人知道这几个名字
  /// 没有连到帐号，而那对讲员来说是正常的。
  final List<String> guestSpeakerNames;

  bool get hasIssues =>
      hasUnmatchedNames ||
      missingDates.isNotEmpty ||
      notInEventCatalog.isNotEmpty;

  /// 有没有「人」没对到。日期与活动不算 —— 那两类跟「这些人已经排进去了」
  /// 那句安抚无关，不该一起把那句话带出来。
  bool get hasUnmatchedNames =>
      notInRosterNames.isNotEmpty ||
      roleMismatchDetails.isNotEmpty ||
      otherNames.isNotEmpty;

  /// 能不能讲「下面的名字都已经排进表里了」。
  ///
  /// 未匹配的名单是整份 JSON 的统计，但日期找不到的那几笔根本没写进去 ——
  /// 那些人名照样会出现在清单上。只要有任何一天没汇入，这句话就可能是假的；
  /// 一笔都没更新时更是彻底的谎话。宁可不讲，也不要让管理者以为排好了。
  bool get canPromiseAllImported =>
      hasUnmatchedNames && updated > 0 && missingDates.isEmpty;
}
