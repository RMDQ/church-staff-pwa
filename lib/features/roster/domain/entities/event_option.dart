class EventOption {
  final String name;
  final int color;

  const EventOption({required this.name, required this.color});

  EventOption copyWith({String? name, int? color}) {
    return EventOption(name: name ?? this.name, color: color ?? this.color);
  }

  Map<String, dynamic> toJson() {
    return {'name': name, 'color': color};
  }

  static EventOption fromJson(Map<String, dynamic> json) {
    final rawName = json['name'];
    final rawColor = json['color'];
    return EventOption(
      name: rawName is String ? rawName : '',
      color: rawColor is int ? rawColor : 0xFFD97706,
    );
  }
}

/// 活动清单里找不到、服事表也没自己指定颜色的活动用这个色。
const int fallbackEventColor = 0xFF7F8C8D;

/// 活动可以选的颜色。活动设定页的色盘跟汇入时自动配色用同一份，
/// 不然自动配出来的颜色会是设定页点不回去的颜色。
///
/// Tailwind 的 600 色阶，照色相排成两排各五个（见 EventColorPicker）。标签
/// 是拿这个颜色当字色、再铺一层 12% 的同色底，所以要同一个深浅：Google
/// 日历那套的黄、粉当字色几乎看不见，最早用的 Flat UI 那套也偏淡。
/// 2026-09-24 换过一次，线上活动清单里的旧色码一起换成了最接近的新色。
///
/// 没有灰色：灰色是「没设颜色」的 [fallbackEventColor]，选了它的活动看起来
/// 就像没设。
const List<int> eventColorPalette = [
  0xFFDC2626, // red
  0xFFEA580C, // orange
  0xFFD97706, // amber
  0xFF16A34A, // green
  0xFF0D9488, // teal
  0xFF0284C7, // sky
  0xFF2563EB, // blue
  0xFF4F46E5, // indigo
  0xFF7C3AED, // violet
  0xFFDB2777, // pink
];

/// 帮新活动挑一个颜色：这个崇拜目前用得最少的那个，同样少就照色盘顺序。
///
/// 全部都用过时也不会跟前一个撞色 —— 挑最少的而不是固定第一个，是为了让
/// 同一季一次加进来的几个活动彼此分得开。
int pickEventColor(List<EventOption> existing) {
  final useCount = <int, int>{for (final color in eventColorPalette) color: 0};
  for (final option in existing) {
    if (useCount.containsKey(option.color)) {
      useCount[option.color] = useCount[option.color]! + 1;
    }
  }
  var best = eventColorPalette.first;
  for (final color in eventColorPalette) {
    if (useCount[color]! < useCount[best]!) best = color;
  }
  return best;
}
