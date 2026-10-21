import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:church_staff_pwa/features/roster/domain/entities/event_option.dart';
import 'package:church_staff_pwa/features/roster/presentation/widgets/event_color_picker.dart';

void main() {
  Future<List<int>> pump(WidgetTester tester, {double width = 320}) async {
    final picked = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: width,
            child: StatefulBuilder(
              builder: (context, setState) => EventColorPicker(
                selected: picked.isEmpty
                    ? eventColorPalette.first
                    : picked.last,
                onSelected: (color) => setState(() => picked.add(color)),
              ),
            ),
          ),
        ),
      ),
    );
    return picked;
  }

  testWidgets('排成两排各五个，窄萤幕也一样', (tester) async {
    await pump(tester, width: 280);
    final rows = tester.widgetList<Row>(find.byType(Row)).toList();
    expect(rows, hasLength(2));
    for (final row in rows) {
      expect(row.children, hasLength(EventColorPicker.columns));
    }
    // 上下两排对齐：同一栏的左边界一样。
    final swatches = find.byType(InkWell);
    expect(swatches, findsNWidgets(eventColorPalette.length));
    for (var i = 0; i < EventColorPicker.columns; i++) {
      expect(
        tester.getTopLeft(swatches.at(i)).dx,
        tester.getTopLeft(swatches.at(i + EventColorPicker.columns)).dx,
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('点了就回传那个颜色', (tester) async {
    final picked = await pump(tester);
    await tester.tap(find.byType(InkWell).at(7));
    await tester.pump();
    expect(picked, [eventColorPalette[7]]);
  });
}
