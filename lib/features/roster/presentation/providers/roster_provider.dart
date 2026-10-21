import 'package:church_staff_pwa/core/time/church_time.dart';
import 'dart:developer';

import 'package:flutter/material.dart';
import '../../domain/entities/event_option.dart';
import '../../domain/entities/service_roster.dart';
import 'package:church_staff_pwa/core/types/service_type.dart';
import '../../domain/repositories/roster_repository.dart';
import '../../../../core/utils/error_messages.dart';
import '../../domain/staff_directory.dart';
import '../../domain/roster_import.dart';
import '../../domain/staff_order.dart';
import '../../../../core/utils/scroll_anchor.dart';
import '../../../../core/widgets/text_warmup.dart';

class RosterProvider with ChangeNotifier {
  final RosterRepository _repository;

  List<ServiceRoster> _allRosters = []; // 储存所有原始资料
  Map<ServiceType, List<String>> _templates = {};

  /// 样板是否真的从伺服器读回来过。
  ///
  /// 不能用 `_templates.isEmpty` 或 `templates[type] == null` 代替：读取失败、
  /// 尚未读取、与「这个类别本来就没设定角色」在资料上长得一样，但对汇入来说
  /// 意义完全不同 —— 前两者会让汇入排出错误的顺序。
  bool _templatesLoaded = false;
  Map<ServiceType, List<EventOption>> _eventOptionsByType = {};

  // 同工排序（见 [StaffOrderBook]）。学的那份只在从伺服器／快取读进来时
  // 重算，不在本机每次写入后重算：写入前已经照排序排好了，重算只会得到一
  // 样的东西，而且交换写到一半的状态不该回头影响排序。
  StaffOrderBook _staffOrders = StaffOrderBook();
  bool _isLoading = false;
  bool _isEditMode = false;
  String? _error;

  // 追踪上一次 session userId，用来判断帐号是否真的换了。
  String? _lastSessionUserId;

  // Fetch generation counter：每次 session 变动或主动触发 fetch 时递增。
  // fetch 完成后比对 token，若不一致代表已过期，直接 drop 结果。
  int _fetchToken = 0;

  // ── 衍生资料快取 ────────────────────────────────────────────────────────
  // UI 每次 rebuild 都会问「这个牧区有哪些 roster」「这个事件是什么颜色」。
  // 现算的话等于每个 frame 都扫一次全部资料，所以算一次存起来，
  // 只在 _allRosters / _eventOptionsByType 真的变动时丢掉。
  // 一律透过 _replaceRosters / _replaceRosterAt / _replaceEventOptions
  // 改资料，才不会有人漏掉 invalidate。
  Map<ServiceType, List<ServiceRoster>>? _rostersByType;
  Map<String, int>? _eventColorIndex;
  List<String>? _displayStrings;

  // 事件选项的版本号。UI 想知道「颜色定义有没有换过」时可以 select 这个值 ——
  // eventOptionsByType 每次呼叫都会产生新的 Map，拿来做相等比较永远会是 true。
  int _eventOptionsRevision = 0;

  /// [now] 只给测试用：删除服事项目时「今天以后」的界线要固定得住。
  RosterProvider(this._repository, {DateTime Function()? now})
    : _now = now ?? ChurchTime.now;

  final DateTime Function() _now;

  /// 事件选项的版本号，每次选项被替换就 +1。
  /// widget 用 `context.select((p) => p.eventOptionsRevision)` 订阅颜色变动。
  int get eventOptionsRevision => _eventOptionsRevision;

  /// 换掉整份 roster 清单。
  ///
  /// [rosters] 的 identity 本身就是「资料换过了」的讯号 —— 消费端（例如首页
  /// 的本季服事 memo）用 `identical()` 判断要不要重算，所以任何内容变动都
  /// **必须**换成新的 List instance，不能就地改写。
  ///
  /// 每张都照同工排序排好才放进来 —— 画面、首页、写回去的资料看到的都是排
  /// 好的顺序，不必各自再排。[relearn] 给「从外面读进来」的资料用，见
  /// [_staffOrders]。
  void _replaceRosters(List<ServiceRoster> rosters, {bool relearn = false}) {
    if (relearn) _staffOrders = _staffOrders.relearnedFrom(rosters);
    _allRosters = [for (final roster in rosters) _staffOrders.sort(roster)];
    _rostersByType = null;
    _displayStrings = null;
  }

  /// [type] 这个崇拜实际采用的同工排序。
  StaffOrder staffOrderFor(ServiceType type) => _staffOrders.effectiveFor(type);

