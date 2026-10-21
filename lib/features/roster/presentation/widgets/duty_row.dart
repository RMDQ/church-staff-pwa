import 'package:flutter/material.dart';

/// 编辑模式一列服事的最小高度。
///
/// 48 是那颗删除 IconButton 的触控目标高度，给长辈按的，不能再缩。检视模式
/// 没有按钮，不吃这个下限（见 [DutyRow.dense]）—— 切换模式时的位移是靠锚定
/// 日期修的（见 `ScrollAnchor`），不是靠两边列高一样。
const double kDutyRowMinHeight = 48.0;

/// 服事项目的一列：左边项目名称、中间人名、右边（编辑模式才有的）操作按钮。
///
/// 检视卡片与编辑卡片共用这一份配置，差别只有 [dense]。
class DutyRow extends StatelessWidget {
  const DutyRow({
    super.key,
    required this.role,
    required this.people,
    this.roleColor,
    this.trailing = const [],
    this.dense = false,
  });

  final String role;

  /// 这一项的人。刻意收一份清单而不是排好的字串 —— 中文预设每个字都可以断
  /// 行，接成一串丢给 Text 的话，栏宽不够时会从名字中间切开（「陈美／丽」）。
  final List<String> people;

  final Color? roleColor;

  /// 放在最右边的操作按钮。检视模式留空。
  final List<Widget> trailing;

  /// 检视模式的排法：列高跟著文字走，不撑到 [kDutyRowMinHeight]。这个画面是
  /// 拿来读的，一页看得到几天比每列多出 25px 的留白重要。文字靠上对齐，名字
  /// 换行时项目名称才不会跟著往下飘。
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final row = Row(
      crossAxisAlignment: dense
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 88,
          child: Text(
            role,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: roleColor ?? Colors.grey[600],
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        Expanded(
          // 一个名字一段（顿号跟在名字后面），断行机会就只剩名字之间。
          child: Wrap(
            children: [
              for (var i = 0; i < people.length; i++)
                Text(
                  i == people.length - 1 ? people[i] : '${people[i]}、',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
            ],
          ),
        ),
        ...trailing,
      ],
    );
    if (dense) return row;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: kDutyRowMinHeight),
      child: row,
    );
  }
}
