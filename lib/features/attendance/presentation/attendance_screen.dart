import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/attendance_service.dart';
import '../domain/attendance_models.dart';

/// 出勤名单。管理员看全部，小组长只看本小组（过滤在服务器上完成）。
class AttendanceScreen extends StatefulWidget {
  const AttendanceScreen({super.key, this.service});

  /// 测试与预览用的替身。正式页面不传。
  final AttendanceService? service;

  @override
  State<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends State<AttendanceScreen> {
  late final AttendanceService _service = widget.service ?? AttendanceService();
  final _dateFormat = DateFormat('yyyy-MM-dd');

  DateTime? _selected;
  late Future<AttendanceDay> _future = _service.load();

  void _reload() {
    final selected = _selected;
    setState(() {
      _future = _service.load(
        date: selected == null ? null : _dateFormat.format(selected),
      );
    });
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selected ?? now,
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year + 1),
    );
    if (picked == null) return;
    _selected = picked;
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('出勤'),
        actions: [
          IconButton(
            tooltip: '选择日期',
            icon: const Icon(Icons.calendar_month_outlined),
            onPressed: _pickDate,
          ),
        ],
      ),
      body: FutureBuilder<AttendanceDay>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  snapshot.error is AttendanceException
                      ? snapshot.error.toString()
                      : '读取出勤失败，请稍后再试',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          final day = snapshot.data!;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                day.date,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                '共 ${day.total} 人 · 准时 ${day.onTime} · 迟到 ${day.late}',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              if (day.rows.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Center(child: Text('这一天还没有可以查看的打卡记录')),
                ),
              for (final row in day.rows)
                Card(
                  child: ListTile(
                    title: Text(row.name),
                    subtitle: Text(
                      row.smallGroups.isEmpty
                          ? row.time
                          : '${row.smallGroups.join('、')} · ${row.time}',
                    ),
                    trailing: Text(
                      row.onTime ? '准时' : '迟到',
                      style: TextStyle(
                        color: row.onTime
                            ? const Color(0xFF2E7D32)
                            : const Color(0xFFB26A00),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
