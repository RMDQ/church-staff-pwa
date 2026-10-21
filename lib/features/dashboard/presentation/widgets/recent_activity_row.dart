import 'package:flutter/material.dart';

import '../../domain/entities/recent_activity.dart';

/// 首页「近期活动」的一列：左边日期、右边标题。
///
/// 抽成独立 widget 是为了让版面能被测试盯住。日期栏是
/// `Expanded(flex: 2)` + 单行 + ellipsis —— 字串太长不会报错，只会
/// 被默默截掉，肉眼在开发机上又不见得看得出来。recent_activity_row_test.dart
/// 会用 TextPainter 量实际字宽并跟栏宽比对，超出就让测试红。
class RecentActivityRow extends StatelessWidget {
  const RecentActivityRow({super.key, required this.activity});

  final RecentActivity activity;

  /// 日期栏与标题栏的宽度比。固定比例（而不是让日期照自然宽度）是为了让
  /// 每一列的标题都从同一个 x 起始 —— 「全日」与「有时间」两种格式的自然
  /// 宽度不同，不固定就会参差不齐。
  static const int dateFlex = 2;
  static const int titleFlex = 3;
  static const double columnGap = 8;

  static const TextStyle dateStyle = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
  );
  static const TextStyle titleStyle = TextStyle(fontSize: 13);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: dateFlex,
            child: Text(
              formatRecentActivityDate(activity),
              key: const ValueKey('recent-activity-date'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: dateStyle,
            ),
          ),
          const SizedBox(width: columnGap),
          Expanded(
            flex: titleFlex,
            child: Text(
              activity.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: titleStyle,
            ),
          ),
        ],
      ),
    );
  }
}
