import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/config/google_calendar_config.dart';
import '../../../core/time/church_time.dart';
import '../domain/entities/calendar_event.dart';
import 'google_calendar_month_reader.dart';

/// Reads one month of events. [GoogleCalendarMonthReader.fetchMonth] in the
/// app; tests hand in their own so they control what arrives and when.
typedef CalendarMonthFetcher =
    Future<List<CalendarEvent>> Function(DateTime month);

/// The events the calendar screen shows, one month at a time.
///
/// Owns everything between "the user paged to October" and "October's events
/// are on screen": the SharedPreferences copy that paints instantly, the Google
/// read behind it, the freshness gate that keeps paging from burning API quota,
/// and patching the lists after an admin write so the grid does not wait for a
/// round trip.
///
/// Every change to a month replaces its list rather than editing it in place,
/// so `identical()` on [eventsForMonth] is enough to tell whether a cached
/// layout is still good.
class CalendarMonthStore with ChangeNotifier {
  /// 同一个月在这段时间内不重抓。没有这道闸门的话，每次左右换页都会对
  /// 当月 + 前后月各打一次 Google Calendar API，来回滑几次就烧掉配额。
  static const Duration monthFreshness = Duration(minutes: 10);

  /// SharedPreferences 只保留距今前后这么多个月的快取，避免 key 无限累积。
  static const int _cacheKeepMonths = 12;
  static String get _cacheKeyPrefix =>
      'calendar_events_v2_${Uri.encodeComponent(GoogleCalendarConfig.calendarId)}_'
      '${Uri.encodeComponent(GoogleCalendarConfig.timeZone)}_';

  final CalendarMonthFetcher _fetchMonth;
  final DateTime Function() _now;
  final Future<SharedPreferences> Function() _prefs;

  final Map<String, List<CalendarEvent>> _eventsByMonth = {};
  final Set<String> _loadingMonths = {};
  final Map<String, String?> _errorsByMonth = {};
  final Map<String, DateTime> _fetchedAtByMonth = {};

  // 每个月的写入世代。写入时 +1；fetch 开始时记下当时的值，回来时若已经
  // 不同，代表这份回应是在写入之前发出去的 —— 它不知道那笔写入，套上去会
  // 盖掉本地 patch 还盖上新鲜戳记，错的资料会挂十分钟。所以丢掉，重抓。
  final Map<String, int> _writeGeneration = {};

  bool _disposed = false;

  /// [prefs] exists so a test can hand in storage that fails, the way a full
  /// localStorage does on a phone.
  CalendarMonthStore({
    CalendarMonthFetcher? fetchMonth,
    DateTime Function()? now,
    Future<SharedPreferences> Function()? prefs,
  }) : _fetchMonth = fetchMonth ?? GoogleCalendarMonthReader().fetchMonth,
       _now = now ?? ChurchTime.now,
       _prefs = prefs ?? SharedPreferences.getInstance;

  /// The month's events, or null if nothing has arrived for it yet — neither
  /// from the device cache nor from Google.
  List<CalendarEvent>? eventsForMonth(DateTime month) =>
      _eventsByMonth[_keyFor(month)];

  /// Why the month failed to load, ready to show; null when it did not fail.
  String? errorForMonth(DateTime month) => _errorsByMonth[_keyFor(month)];

  /// Puts [month] on screen as soon as possible and refreshes it if due.
  ///
  /// The device cache and Google are asked at the same time: the cache paints
  /// the month straight away, Google replaces it when it answers. A month read
  /// from Google within [monthFreshness] is left alone.
  Future<void> ensureLoaded(DateTime month) =>
      Future.wait([_loadCached(month), _fetch(month)]);

  /// An admin write went through: patch what is on screen now, then refetch
  /// every month either version of the event touches.
  ///
  /// The server has already accepted the change, so the patch is not
  /// optimistic — it only saves the user from watching the old event sit there
  /// for a round trip. The refetch is what makes the cache authoritative again.
  void applyWrite({CalendarEvent? removed, CalendarEvent? added}) {
    if (_disposed) return;
    final touched = <String>{};

    if (removed != null) {
      // Scans every loaded month rather than only the ones the event spans:
      // an edit that moves an event has to clear it out of wherever it used
      // to sit, and that span is not always the span being passed in.
      for (final entry in _eventsByMonth.entries) {
        if (!entry.value.any((existing) => existing.id == removed.id)) {
          continue;
        }
        _eventsByMonth[entry.key] = List.unmodifiable(
          entry.value.where((existing) => existing.id != removed.id),
        );
        touched.add(entry.key);
      }
    }

    if (added != null) {
      for (final month in monthsSpannedBy(added)) {
        final key = _keyFor(month);
        // A month that was never loaded has nothing to patch; it will fetch
        // the event normally when the user pages to it.
        final events = _eventsByMonth[key];
        if (events == null) continue;
        _eventsByMonth[key] = List.unmodifiable([
          ...events.where((existing) => existing.id != added.id),
          added,
        ]);
        touched.add(key);
      }
    }

    if (touched.isNotEmpty) notifyListeners();

    // The old span matters too: moving an event out of a month has to refresh
    // the month it left, not only the one it landed in.
    final toRefresh = <String, DateTime>{
      for (final event in [?removed, ?added])
        for (final month in monthsSpannedBy(event)) _keyFor(month): month,
    };
    for (final entry in toRefresh.entries) {
      _writeGeneration[entry.key] = (_writeGeneration[entry.key] ?? 0) + 1;
      // Clearing the freshness stamp is what lets the refetch through; without
      // it [_fetch] would sit on the patched copy for the next ten minutes.
      _fetchedAtByMonth.remove(entry.key);
      unawaited(_fetch(entry.value));
    }
  }

