import 'dart:convert';
import 'dart:developer';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../auth/presentation/providers/session_provider.dart';
import '../../../../core/config/church_config.dart';
import '../../../../core/config/google_calendar_config.dart';
import '../../../../core/time/church_time.dart';
import '../../../calendar/data/google_calendar_event.dart';
import '../../../../core/services/external_link_service.dart';
import '../../../../core/services/install_hint_service.dart';
import '../../../../core/utils/error_messages.dart';
import '../../domain/entities/recent_activity.dart';
import '../../domain/season_window.dart';
import '../widgets/recent_activity_row.dart';
import '../widgets/add_to_home_card.dart';
import '../../../checkin/presentation/checkin_card.dart';
import '../../../attendance/presentation/attendance_screen.dart';
import '../../../auth/domain/entities/user.dart' show UserRole;
import '../../../roster/domain/entities/service_roster.dart';
import '../../../roster/presentation/providers/roster_provider.dart';
import '../../../calendar/presentation/screens/calendar_screen.dart'
    deferred as calendar;

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({
    super.key,
    this.httpClient,
    this.idToken,
    this.installHints = const InstallHintService(),
  });

  /// Tests supply a transport so optional integrations never contact a server.
  final http.Client? httpClient;

  /// Tests supply the sign-in token for the site's own API.
  final Future<String?> Function()? idToken;

  /// Tests supply the phone/browser the add-to-home card sees.
  final InstallHintService installHints;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  static const int _recentActivitiesLimit = 3;
  static const int _recentActivitiesFetchMax = 20;
  static const _dailyBreadRangeFallback = '查看今日经文范围';

  static final _whitespaceRe = RegExp(r'\s+');
  static final _latinRe = RegExp(r'[A-Za-z]');
  static final _cjkRe = RegExp(r'[一-鿿]');

  bool _isLoadingCalendar = false;
  bool _isLoadingDailyBreadRange = false;
  bool _isLoadingRecentActivities = false;
  String? _dailyBreadRange;
  String? _recentActivitiesError;
  List<RecentActivity> _recentActivities = const [];

  final ScrollController _seasonScrollController = ScrollController();

  // 追踪上一次的 userId，用来在 didChangeDependencies 侦测帐号切换。
  String? _lastUserId;

  @override
  void initState() {
    super.initState();
    _loadDailyBreadRange();
    // 近期活动不在这里抓：didChangeDependencies 在第一次 build 前必定会跑，
    // 且 _lastUserId 初始为 null，所以首次进画面就会由它触发一次。
    // 两边都抓会让每次开首页都打两次 Google Calendar API。
  }

  @override
  void dispose() {
    _seasonScrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final userId = context.read<SessionProvider>().currentUser?.id;
    if (userId == _lastUserId) return;
    _lastUserId = userId;

    if (userId != null) {
      // 首次进画面、登入或切换帐号：抓近期活动
      //（RosterProvider cache 已由 ProxyProvider 清掉）。
      _loadRecentActivities();
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<SessionProvider>().currentUser;
    final fullName = user?.name ?? '';
    final displayName = _displayName(fullName);
    return Scaffold(
      appBar: AppBar(title: const Text('首页'), centerTitle: true),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '欢迎回来，$displayName！',
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),
            AddToHomeCard(service: widget.installHints),
            const CheckinCard(),
            const SizedBox(height: 16),
            if (user != null &&
                (user.role == UserRole.admin ||
                    user.role == UserRole.leader)) ...[
              Card(
                elevation: 2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: ListTile(
                  leading: const Icon(Icons.fact_check_outlined),
                  title: const Text(
                    '出勤',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(
                    user.role == UserRole.admin ? '全部成员的打卡记录' : '本小组的打卡记录',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const AttendanceScreen(),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            if (ChurchConfig.current.devotional.enabled) ...[
              _buildFeatureCard(
                context,
                icon: Icons.menu_book_rounded,
                title: ChurchConfig.current.devotional.sourceName,
                description: _dailyBreadDescription,
                color: Colors.orangeAccent,
                onTap: _openDailyBread,
              ),
              const SizedBox(height: 16),
            ],
            if (GoogleCalendarConfig.isEnabled) ...[
              _buildCalendarFeatureCard(context),
              const SizedBox(height: 20),
            ],
            _buildSeasonServiceSection(
              context,
              fullName: fullName,
              userId: user?.id,
            ),
          ],
        ),
      ),
    );
  }

  String _displayName(String? fullName) {
    final name = fullName?.trim() ?? '';
    if (name.isEmpty) return '同工';

    final parts = name.split(_whitespaceRe).where((p) => p.isNotEmpty).toList();
    final hasLatin = _latinRe.hasMatch(name);
    if (parts.length > 1) {
      return hasLatin ? parts.first : parts.last;
    }

    // 三个字的中文名最常见是单姓＋两字名，叫名字比较亲切（王小明 → 小明）。
    // 两个字（李安）或四个字以上（复姓、「测试管理员」这种非人名）就整个叫，
    // 否则会变成「安」「试管理员」。
    if (_cjkRe.hasMatch(name) && name.length == 3) {
      return name.substring(1);
    }

    return name;
  }

  Future<void> _openCalendar() async {
    if (!GoogleCalendarConfig.isEnabled || _isLoadingCalendar) return;
    setState(() {
      _isLoadingCalendar = true;
    });

    try {
      await calendar.loadLibrary();
      if (!mounted) return;
      await Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => calendar.CalendarScreen()));
    } catch (error, st) {
      log('载入行事历画面失败', error: error, stackTrace: st);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('载入失败：${mapErrorToUserMessage(error)}')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingCalendar = false;
        });
      }
    }
  }

  Future<void> _openDailyBread() async {
    final devotional = ChurchConfig.current.devotional;
    if (!devotional.enabled) return;
    final launched = await openExternalLink(devotional.linkUrl);
    if (!launched && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法打开每日灵粮页面')));
    }
  }

  String get _dailyBreadDescription {
    final range = _dailyBreadRange?.trim();
    if (range != null && range.isNotEmpty) {
      return range;
    }
    if (_isLoadingDailyBreadRange) {
      return '载入今日经文范围中...';
    }
    return _dailyBreadRangeFallback;
  }

  Future<void> _loadDailyBreadRange() async {
    if (!ChurchConfig.current.devotional.enabled) return;
    if (mounted) {
      setState(() {
        _isLoadingDailyBreadRange = true;
      });
    }

    final cached = await _loadCachedDailyBreadRange();
    if (mounted && cached != null && cached.isNotEmpty) {
      setState(() {
        _dailyBreadRange = cached;
      });
    }

    try {
      final fetched = await _fetchDailyBreadRange();
      if (fetched != null && fetched.isNotEmpty) {
        await _saveCachedDailyBreadRange(fetched);
      }
      if (!mounted) return;
      setState(() {
        _dailyBreadRange = fetched ?? _dailyBreadRange;
      });
    } catch (_) {
      // Keep cached or fallback text when the source cannot be reached.
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingDailyBreadRange = false;
        });
      }
    }
  }

  static const String _dailyBreadKeyPrefix = 'dashboard_daily_bread_range_';

  String _cacheKeyForDailyBreadRange() {
    final today = DateFormat('yyyy-MM-dd').format(ChurchTime.now());
    return '$_dailyBreadKeyPrefix${Uri.encodeComponent(ChurchConfig.current.devotional.dataUrl)}_$today';
  }

  /// key 带日期，每天都会产生新的一笔。不清掉的话 localStorage 会无限长大，
  /// 用久了可能撞到浏览器的 quota。写新的时候顺手把旧的删掉。
  Future<void> _pruneDailyBreadCache(
    SharedPreferences prefs,
    String currentKey,
  ) async {
    for (final key in prefs.getKeys().toList()) {
      if (key.startsWith(_dailyBreadKeyPrefix) && key != currentKey) {
        await prefs.remove(key);
      }
    }
  }

  Future<String?> _loadCachedDailyBreadRange() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_cacheKeyForDailyBreadRange());
    if (cached == null || cached.isEmpty) return null;
    return cached;
  }

  Future<void> _saveCachedDailyBreadRange(String range) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _cacheKeyForDailyBreadRange();
    await prefs.setString(key, range);
    await _pruneDailyBreadCache(prefs, key);
  }

  Future<String?> _fetchDailyBreadRange() async {
    final today = DateFormat('yyyy-MM-dd').format(ChurchTime.now());
    String? raw;
    try {
      raw = await _fetchDailyVerseFromData(today);
    } catch (e, st) {
      log('daily verse data fetch failed', error: e, stackTrace: st);
    }
    // 资料分支靠 GitHub 排程每天更新，但排程常晚好几个小时（凌晨一点排的，
    // 实际三、四点才跑），这段时间首页会看不到今天的范围。还没更新时改请
    // 网站当场读一次来源。
    raw ??= await _fetchDailyVerseFromSite(today);
    if (raw == null || raw.isEmpty) return null;
    return _normalizeBibleRange(raw);
  }

  Future<String?> _fetchDailyVerseFromData(String today) async {
    final uri = Uri.parse(ChurchConfig.current.devotional.dataUrl);
    final datedUri = uri.replace(
      queryParameters: {...uri.queryParameters, 'd': today},
    );
    final response =
        await (widget.httpClient?.get(datedUri) ?? http.get(datedUri)).timeout(
          const Duration(seconds: 10),
        );
    if (response.statusCode != 200) {
      throw Exception('daily_verse_fetch_failed_${response.statusCode}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if ((data['date'] as String?) != today) return null;
    return data['rawRange'] as String?;
  }

  static Future<String?> _firebaseIdToken() async {
    try {
      return await FirebaseAuth.instance.currentUser?.getIdToken();
    } catch (_) {
      return null;
    }
  }

  /// 见 functions/api/devotional/today.js。失败一律当作没有，首页显示预设文字。
  Future<String?> _fetchDailyVerseFromSite(String today) async {
    if (ChurchConfig.current.devotional.fetchUrl.isEmpty) return null;
    try {
      final token = await (widget.idToken ?? _firebaseIdToken)();
      if (token == null || token.isEmpty) return null;
      final uri = Uri.base.resolve('/api/devotional/today');
      final headers = {'Authorization': 'Bearer $token'};
      final response =
          await (widget.httpClient?.get(uri, headers: headers) ??
                  http.get(uri, headers: headers))
              .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return null;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if ((data['date'] as String?) != today) return null;
      return data['rawRange'] as String?;
    } catch (e, st) {
      log('daily verse fallback failed', error: e, stackTrace: st);
      return null;
    }
  }

  String _normalizeBibleRange(String? raw) {
    if (raw == null || raw.isEmpty) return '';

    final normalizedPunctuation = raw
        .replaceAll('：', ':')
        .replaceAll('，', ',')
        .trim();
    final singleRangePattern = RegExp(
      r'^(.+?)([零一二三四五六七八九十百千两〇]+):(\d+)-([零一二三四五六七八九十百千两〇]+):(\d+)$',
    );
    final singleChapterPattern = RegExp(
      r'^(.+?)([零一二三四五六七八九十百千两〇]+):(\d+)-(\d+)$',
    );

    final singleRangeMatch = singleRangePattern.firstMatch(
      normalizedPunctuation,
    );
    if (singleRangeMatch != null) {
      final book = singleRangeMatch.group(1)!;
      final startChapter = _chineseNumberToArabic(singleRangeMatch.group(2)!);
      final startVerse = singleRangeMatch.group(3)!;
      final endChapter = _chineseNumberToArabic(singleRangeMatch.group(4)!);
      final endVerse = singleRangeMatch.group(5)!;

      if (startChapter == endChapter) {
        return '$book$startChapter:$startVerse-$endVerse';
      }
      return '$book$startChapter:$startVerse-$endChapter:$endVerse';
    }

    final singleChapterMatch = singleChapterPattern.firstMatch(
      normalizedPunctuation,
    );
    if (singleChapterMatch != null) {
      final book = singleChapterMatch.group(1)!;
      final chapter = _chineseNumberToArabic(singleChapterMatch.group(2)!);
      final startVerse = singleChapterMatch.group(3)!;
      final endVerse = singleChapterMatch.group(4)!;
      return '$book$chapter:$startVerse-$endVerse';
    }

    return normalizedPunctuation.replaceAllMapped(
      RegExp(r'[零一二三四五六七八九十百千两〇]+'),
      (match) => _chineseNumberToArabic(match.group(0)!),
    );
  }

  String _chineseNumberToArabic(String value) {
    const digitMap = {
      '零': 0,
      '〇': 0,
      '一': 1,
      '二': 2,
      '两': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
    };
    const unitMap = {'十': 10, '百': 100, '千': 1000};

    var result = 0;
    var section = 0;
    var number = 0;

    for (final rune in value.runes) {
      final char = String.fromCharCode(rune);
      final digit = digitMap[char];
      if (digit != null) {
        number = digit;
        continue;
      }

      final unit = unitMap[char];
      if (unit != null) {
        section += (number == 0 ? 1 : number) * unit;
        number = 0;
      }
    }

    result += section + number;
    return result == 0 && !value.contains('零') && !value.contains('〇')
        ? value
        : result.toString();
  }

  Future<void> _loadRecentActivities() async {
    if (!GoogleCalendarConfig.isEnabled) return;
    if (mounted) {
      setState(() {
        _isLoadingRecentActivities = true;
        _recentActivitiesError = null;
      });
    }

    final cached = await _loadCachedRecentActivities();
    final cachedUpcoming = _mergeUpcomingEvents(cached);

    if (mounted && cachedUpcoming.isNotEmpty) {
      setState(() {
        _recentActivities = cachedUpcoming;
      });
    }

    try {
      final fetched = await _fetchRecentActivities();
      final fetchedUpcoming = _mergeUpcomingEvents(fetched);
      await _saveCachedRecentActivities(fetchedUpcoming);

      if (!mounted) return;
      setState(() {
        _recentActivities = fetchedUpcoming;
        _recentActivitiesError = null;
      });
    } catch (_) {
      if (!mounted) return;
      if (cachedUpcoming.isEmpty) {
        setState(() {
          _recentActivitiesError = '近期活动载入失败';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingRecentActivities = false;
        });
      }
    }
  }

  List<RecentActivity> _mergeUpcomingEvents(List<RecentActivity> events) =>
      selectRecentActivities(
        events,
        now: ChurchTime.now(),
        limit: _recentActivitiesLimit,
      );

  String _cacheKeyForRecentActivities() {
    // v1 的内容没有 endTime，跨日活动会被当成一日活动。升版让旧快取自然作废。
    return 'dashboard_recent_activities_v3_${Uri.encodeComponent(GoogleCalendarConfig.calendarId)}_${GoogleCalendarConfig.timeZone}';
  }

  Future<List<RecentActivity>> _loadCachedRecentActivities() async {
    final prefs = await SharedPreferences.getInstance();
    final key = _cacheKeyForRecentActivities();
    final cached = prefs.getString(key);
    if (cached == null || cached.isEmpty) return const [];

    try {
      final data = jsonDecode(cached) as List<dynamic>;
      return data
          .map((raw) => RecentActivity.fromJson(raw as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _saveCachedRecentActivities(List<RecentActivity> events) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _cacheKeyForRecentActivities();
    final payload = jsonEncode(events.map((event) => event.toJson()).toList());
    await prefs.setString(key, payload);
  }

  Future<List<RecentActivity>> _fetchRecentActivities() async {
    if (!GoogleCalendarConfig.isEnabled) return const [];
    final todayStart = ChurchTime.atDate(ChurchTime.today()).toUtc();

    final uri =
        Uri.https('www.googleapis.com', '', {
          'key': GoogleCalendarConfig.apiKey,
          'singleEvents': 'true',
          'orderBy': 'startTime',
          'maxResults': _recentActivitiesFetchMax.toString(),
          'timeMin': todayStart.toIso8601String(),
          'timeZone': GoogleCalendarConfig.timeZone,
          // 一定要拿 end：没有它就无法判断跨日活动是否仍在进行，
          // 也无法显示区间。timeMin 本来就是以 end 过滤，资料一直都在。
          'fields': 'items(status,start,end,summary)',
        }).replace(
          pathSegments: [
            'calendar',
            'v3',
            'calendars',
            GoogleCalendarConfig.calendarId,
            'events',
          ],
        );

    final response = await (widget.httpClient?.get(uri) ?? http.get(uri))
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw Exception('calendar_fetch_failed_${response.statusCode}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final items = data['items'] as List<dynamic>? ?? [];
    final events = <RecentActivity>[];

    for (var i = 0; i < items.length; i++) {
      try {
        final event = calendarEventFromGoogleItem(
          items[i] as Map<String, dynamic>,
          fallbackIndex: i,
        );
        if (event == null) continue;
        events.add(
          RecentActivity(
            startTime: event.startTime,
            endTime: event.endTime,
            title: event.title,
            isAllDay: event.isAllDay,
          ),
        );
      } catch (e, st) {
        debugPrint('Skipping malformed calendar item #$i: $e');
        debugPrintStack(stackTrace: st);
      }
    }

    return events;
  }

  Widget _buildCalendarFeatureCard(BuildContext context) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Column(
        children: [
          ListTile(
            leading: CircleAvatar(
              backgroundColor: Colors.purpleAccent.withValues(alpha: 0.2),
              child: const Icon(
                Icons.calendar_month,
                color: Colors.purpleAccent,
              ),
            ),
            title: const Text(
              '行事历',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: const Text('教会年度活动一览'),
            trailing: _isLoadingCalendar
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.chevron_right),
            enabled: !_isLoadingCalendar,
            onTap: _openCalendar,
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: _buildRecentActivitiesContent(),
          ),
        ],
      ),
    );
  }

  Widget _buildRecentActivitiesContent() {
    if (_isLoadingRecentActivities && _recentActivities.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    if (_recentActivitiesError != null && _recentActivities.isEmpty) {
      return Text(
        _recentActivitiesError!,
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      );
    }

    if (_recentActivities.isEmpty) {
      return const Text('近期暂无活动');
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('近期活动', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        ..._recentActivities.map((event) => RecentActivityRow(activity: event)),
      ],
    );
  }

  Widget _buildSeasonServiceSection(
    BuildContext context, {
    required String fullName,
    required String? userId,
  }) {
    final window = seasonWindow(ChurchTime.today());
    return Consumer<RosterProvider>(
      builder: (context, provider, child) {
        // 仅在 isLoading 且 cache 尚无资料时显示 spinner（stale-while-revalidate）。
        // 若 IndexedDB cache 已有 roster，isLoading 仍可能为 true，但直接显示卡内容。
        if (provider.isLoading && provider.rosters.isEmpty) {
          return _buildSectionCard(
            title: window.title,
            icon: Icons.volunteer_activism,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Center(child: CircularProgressIndicator()),
                  const SizedBox(height: 12),
                  Text(
                    '载入近期活动中…',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          );
        }

        if (provider.error != null) {
          return _buildSectionCard(
            title: window.title,
            icon: Icons.volunteer_activism,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  provider.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: () => provider.fetchInitialData(),
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试'),
                ),
              ],
            ),
          );
        }

        final assignments = _seasonAssignments(
          rosters: provider.rosters,
          userName: fullName,
          userId: userId,
        );
        if (assignments.isEmpty) {
          final emptyText = fullName.trim().isEmpty
              ? '尚未登入同工资料'
              : window.emptyText;
          return _buildSectionCard(
            title: window.title,
            icon: Icons.volunteer_activism,
            child: Text(emptyText),
          );
        }

        return _buildSectionCard(
          title: window.title,
          icon: Icons.volunteer_activism,
          child: SizedBox(
            height: _seasonListHeight(assignments.length),
            child: Scrollbar(
              controller: _seasonScrollController,
              thumbVisibility: assignments.length > 5,
              child: ListView.separated(
                controller: _seasonScrollController,
                itemCount: assignments.length,
                separatorBuilder: (_, itemIndex) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final assignment = assignments[index];
                  final dateText = DateFormat(
                    'MM/dd (EEEEE)',
                    'zh_CN',
                  ).format(assignment.roster.date);
                  final roleText = assignment.roles.join('、');
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 90,
                        child: Text(
                          dateText,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              assignment.roster.displayName,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(roleText),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  double _seasonListHeight(int itemCount) {
    const maxVisibleItems = 3;
    const rowHeight = 48.0;
    const separatorHeight = 8.0;
    final visibleCount = itemCount < maxVisibleItems
        ? itemCount
        : maxVisibleItems;
    if (visibleCount <= 0) return 0;
    return (visibleCount * rowHeight) + ((visibleCount - 1) * separatorHeight);
  }

  // 上一次算出来的本季服事，避免每次 setState（推播开关、每日灵粮载入…）
  // 都重排一次全部 roster。RosterProvider 的 rosters 在资料没变时是同一个
  // reference，所以用 identical 判断就够。
  List<ServiceRoster>? _assignmentsSourceRosters;
  String? _assignmentsSourceKey;
  List<_UserServiceAssignment> _cachedAssignments = const [];

  List<_UserServiceAssignment> _seasonAssignments({
    required List<ServiceRoster> rosters,
    required String userName,
    required String? userId,
  }) {
    // key 必须含日期：季度区间是从 ChurchTime.now() 推导的，App 一直开著跨过
    // 季末时，只看 rosters identity 的话会永远回传上一季的结果。
    final today = ChurchTime.today();
    final sourceKey = '$userId|$userName|${today.toIso8601String()}';
    if (identical(rosters, _assignmentsSourceRosters) &&
        sourceKey == _assignmentsSourceKey) {
      return _cachedAssignments;
    }

    final computed = _computeSeasonAssignments(
      rosters: rosters,
      userName: userName,
      userId: userId,
    );
    _assignmentsSourceRosters = rosters;
    _assignmentsSourceKey = sourceKey;
    _cachedAssignments = computed;
    return computed;
  }

  List<_UserServiceAssignment> _computeSeasonAssignments({
    required List<ServiceRoster> rosters,
    required String userName,
    required String? userId,
  }) {
    final normalizedName = _normalizeName(userName);
    final normalizedId = userId?.trim() ?? '';
    if (normalizedName.isEmpty && normalizedId.isEmpty) return [];

    final List<_UserServiceAssignment> results = [];
    final window = seasonWindow(ChurchTime.today());
    final sorted = List<ServiceRoster>.from(rosters)
      ..sort((a, b) => a.date.compareTo(b.date));

    for (final roster in sorted) {
      if (roster.date.isBefore(window.start) ||
          roster.date.isAfter(window.end)) {
        continue;
      }
      final roles = roster.duties
          .where((duty) => _isAssignedTo(duty, normalizedId, normalizedName))
          .map((duty) => duty.role)
          .toList();
      if (roles.isEmpty) continue;
      results.add(_UserServiceAssignment(roster: roster, roles: roles));
    }

    return results;
  }

  /// 判断这笔 duty 是否排到本人。
  ///
  /// uid 相符直接算数（改名之后照样对得上）；uid 对不上时仍会退回姓名比对。
  ///
  /// 刻意不把 uid 当成唯一权威：roster 里存的 uid 可能已经过期 —— 例如同工
  /// 原本没有 email、admin 后来补上时会建立全新的 Auth 帐号并换掉 user 文件
  /// id，既有 roster 的 personIdsByName 仍指向旧 id。那种情况下若因为
  /// 「有 uid 但不相符」就跳过姓名比对，本人会在首页看到「本季尚无排到服事」，
  /// 但服事表分页明明列著他。漏掉自己的服事比同名误判严重得多。
  bool _isAssignedTo(
    RosterEntry duty,
    String normalizedId,
    String normalizedName,
  ) {
    for (final person in duty.people) {
      final trimmed = person.trim();
      if (trimmed.isEmpty) continue;

      final linkedId = duty.personIdsByName[trimmed]?.trim() ?? '';
      if (normalizedId.isNotEmpty && linkedId == normalizedId) return true;

      if (normalizedName.isNotEmpty &&
          _normalizeName(trimmed) == normalizedName) {
        return true;
      }
    }
    return false;
  }

  String _normalizeName(String name) {
    return name.trim().toLowerCase();
  }

  Widget _buildSectionCard({
    required String title,
    required Widget child,
    IconData? icon,
  }) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (icon != null) ...[
                  Icon(
                    icon,
                    size: 18,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                ],
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }

  Widget _buildFeatureCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String description,
    required Color color,
    VoidCallback? onTap,
  }) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.2),
          child: Icon(icon, color: color),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(description),
        onTap:
            onTap ??
            () {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('此功能即将推出！')));
            },
      ),
    );
  }
}

class _UserServiceAssignment {
  final ServiceRoster roster;
  final List<String> roles;

  const _UserServiceAssignment({required this.roster, required this.roles});
}
