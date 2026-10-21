import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:church_staff_pwa/core/widgets/text_warmup.dart';

void main() {
  group('TextWarmup.uniqueStringsOf', () {
    test('去重且保留出现顺序', () {
      final result = TextWarmup.uniqueStringsOf(['王小明', '李大华', '王小明']);
      expect(result, ['王小明', '李大华']);
    });

    test('去除前后空白后再比对', () {
      final result = TextWarmup.uniqueStringsOf(['王小明', ' 王小明 ']);
      expect(result, ['王小明']);
    });

    test('略过空字串与纯空白', () {
      expect(TextWarmup.uniqueStringsOf(['', '   ', '\n']), isEmpty);
    });

    test('空输入回传空清单', () {
      expect(TextWarmup.uniqueStringsOf(const []), isEmpty);
    });
  });

  group('TextWarmup widget', () {
    Widget host(List<String> strings) => MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            const SizedBox.expand(),
            TextWarmup(strings: strings),
          ],
        ),
      ),
    );

    testWidgets('分批排版，不会一次把全部塞进同一帧', (tester) async {
      // 60 个字串、每帧 24 个 → 至少要跨三帧才做得完
      final strings = [for (var i = 0; i < 60; i++) '名字$i'];
      await tester.pumpWidget(host(strings));

      // 第一帧还没开始（要等 post-frame callback）
      expect(find.byType(Text), findsNothing);

      await tester.pump();
      expect(find.text('名字0'), findsOneWidget);
      expect(find.text('名字30'), findsNothing); // 还没轮到

      await tester.pump();
      expect(find.text('名字30'), findsOneWidget);
      expect(find.text('名字0'), findsNothing); // 已排版过的就不留在树上
    });

    testWidgets('全部做完之后把自己撤掉', (tester) async {
      await tester.pumpWidget(host(['王小明', '李大华']));
      await tester.pump();
      expect(find.text('王小明'), findsOneWidget);

      // 排完 + settle 时间
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('换一份字串就重新预热', (tester) async {
      await tester.pumpWidget(host(['王小明']));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      expect(find.byType(Text), findsNothing);

      await tester.pumpWidget(host(['李大华']));
      await tester.pump();
      expect(find.text('李大华'), findsOneWidget);
    });

    testWidgets('空清单不放任何东西进树里', (tester) async {
      await tester.pumpWidget(host(const []));
      await tester.pump();
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('预热的字串对辅助科技隐形', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(host(const ['王小明', '李大华']));
      await tester.pump();

      // 确实排版了 —— 否则下面的 findsNothing 只是因为树上根本没东西。
      expect(find.text('王小明'), findsOneWidget);
      // 但 VoiceOver／TalkBack 读不到：这些字只是拿来逼引擎排版，
      // 进了 semantics tree 就会变成整份名单被一个个念出来。
      expect(find.bySemanticsLabel('王小明'), findsNothing);
      expect(find.bySemanticsLabel('李大华'), findsNothing);

      handle.dispose();
    });

    testWidgets('清单被就地改短也不会抛 RangeError', (tester) async {
      final strings = [for (var i = 0; i < 60; i++) '名字$i'];
      await tester.pumpWidget(host(strings));
      await tester.pump();
      await tester.pump(); // 已经排到第 48 个

      // 就地砍短：identity 没变，didUpdateWidget 不会重置，已排版位置就落在
      // 界外。没有夹住的话 sublist 会直接炸掉。
      strings.removeRange(10, strings.length);
      await tester.pumpWidget(host(strings));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('内容一样的新 List 不会重新预热', (tester) async {
      await tester.pumpWidget(host(const ['王小明', '李大华']));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      expect(find.byType(Text), findsNothing);

      // 呼叫端若在 build 里现算清单，每次 rebuild 的 instance 都不同但内容
      // 一样。这时若重新预热，就再也撤不掉，每一帧都白排一次版。
      await tester.pumpWidget(host(['王小明', '李大华']));
      await tester.pump();
      expect(find.byType(Text), findsNothing);
    });
  });
}