  /// Every month an event touches, so a span across a month boundary refreshes
  /// both sides rather than only where it starts.
  static List<DateTime> monthsSpannedBy(CalendarEvent event) {
    final months = <DateTime>[];
    var cursor = DateTime.utc(event.startDay.year, event.startDay.month, 1);
    final last = DateTime.utc(event.endDay.year, event.endDay.month, 1);
    while (!cursor.isAfter(last)) {
      months.add(cursor);
      cursor = DateTime.utc(cursor.year, cursor.month + 1, 1);
    }
    return months;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // The namespace includes calendar and zone so redeploying another church's
  // settings cannot reuse dates from the previous deployment.
  static String _keyFor(DateTime month) =>
      '$_cacheKeyPrefix${month.year}_${month.month.toString().padLeft(2, '0')}';

  Future<void> _loadCached(DateTime month) async {
    final key = _keyFor(month);
    // 记忆体里已经有这个月了就不要再读 disk：重读会 jsonDecode 整个月、
    // 通知画面、并让 layout 快取失效，等于每次换页都把三个月的版面重算一次。
    if (_eventsByMonth.containsKey(key)) return;

    try {
      final prefs = await _prefs();
      final cached = prefs.getString(key);
      if (cached == null || cached.isEmpty) return;

      final data = jsonDecode(cached) as List<dynamic>;
      final events = data
          .map((raw) => CalendarEvent.fromJson(raw as Map<String, dynamic>))
          .toList();
      // Checked again after the await: Google may have answered meanwhile,
      // and the disk copy is never newer than that.
      if (_disposed || _eventsByMonth.containsKey(key)) return;
      _eventsByMonth[key] = List.unmodifiable(events);
      _notify();
    } catch (_) {
      // Ignore corrupted or unreadable cache; Google will fill the month.
    }
  }

  /// Never throws. The month is already on screen by the time this runs, so a
  /// storage failure (localStorage full, private mode) only costs the next
  /// cold start its instant paint — it is not a failed load.
  Future<void> _saveCached(String key, List<CalendarEvent> events) async {
    try {
      final prefs = await _prefs();
      final payload = jsonEncode(events.map((e) => e.toJson()).toList());
      await prefs.setString(key, payload);
      await _pruneCachedMonths(prefs);
    } catch (error) {
      debugPrint('Could not cache $key: $error');
    }
  }

  Future<bool> _hasCachedCopy(String key) async {
    try {
      return (await _prefs()).getString(key) != null;
    } catch (_) {
      return false;
    }
  }

  /// 每浏览一个新月份就多一笔 key，永远不清的话 localStorage 会一直长大。
  /// 只留距今 [_cacheKeepMonths] 个月内的月份，其余删掉。
  Future<void> _pruneCachedMonths(SharedPreferences prefs) async {
    final now = _now();
    final nowIndex = now.year * 12 + now.month;

    for (final key in prefs.getKeys().toList()) {
      if (!key.startsWith(_cacheKeyPrefix)) continue;
      final parts = key.substring(_cacheKeyPrefix.length).split('_');
      if (parts.length != 2) continue;
      final year = int.tryParse(parts[0]);
      final month = int.tryParse(parts[1]);
      if (year == null || month == null) continue;

      final distance = (year * 12 + month) - nowIndex;
      if (distance.abs() > _cacheKeepMonths) {
        await prefs.remove(key);
      }
    }
  }

  Future<void> _fetch(DateTime month) async {
    final key = _keyFor(month);
    // Already on its way. If a write lands before it does, the generation
    // check below throws that answer away and asks again.
    if (_loadingMonths.contains(key)) return;

    final fetchedAt = _fetchedAtByMonth[key];
    if (fetchedAt != null && _now().difference(fetchedAt) < monthFreshness) {
      return; // 这个月刚抓过，直接用记忆体里的资料
    }

    final generation = _writeGeneration[key] ?? 0;
    bool superseded() => (_writeGeneration[key] ?? 0) != generation;

    _loadingMonths.add(key);
    _errorsByMonth.remove(key);
    _notify();

    try {
      final events = await _fetchMonth(month);
      if (_disposed || superseded()) return;
      _eventsByMonth[key] = List.unmodifiable(events);
      _fetchedAtByMonth[key] = _now();
      _notify();
      await _saveCached(key, events);
    } on CalendarReadException catch (error) {
      if (_disposed || superseded()) return;
      _errorsByMonth[key] = error.message;
    } catch (_) {
      if (_disposed || superseded()) return;
      // Offline with a copy on disk is not worth an error: the month is
      // already showing that copy.
      _errorsByMonth[key] = await _hasCachedCopy(key)
          ? null
          : '离线或连线逾时，且没有快取资料';
    } finally {
      _loadingMonths.remove(key);
      if (!_disposed) {
        _notify();
        if (superseded()) unawaited(_fetch(month));
      }
    }
  }
}