  /// 换掉单笔 roster。刻意复制一份新 List 而不是 `_allRosters[index] = ...` ——
  /// 就地改写会让 `rosters` 的 identity 不变，靠 identity 判断是否失效的
  /// 消费端就会继续用旧的计算结果。
  void _replaceRosterAt(int index, ServiceRoster roster) {
    final updated = List<ServiceRoster>.of(_allRosters);
    updated[index] = _staffOrders.sort(roster);
    _replaceRosters(updated);
  }

  void _replaceEventOptions(Map<ServiceType, List<EventOption>> options) {
    _eventOptionsByType = options;
    _eventColorIndex = null;
    _eventOptionsRevision++;
  }

  bool get isLoading => _isLoading;
  bool get isEditMode => _isEditMode;

  /// 载入失败的讯息。写入失败不会出现在这里 —— 写入一律往上丢，见
  /// [updateRoster]。
  String? get error => _error;
  Map<ServiceType, List<String>> get templates => _templates;
  bool get templatesLoaded => _templatesLoaded;
  Map<ServiceType, List<EventOption>> get eventOptionsByType => Map.fromEntries(
    _eventOptionsByType.entries.map(
      (entry) => MapEntry(entry.key, List<EventOption>.from(entry.value)),
    ),
  );
  List<EventOption> eventOptionsFor(ServiceType type) =>
      List.unmodifiable(_eventOptionsByType[type] ?? const <EventOption>[]);

  /// 事件名称 → 颜色。每张卡片的每个事件标签在每次 rebuild 都会问一次，
  /// 所以用一份摊平的索引，不要每次都线性扫过所有 ServiceType 的清单。
  /// 同名事件以本 type 的定义优先，其次才是其他 type（维持原本语意）。
  int eventColorFor(ServiceType type, String name) {
    final own = _eventOptionsByType[type];
    if (own != null) {
      for (final option in own) {
        if (option.name == name) return option.color;
      }
    }
    return _colorIndex[name] ?? fallbackEventColor;
  }

  /// 这一天的这个活动画什么颜色：这张服事表自己指定的 → 活动清单 → 灰色。
  ///
  /// 优先序只写在这里。以前每个画活动标签的地方各自串一次
  /// `customEventColors[event] ?? eventColorFor(...)`，检视与编辑各一份。
  int eventColorOf(ServiceRoster roster, String event) =>
      roster.customEventColors[event] ?? eventColorFor(roster.type, event);

  Map<String, int> get _colorIndex {
    final cached = _eventColorIndex;
    if (cached != null) return cached;

    final index = <String, int>{};
    for (final list in _eventOptionsByType.values) {
      for (final option in list) {
        index.putIfAbsent(option.name, () => option.color);
      }
    }
    _eventColorIndex = index;
    return index;
  }

  // ── 卷动位置锚点 ────────────────────────────────────────────────────────
  // 检视与编辑是两棵不同的 widget 树，切换的当下旧清单整个被拆掉，只有
  // provider 活得够久，所以「切之前看到哪」存在这里。
  //
  // 刻意不 notifyListeners：这是纯 UI 的暂存状态，通知出去只会让画面上每张
  // 卡片为了一个没人显示的数字白白重建一次。
  final Map<ServiceType, ScrollAnchor> _scrollAnchors = {};
  final Map<ServiceType, ScrollAnchor? Function()> _anchorCaptures = {};

  /// 清单挂上时登记自己的取样函式，[captureScrollAnchors] 会逐一呼叫。
  void registerScrollAnchorCapture(
    ServiceType type,
    ScrollAnchor? Function() capture,
  ) {
    _anchorCaptures[type] = capture;
  }

  /// 卸载时撤销登记。比对是不是同一个清单才移除：切换模式时新清单会先登记、
  /// 旧清单才 dispose，直接 remove 会把刚登记好的新清单一起拔掉。
  ///
  /// 用 `==` 不是 `identical`：Dart 的 tear-off 每次取值都是新物件，
  /// `identical(a.cap, a.cap)` 恒为 false，改用 `==` 才问得到「同一个 State 的
  /// 同一个方法」（同 receiver 才相等）。
  void unregisterScrollAnchorCapture(
    ServiceType type,
    ScrollAnchor? Function() capture,
  ) {
    if (_anchorCaptures[type] == capture) {
      _anchorCaptures.remove(type);
    }
  }

  ScrollAnchor? scrollAnchorFor(ServiceType type) => _scrollAnchors[type];

  /// 在切换模式前呼叫：把目前每个分页顶端的日期记下来。
  void captureScrollAnchors() {
    for (final entry in _anchorCaptures.entries) {
      final anchor = entry.value();
      if (anchor != null) _scrollAnchors[entry.key] = anchor;
    }
  }

