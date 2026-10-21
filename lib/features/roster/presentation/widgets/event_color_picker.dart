import 'package:flutter/material.dart';

import '../../domain/entities/event_option.dart';

/// 活动标签的选色：[eventColorPalette] 排成每排 [columns] 个的格子。
///
/// 用固定的格子而不是 Wrap：Wrap 一排放几个看萤幕宽度，十个颜色会排成
/// 7+3 或 8+2，一边长一边短。色盘照「上排亮色、下排同色系深色」排好了，
/// 格子才对得上。活动设定页与单次活动的视窗共用这一个，两边才长得一样。
class EventColorPicker extends StatelessWidget {
  const EventColorPicker({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  static const int columns = 5;

  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var start = 0; start < eventColorPalette.length; start += columns)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final color in eventColorPalette.skip(start).take(columns))
                _Swatch(
                  color: color,
                  isSelected: color == selected,
                  onTap: () => onSelected(color),
                ),
            ],
          ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.color,
    required this.isSelected,
    required this.onTap,
  });

  final int color;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Padding(
        padding: const EdgeInsets.all(11),
        child: Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Color(color),
            border: Border.all(
              color: isSelected ? Colors.black54 : Colors.white,
              width: isSelected ? 2 : 1,
            ),
          ),
        ),
      ),
    );
  }
}
