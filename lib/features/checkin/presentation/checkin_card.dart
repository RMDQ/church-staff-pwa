import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' show FirebaseAuth;
import 'package:flutter/material.dart';

import '../../../core/config/church_config.dart';
import '../../../core/time/church_time.dart';
import '../../auth/data/email_verification.dart';
import '../data/checkin_location.dart';
import '../data/checkin_service.dart';
import '../domain/checkin_models.dart';
import '../domain/checkin_reminders.dart';

enum _Phase { idle, busy, done, failed }

/// 首页的打卡卡片。按钮只负责取得位置、交给服务器；能不能打卡由服务器说了算。
class CheckinCard extends StatefulWidget {
  const CheckinCard({super.key, this.service, this.locate, this.verification});

  /// 测试与预览用的替身。正式页面不传，用真实的服务和定位。
  final CheckinService? service;
  final Future<CheckinPosition> Function()? locate;
  final EmailVerification? verification;

  @override
  State<CheckinCard> createState() => _CheckinCardState();
}

class _CheckinCardState extends State<CheckinCard> {
  late final CheckinService _service = widget.service ?? CheckinService();
  late final Future<CheckinPosition> Function() _locate =
      widget.locate ?? currentCheckinPosition;
  late final EmailVerification _verification =
      widget.verification ?? EmailVerification();
  late bool _verified = _verification.isVerified;
  bool _checkingVerification = false;
  String? _verificationNote;

  /// 今天是否已经打过卡（从 checkins 读取，本人可以读自己的记录）。
  bool _checkedInToday = false;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _loadToday();
    // 每分钟重新计算一次提醒，让「开放打卡」「现在可以打卡」跟上时间。
    _ticker = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _loadToday() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;
      final key = ChurchTime.dateKey(ChurchTime.today());
      final doc = await FirebaseFirestore.instance
          .collection('checkins')
          .doc('${key}_$uid')
          .get();
      if (mounted) setState(() => _checkedInToday = doc.exists);
    } catch (_) {
      // 读不到就不显示「已打卡」；按钮的可用与否仍由服务器判断。
    }
  }

  Future<void> _resendVerification() async {
    try {
      await _verification.resend();
      if (!mounted) return;
      setState(() => _verificationNote = '验证邮件已重新寄出，请到邮箱点击链接');
    } catch (_) {
      if (!mounted) return;
      setState(() => _verificationNote = '暂时无法寄出验证邮件，请稍后再试');
    }
  }

  Future<void> _refreshVerification() async {
    setState(() => _checkingVerification = true);
    final verified = await _verification.refresh();
    if (!mounted) return;
    setState(() {
      _verified = verified;
      _checkingVerification = false;
      _verificationNote = verified ? null : '还没有验证，请先点击邮件里的链接';
    });
  }

  _Phase _phase = _Phase.idle;
  String _busyText = '';
  CheckinResult? _result;
  String? _error;

  Future<void> _checkIn() async {
    setState(() {
      _phase = _Phase.busy;
      _busyText = '正在取得位置…';
      _error = null;
    });
    try {
      final position = await _locate();
      if (!mounted) return;
      setState(() => _busyText = '正在打卡…');
      final result = await _service.checkIn(position);
      if (!mounted) return;
      setState(() {
        _result = result;
        _phase = _Phase.done;
        _checkedInToday = true;
      });
    } on CheckinException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _phase = _Phase.failed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final busy = _phase == _Phase.busy;
    final done = _phase == _Phase.done;
    final result = _result;

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
                Icon(Icons.how_to_reg_outlined, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                const Text(
                  '主日崇拜打卡',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(_windowText()),
            ..._reminderLines(done),
            if (!_verified) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '邮箱还没有验证。验证后才能打卡。',
                      style: TextStyle(color: scheme.onErrorContainer),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        TextButton(
                          onPressed: _resendVerification,
                          child: const Text('重新发送'),
                        ),
                        TextButton(
                          onPressed: _checkingVerification ? null : _refreshVerification,
                          child: const Text('我已验证'),
                        ),
                      ],
                    ),
                    if (_verificationNote != null)
                      Text(
                        _verificationNote!,
                        style: TextStyle(color: scheme.onErrorContainer),
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            Center(
              child: FilledButton.icon(
                onPressed: (busy || done) ? null : _checkIn,
                icon: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.place_outlined),
                label: Text(
                  done ? '已打卡' : (busy ? _busyText : '打卡'),
                ),
              ),
            ),
            if (result != null) ...[
              const SizedBox(height: 12),
              Text(
                '${result.onTime ? '准时' : '迟到'} · ${result.time} · 距离教堂约 ${result.distanceMeters} 米',
                style: TextStyle(
                  color: result.onTime ? const Color(0xFF2E7D32) : const Color(0xFFB26A00),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: scheme.error)),
            ],
          ],
        ),
      ),
    );
  }
}

/// 打卡说明，照教会设定显示，不写死在界面里。
String _windowText() {
  final checkin = ChurchConfig.current.checkin;
  return '每周${checkin.start}–${checkin.end}，需在教堂附近 ${checkin.allowedMeters} 米内';
}

extension on _CheckinCardState {
  /// 事件提醒：打卡开放前、开放中还没打卡、邮箱未验证。
  List<Widget> _reminderLines(bool done) {
    final config = ChurchConfig.current.checkin;
    final service = ChurchConfig.current.services.firstWhere(
      (entry) => entry.id == config.serviceId,
    );
    final reminders = checkinReminders(
      now: ChurchTime.now(),
      start: config.start,
      end: config.end,
      allowedMeters: config.allowedMeters,
      serviceWeekday: service.weekday,
      checkedInToday: _checkedInToday || done,
      emailVerified: _verified,
    );
    if (reminders.isEmpty) return const [];
    return [
      const SizedBox(height: 12),
      for (final reminder in reminders)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.only(top: 6, right: 8),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: reminder.urgent
                      ? Theme.of(context).colorScheme.error
                      : Theme.of(context).colorScheme.primary,
                ),
              ),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: reminder.title,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      TextSpan(
                        text: '  ${reminder.detail}',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
    ];
  }
}