  void toggleEditMode() {
    _isEditMode = !_isEditMode;
    notifyListeners();
  }

  /// 由 ChangeNotifierProxyProvider 在 SessionProvider.currentUser 变动时呼叫。
  /// 当 userId 真的改变（含登出 → null 或切换帐号），清掉全部 cache 并重抓资料。
  void onSessionChanged(String? userId) {
    if (userId == _lastSessionUserId) return;
    _lastSessionUserId = userId;

    _fetchToken++; // 让进行中的 fetch 过期
    _replaceRosters([]);
    _templates = {};
    _templatesLoaded = false;
    _replaceEventOptions({});
    _staffOrders = StaffOrderBook();
    _error = null;
    _isEditMode = false;
    // 换人＝换整份资料，旧的日期锚点指到的卡片可能根本不存在了。
    _scrollAnchors.clear();

    if (userId != null) {
      // 有新使用者，重抓资料。
      fetchInitialData();
    } else {
      // 登出，仅清除并通知 UI。
      notifyListeners();
    }
  }

  /// 取得特定类别的服事表。分组结果会快取 — UI 每次 rebuild 都会对三个
  /// ServiceType 各问一次，现算等于每个 frame 扫三遍全部 roster 并配置三个
  /// 新 List（也让 ListView 每次都拿到不同的 list instance）。
  List<ServiceRoster> getRostersByType(ServiceType type) {
    final grouped = _rostersByType ??= _groupByType(_allRosters);
    return grouped[type] ?? const <ServiceRoster>[];
  }

  static Map<ServiceType, List<ServiceRoster>> _groupByType(
    List<ServiceRoster> all,
  ) {
    final grouped = <ServiceType, List<ServiceRoster>>{
      for (final type in ServiceType.values) type: <ServiceRoster>[],
    };
    for (final roster in all) {
      (grouped[roster.type] ??= []).add(roster);
    }
    return grouped;
  }

  // 为了相容性，如果有人直接 call rosters (虽然目前没人用)，回传全部
  List<ServiceRoster> get rosters => _allRosters;

  /// 服事表会显示出来的所有不重复字串，给 [TextWarmup] 预热用。
  ///
  /// 是「字串」不是「字元」：引擎的排版快取以整个字串为 key，只预热字元只
  /// 会把字型抓下来，每个名字第一次排版的成本还是会落在卷动途中。
  List<String> get displayStrings {
    final cached = _displayStrings;
    if (cached != null) return cached;

    final sources = <String>[];
    for (final roster in _allRosters) {
      sources.add(roster.serviceName);
      sources.addAll(roster.specialEvents);
      for (final duty in roster.duties) {
        sources.add(duty.role);
        sources.addAll(duty.people);
      }
    }
    final strings = TextWarmup.uniqueStringsOf(sources);
    _displayStrings = strings;
    return strings;
  }

  Future<void> fetchInitialData() async {
    final token = ++_fetchToken;

    // Phase 1: cache-first — 从 IndexedDB 读取（~50-150ms），有资料就先渲染。
    // isLoading 维持 true，但 UI 改成「isLoading && rosters.isEmpty」才显示
    // spinner，所以有 stale data 时画面不再卡白。
    try {
      final cached = await _repository.getUpcomingRostersFromCache();
      if (token != _fetchToken) return; // stale token，丢弃
      if (cached.isNotEmpty) {
        _replaceRosters(cached, relearn: true);
        notifyListeners(); // 先渲染 stale data
      }
    } catch (e, st) {
      log('读取 roster cache 失败（不影响后续 server fetch）', error: e, stackTrace: st);
      // cache 失败不影响继续走 server，silent
    }

    // Phase 2: server fetch — 拿到最新资料后覆盖。
    _isLoading = true;
    _error = null;
    notifyListeners();

    // 三个请求同时发，但只有 roster 是必要的：服事表没有 templates /
    // event options 一样能显示（那两份只影响编辑用的选单与标签颜色）。
    // 全部塞进同一个 Future.wait 的话，任何一份 settings 读取失败都会把
    // 已经成功抓到的 roster 一起丢掉，画面变成「载入失败」。
    final rostersFuture = _repository.getUpcomingRosters();
    final templatesFuture = _optional(
      _repository.getServiceTemplates(),
      '载入服事项目样板失败（不影响服事表显示）',
    );
    final eventOptionsFuture = _optional(
      _repository.getEventOptions(),
      '载入事件选项失败（不影响服事表显示）',
    );
    // 读不到就照学出来的顺序排，一样能看。
    final staffOrdersFuture = _optional(
      _repository.getStaffOrders(),
      '载入同工排序失败（改用服事表上的顺序）',
    );

    try {
      final rosters = await rostersFuture;
      if (token != _fetchToken) return; // stale fetch，丢弃结果
      _replaceRosters(rosters, relearn: true);
    } catch (e, st) {
      if (token != _fetchToken) return; // stale fetch，丢弃错误
      log('载入服事表资料失败', error: e, stackTrace: st);
      // 若 Phase 1 已拿到 cache 资料，就不设 _error（让 UI 显示 stale data 而非错误）
      if (_allRosters.isEmpty) {
        _error = '载入失败:${mapErrorToUserMessage(e)}';
      } else {
        log('Server fetch 失败，UI 继续显示 cache 资料', error: e, stackTrace: st);
      }
    } finally {
      // settings 失败时保留上一次的值，不覆盖成空的。
      final templates = await templatesFuture;
      final eventOptions = await eventOptionsFuture;
      final staffOrders = await staffOrdersFuture;
      if (token == _fetchToken) {
        if (staffOrders != null) {
          _staffOrders = _staffOrders.withStored(staffOrders);
          _replaceRosters(_allRosters);
        }
        if (templates != null) {
          _templates = templates;
          _templatesLoaded = true;
        }
        if (eventOptions != null) _replaceEventOptions(eventOptions);
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  /// 把「有了更好、没有也能动」的请求包成永远不会 reject 的 future：
  /// 失败时 log 后回传 null，让呼叫端保留既有的值。
  static Future<T?> _optional<T>(Future<T> future, String failureMessage) {
    return future.then<T?>((value) => value).catchError((
      Object e,
      StackTrace st,
    ) {
      log(failureMessage, error: e, stackTrace: st);
      return null;
    });
  }

  Future<void> fetchRosters() async {
    final token = ++_fetchToken;

    // Phase 1: cache-first — 先显示 stale data 避免白屏。
    try {
      final cached = await _repository.getUpcomingRostersFromCache();
      if (token != _fetchToken) return;
      if (cached.isNotEmpty) {
        _replaceRosters(cached, relearn: true);
        notifyListeners();
      }
    } catch (e, st) {
      log('读取 roster cache 失败（不影响后续 server fetch）', error: e, stackTrace: st);
    }

    // Phase 2: server fetch。
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final rosters = await _repository.getUpcomingRosters();
      if (token != _fetchToken) return; // stale fetch，丢弃结果
      _replaceRosters(rosters, relearn: true);
    } catch (e, st) {
      if (token != _fetchToken) return; // stale fetch，丢弃错误
      log('载入服事表失败', error: e, stackTrace: st);
      if (_allRosters.isEmpty) {
        _error = '载入失败:${mapErrorToUserMessage(e)}';
      } else {
        log('Server fetch 失败，UI 继续显示 cache 资料', error: e, stackTrace: st);
      }
    } finally {
      if (token == _fetchToken) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  /// 只有具编辑权的人（admin / 负责人）才可呼叫。确保本季 + 下季、[allowedTypes]
  /// 范围内的预定 roster 都已存在于 Firestore。
  ///
  /// [allowedTypes] 要传呼叫者「改得动」的聚会别（[User.allowedRosterTypes]），
  /// 不是画面上显示的全部：多一个他无权写的聚会别，整个 batch 都会被 rules 拒。
  /// 背景执行，失败仅 log，不影响 UI。完成后触发 fetchInitialData 让新建的 roster 出现。
  Future<void> ensureQuarterRostersForEditor(
    List<ServiceType> allowedTypes,
  ) async {
    try {
      await _repository.ensureQuarterRosters(allowedTypes);
    } catch (e, st) {
      log('ensureQuarterRosters 失败', error: e, stackTrace: st);
      // 静默失败，不 disrupt UI。
    }
    // backfill 成功与否都要重抓 —— backfill 只是「补齐缺的 roster」，
    // 它失败不代表现有资料读不到。放在 try 里的话，backfill 一抛例外就会
    // 连重抓一起跳过，进编辑模式时画面停在旧资料且毫无提示。
    await fetchInitialData();
  }

  /// 写一张服事表。
  ///
  /// 这个 provider 的写入失败**一律往上丢**，由呼叫端就地显示；[error] 只留
  /// 给载入失败。以前这里把错误吞进 [error]，而编辑页一看到 [error] 就把整页
  /// 换成错误画面 —— 改错一格，整本服事表从画面上消失。例外只有服事项目
  /// 改名或删除时顺带同步同工排序那一步（见 [_syncStaffOrderRoles]）。
  ///
  /// 写进去之前先照同工排序排好：存起来的就是画面上的顺序，不会因为下次
  /// 重新学排序时学到一份没排好的资料。
  ///
  /// [ranking] 是选人视窗里拖过的顺序，先存它再存这一天 —— 反过来的话这一天
  /// 会照旧的排序排。排序存失败就往上丢，这一天也不写：跟汇入一样，失败时
  /// 什么都没动，重按一次就好。
  Future<void> updateRoster(
    ServiceRoster roster, {
    StaffRanking? ranking,
  }) async {
    if (ranking != null) await updateStaffRanking(roster.type, ranking);
    roster = _staffOrders.sort(roster);
    try {
      await _repository.updateRoster(roster);
    } catch (e, st) {
      log('更新 roster 失败', error: e, stackTrace: st);
      rethrow;
    }
    final index = _allRosters.indexWhere((r) => r.id == roster.id);
    if (index != -1) {
      _replaceRosterAt(index, roster);
      notifyListeners();
    }
  }

  /// 把 [duty] 里的 [from] 换成 [to]，其他人与既有顺序都不动。
  ///
  /// [toId] 是 [to] 在对方那笔 duty 上记的 uid（可能没有，例如「外请讲员」这种
  /// 名单外的自订名字）。要一起搬过来，否则推播就找不到这个人了。
  ///
  /// 两个边界：
  ///   - 换进来的人本来就在这一天：不要留下两个同名，直接把重复的那个吃掉。
  ///     UI 已经先滤掉这种选项，这里是第二道防线。
  ///   - 换成「待定」而这一天还有别人：只把 [from] 拿掉，不补占位符；全空了
  ///     才补一个回去。
  @visibleForTesting
  static RosterEntry replaceDutyPerson(
    RosterEntry duty,
    String from,
    String to, {
    String? toId,
  }) {
    List<String> replaced(List<String> names) {
      final result = <String>[];
      for (final name in names) {
        if (name == from) {
          if (to != placeholderPerson && !result.contains(to)) result.add(to);
          continue;
        }
        if (name == to || name == placeholderPerson) continue;
        result.add(name);
      }
      return result;
    }

    // 没有人的 duty 在 UI 上显示成一个「待定」（见 _SwapDutyDialog），所以这里
    // 也要把空清单当成 ['待定']，否则以待定为交换对象时 from 找不到对应项目，
    // 换过来的人会直接消失。
    final currentPeople = duty.people.isEmpty
        ? const [placeholderPerson]
        : duty.people;

    final people = replaced(currentPeople);
    if (people.isEmpty) people.add(placeholderPerson);

    final personIdsByName = Map<String, String>.from(duty.personIdsByName)
      ..remove(from);
    final trimmedToId = toId?.trim();
    if (trimmedToId != null && trimmedToId.isNotEmpty && people.contains(to)) {
      personIdsByName[to] = trimmedToId;
    }
    // 名字都不在这一天了，uid 留著只会在下次交换时被误搬。
    personIdsByName.removeWhere((name, _) => !people.contains(name));

    return duty.copyWith(people: people, personIdsByName: personIdsByName);
  }

  /// 把两张服事表上同一个服事项目的两个人对调。
  ///
  /// 走 repository 的 batch 而不是两次 [updateRoster]：交换的两笔缺一不可，
  /// 一边成功一边失败会留下一个人被排两天、另一个人的那天空著，而且画面上
  /// 两边看起来都换好了。
  ///
  /// 失败往上丢（见 [updateRoster]），呼叫端的 sheet 就地显示错误让人重试。
  Future<void> swapDutyPeople({
    required String sourceRosterId,
    required int sourceDutyIndex,
    required String sourcePerson,
    required String targetRosterId,
    required int targetDutyIndex,
    required String targetPerson,
  }) async {
    final sourceIndex = _allRosters.indexWhere((r) => r.id == sourceRosterId);
    final targetIndex = _allRosters.indexWhere((r) => r.id == targetRosterId);
    if (sourceIndex < 0 || targetIndex < 0) {
      throw StateError('找不到要交换的服事表，请重新整理后再试');
    }
    if (sourceIndex == targetIndex) {
      throw ArgumentError('同一天的服事不需要交换');
    }

    final source = _allRosters[sourceIndex];
    final target = _allRosters[targetIndex];
    if (sourceDutyIndex < 0 ||
        sourceDutyIndex >= source.duties.length ||
        targetDutyIndex < 0 ||
        targetDutyIndex >= target.duties.length) {
      throw StateError('服事项目已变动，请重新整理后再试');
    }

    final sourceDuty = source.duties[sourceDutyIndex];
    final targetDuty = target.duties[targetDutyIndex];

    final newSourceDuties = List<RosterEntry>.of(source.duties);
    newSourceDuties[sourceDutyIndex] = replaceDutyPerson(
      sourceDuty,
      sourcePerson,
      targetPerson,
      toId: targetDuty.personIdsByName[targetPerson],
    );
    final newTargetDuties = List<RosterEntry>.of(target.duties);
    newTargetDuties[targetDutyIndex] = replaceDutyPerson(
      targetDuty,
      targetPerson,
      sourcePerson,
      toId: sourceDuty.personIdsByName[sourcePerson],
    );

    // 换进来的人就地顶替，位置交给同工排序决定：主要同工换到别天还是排第
    // 一个，不会因为顶替的是第二个位置就跟著排第二。
    final newSource = _staffOrders.sort(
      source.copyWith(duties: newSourceDuties),
    );
    final newTarget = _staffOrders.sort(
      target.copyWith(duties: newTargetDuties),
    );

    await _repository.updateRostersAtomically([newSource, newTarget]);

    final updated = List<ServiceRoster>.of(_allRosters);
    updated[sourceIndex] = newSource;
    updated[targetIndex] = newTarget;
    _replaceRosters(updated);
    notifyListeners();
  }

  /// Batch-update rosters in parallel. On partial failure we still sync the
  /// successful writes into local state (so the UI matches Firestore truth)
  /// and then throw a summary so the caller can surface the partial error
  /// and offer "retry only failed". Plain `Future.wait` would also have
  /// written the same rows to Firestore but left local state empty,
  /// drifting the UI from the server.
  Future<void> updateRosters(List<ServiceRoster> rosters) async {
    if (rosters.isEmpty) return;
    rosters = [for (final roster in rosters) _staffOrders.sort(roster)];
    final results = await Future.wait(
      rosters.map((roster) async {
        try {
          await _repository.updateRoster(roster);
          return (
            roster: roster,
            error: null as Object?,
            stackTrace: null as StackTrace?,
          );
        } catch (e, st) {
          return (
            roster: roster,
            error: e as Object?,
            stackTrace: st as StackTrace?,
          );
        }
      }),
    );

    final successes = results.where((r) => r.error == null).toList();
    if (successes.isNotEmpty) {
      // 一次算出新清单再换上去，不要逐笔呼叫 _replaceRosterAt（那会为每笔
      // 成功的写入各复制一份完整清单）。
      final successById = {for (final r in successes) r.roster.id: r.roster};
      _replaceRosters(
        _allRosters.map((roster) => successById[roster.id] ?? roster).toList(),
      );
    }
    notifyListeners();

    final failures = results.where((r) => r.error != null).toList();
    if (failures.isNotEmpty) {
      throw PartialUpdateException(
        successCount: successes.length,
        failureCount: failures.length,
        failedRosters: failures.map((r) => r.roster).toList(),
        cause: failures.first.error!,
        causeStackTrace: failures.first.stackTrace,
      );
    }
  }

  /// 写入服事项目样板，并把改名的服事同步到现有的服事表。
  ///
  /// 失败往上丢（见 [updateRoster]）。样板写成功、但有几天的服事表没改到名
  /// 时丢 [PartialUpdateException] —— 再存一次就会补上，改过的那几天已经没有
  /// 旧名字可以换了。
  /// 写入服事项目样板，并把改名与删除同步到服事表和同工排序。
  ///
  /// 改名套到每一张载入的服事表。删除只套到今天以后的：已经过去的那几周
  /// 是纪录，当时确实排了这一项。以前删除完全不同步，样板少了一项，每一
  /// 周的服事表却还挂著它，只能一周一周手动删。
  ///
  /// [renamedRolesByType] 的 key 是改名前的名字，那些不算删除。
  Future<void> updateTemplates(
    Map<ServiceType, List<String>> newTemplates, {
    Map<ServiceType, Map<String, String>> renamedRolesByType = const {},
  }) async {
    try {
      // 样板还没载入过就不知道少了哪几项，这时不删任何东西。
      final removedRolesByType = _templatesLoaded
          ? _removedRoles(_templates, newTemplates, renamedRolesByType)
          : const <ServiceType, Set<String>>{};

      await _repository.updateServiceTemplates(newTemplates);
      _templates = Map.from(newTemplates);
      _templatesLoaded = true;

      if (renamedRolesByType.isNotEmpty || removedRolesByType.isNotEmpty) {
        final now = _now();
        final today = ChurchTime.dateOnly(now);
        final updatedRosters = <ServiceRoster>[];
        for (final roster in _allRosters) {
          final renameMap = renamedRolesByType[roster.type] ?? const {};
          final removed = ChurchTime.dateOnly(roster.date).isBefore(today)
              ? const <String>{}
              : removedRolesByType[roster.type] ?? const <String>{};
          if (renameMap.isEmpty && removed.isEmpty) continue;

          var hasChanges = false;
          final updatedDuties = <RosterEntry>[];
          for (final duty in roster.duties) {
            if (removed.contains(duty.role)) {
              hasChanges = true;
              continue;
            }
            final renamedRole = renameMap[duty.role];
            if (renamedRole == null || renamedRole == duty.role) {
              updatedDuties.add(duty);
              continue;
            }
            hasChanges = true;
            updatedDuties.add(duty.copyWith(role: renamedRole));
          }

          if (!hasChanges) {
            continue;
          }

          updatedRosters.add(roster.copyWith(duties: updatedDuties));
        }

        await _syncStaffOrderRoles(renamedRolesByType, removedRolesByType);

        // 走 updateRosters 而不是 Future.wait：后者一笔失败就整批当作没
        // 写，成功的那几天在画面上还是旧名字。
        await updateRosters(updatedRosters);
      }

      notifyListeners();
    } catch (e, st) {
      log('更新服事表样板失败', error: e, stackTrace: st);
      rethrow;
    }
  }

  /// [before] 有、[after] 没有、也不是改名前的名字的服事项目。
  static Map<ServiceType, Set<String>> _removedRoles(
    Map<ServiceType, List<String>> before,
    Map<ServiceType, List<String>> after,
    Map<ServiceType, Map<String, String>> renamedRolesByType,
  ) {
    final result = <ServiceType, Set<String>>{};
    for (final entry in after.entries) {
      final kept = entry.value.toSet();
      final renamedFrom = renamedRolesByType[entry.key]?.keys.toSet() ?? {};
      final removed = {
        for (final role in before[entry.key] ?? const <String>[])
          if (!kept.contains(role) && !renamedFrom.contains(role)) role,
      };
      if (removed.isNotEmpty) result[entry.key] = removed;
    }
    return result;
  }

  /// 服事项目改名时把存下来的同工排序搬到新名字，删掉的项目连排序一起删。
  ///
  /// 失败只记 log、不往上丢 —— 这个 provider 写入失败一律往上丢的唯一例外：
  /// 样板已经写进去了，这时报失败会让人以为改名没成功。排序没搬到的后果只
  /// 是那一项退回从服事表学的顺序，而服事表本来就照旧的排序存，学回来的是
  /// 同一份；没删到的只是留一笔没人用的排序。
  Future<void> _syncStaffOrderRoles(
    Map<ServiceType, Map<String, String>> renamedRolesByType,
    Map<ServiceType, Set<String>> removedRolesByType,
  ) async {
    for (final type in {
      ...renamedRolesByType.keys,
      ...removedRolesByType.keys,
    }) {
      try {
        await _writeStaffOrder(
          type,
          _staffOrders
              .storedFor(type)
              .withRolesRenamed(renamedRolesByType[type] ?? const {})
              .withChanges({
                for (final role in removedRolesByType[type] ?? const <String>{})
                  role: null,
              }),
        );
      } catch (e, st) {
        log('同工排序同步失败（该项退回服事表上的顺序）', error: e, stackTrace: st);
      }
    }
  }

  /// 把 [type] 存著的排序改成 [next]。只写有变的服事项目（见
  /// [StaffOrder.changesTo]），没变就不写。失败往上丢，本机什么都不动。
  Future<void> _writeStaffOrder(ServiceType type, StaffOrder next) async {
    final changes = _staffOrders.storedFor(type).changesTo(next);
    if (changes.isEmpty) return;
    await _repository.updateStaffRankings(type, changes);
    _staffOrders = _staffOrders.withStoredFor(type, next);
    _replaceRosters(_allRosters);
    notifyListeners();
  }

  /// 在选人视窗拖过顺序之后，把那个服事项目的排序换成 [ranking]。
  ///
  /// 换掉的是整个崇拜的这一项，不是这一天：画面上每一天的这一项都会照新
  /// 顺序重排。失败往上丢（见 [updateRoster]）。
  Future<void> updateStaffRanking(ServiceType type, StaffRanking ranking) =>
      _writeStaffOrder(
        type,
        _staffOrders.storedFor(type).withRanking(ranking.role, ranking.names),
      );

  /// 写一次汇入：先把图片上学到的排序并进存著的那份，再写服事表。
  ///
  /// 顺序不能反：服事表写入时照排序重排，排序还是旧的就会把图片上的顺序打
  /// 乱。图片是负责人排好发出来的，比之前在这里拖过的顺序新，所以图片上的
  /// 人照图片排；这次没出现的人留在原位（见 [StaffOrder.mergedWith]）。
  ///
  /// 排序写失败时原样往上丢，一张服事表都还没动；服事表写失败时丢
  /// [PartialUpdateException]（见 [updateRosters]）。
  Future<void> applyRosterImport(
    ServiceType type,
    RosterImportReady ready,
  ) async {
    await _writeStaffOrder(
      type,
      _staffOrders.storedFor(type).mergedWith(ready.staffOrder),
    );
    await updateRosters(ready.updates);
  }

  /// 把一个活动加进 [type] 的活动清单，颜色自动挑（见 [pickEventColor]）。
  ///
  /// 给汇入结果上的「加入活动清单」用。失败往上丢，那颗按钮在自己那一列
  /// 显示失败。
  ///
  /// 已经有同名的就什么都不写，直接回那一笔 —— 重按、或两个崇拜的汇入先后
  /// 按到同一个活动，都不该多出一笔重复的。
  ///
  /// 先读一份最新的再写，而不是用这台装置上的快取：活动清单是整份文件写回
  /// 去的，拿快取来写，另一台装置在这段期间改的活动设定会被静静盖掉。剩下
  /// 的空窗只有读与写之间那一下。
  Future<EventOption> addEventOption(ServiceType type, String name) async {
    final options = Map.of(await _repository.getEventOptions());
    final list = List<EventOption>.from(options[type] ?? const []);
    for (final option in list) {
      if (option.name == name) {
        // 别台装置刚加过。什么都不写，但这台的快取也跟上，颜色才会出来。
        _replaceEventOptions(options);
        notifyListeners();
        return option;
      }
    }
    final added = EventOption(name: name, color: pickEventColor(list));
    options[type] = [...list, added];
    await _repository.updateEventOptions(options);
    _replaceEventOptions(options);
    notifyListeners();
    return added;
  }

  /// 写入活动清单，并把改名的活动（连同自订颜色）同步到现有的服事表。
  ///
  /// 失败往上丢，部分失败的语意同 [updateTemplates]。
  Future<void> updateEventOptions(
    Map<ServiceType, List<EventOption>> options, {
    Map<ServiceType, Map<String, String>> renamedEventsByType = const {},
  }) async {
    try {
      await _repository.updateEventOptions(options);
      _replaceEventOptions(
        Map.fromEntries(
          options.entries.map(
            (entry) => MapEntry(entry.key, List<EventOption>.from(entry.value)),
          ),
        ),
      );

      if (renamedEventsByType.isNotEmpty) {
        final updatedRosters = <ServiceRoster>[];
        for (final roster in _allRosters) {
          final renameMap = renamedEventsByType[roster.type];
          if (renameMap == null || renameMap.isEmpty) {
            continue;
          }

          var hasChanges = false;
          final updatedEvents = roster.specialEvents.map((event) {
            final renamedEvent = renameMap[event];
            if (renamedEvent == null || renamedEvent == event) {
              return event;
            }
            hasChanges = true;
            return renamedEvent;
          }).toList();

          final newColors = Map<String, int>.from(roster.customEventColors);
          for (final entry in renameMap.entries) {
            final oldName = entry.key;
            final newName = entry.value;
            if (oldName == newName) continue;
            if (newColors.containsKey(oldName)) {
              newColors[newName] = newColors.remove(oldName)!;
              hasChanges = true;
            }
          }

          if (!hasChanges) {
            continue;
          }

          final updated = roster.copyWith(
            specialEvents: updatedEvents,
            customEventColors: newColors,
          );
          updatedRosters.add(updated);
        }

        await updateRosters(updatedRosters);
      }

      notifyListeners();
    } catch (e, st) {
      log('更新事件选项失败', error: e, stackTrace: st);
      rethrow;
    }
  }
}

class PartialUpdateException implements Exception {
  final int successCount;
  final int failureCount;
  final List<ServiceRoster> failedRosters;
  final Object cause;
  final StackTrace? causeStackTrace;

  PartialUpdateException({
    required this.successCount,
    required this.failureCount,
    required this.failedRosters,
    required this.cause,
    this.causeStackTrace,
  });

  @override
  String toString() => '$successCount 笔写入成功，$failureCount 笔失败（首个错误：$cause）';
}
