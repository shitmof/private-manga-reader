import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_manga_reader/widgets/reader_edge_scrubber.dart';

void main() {
  testWidgets('纵向滑轮平时不可见，触碰右侧热区才显现并在松手后消失', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var fraction = 0.25;
    double? endedAt;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: StatefulBuilder(
            builder: (context, setState) => Stack(
              children: <Widget>[
                const Positioned.fill(child: ColoredBox(color: Colors.black)),
                ReaderEdgeScrubber(
                  currentFraction: fraction,
                  currentPage: (fraction * 600).round().clamp(1, 600),
                  totalPages: 600,
                  onChangeStart: (_) {},
                  onChanged: (value) => setState(() => fraction = value),
                  onChangeEnd: (value) => endedAt = value,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    AnimatedOpacity visibility() => tester.widget<AnimatedOpacity>(
      find.byKey(const ValueKey<String>('reader-fast-scrubber-visibility')),
    );

    expect(visibility().opacity, 0);
    await tester.tapAt(const Offset(354, 400));
    await tester.pump();
    expect(visibility().opacity, 1);

    await tester.pump(const Duration(milliseconds: 1300));
    expect(visibility().opacity, 0);

    final gesture = await tester.startGesture(const Offset(354, 100));
    await gesture.moveTo(const Offset(354, 735));
    await tester.pump();
    expect(visibility().opacity, 1);
    expect(fraction, greaterThan(0.98));
    await gesture.up();
    await tester.pump();
    expect(endedAt, closeTo(fraction, 0.001));
    await tester.pump(const Duration(milliseconds: 1300));
    expect(visibility().opacity, 0);
  });

  testWidgets('enabled 为 false 时右侧热区完全不响应触摸，不再误触跳页', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var started = 0;
    var changed = 0;
    var ended = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: <Widget>[
              const Positioned.fill(child: ColoredBox(color: Colors.black)),
              ReaderEdgeScrubber(
                enabled: false,
                currentFraction: 0.25,
                currentPage: 150,
                totalPages: 600,
                onChangeStart: (_) => started += 1,
                onChanged: (_) => changed += 1,
                onChangeEnd: (_) => ended += 1,
              ),
            ],
          ),
        ),
      ),
    );

    AnimatedOpacity visibility() => tester.widget<AnimatedOpacity>(
      find.byKey(const ValueKey<String>('reader-fast-scrubber-visibility')),
    );

    // 轻点热区：不应触发任何跳页回调，也不应显示。
    await tester.tapAt(const Offset(354, 400));
    await tester.pump();
    expect(started, 0);
    expect(changed, 0);
    expect(ended, 0);
    expect(visibility().opacity, 0);

    // 纵向拖动同样被忽略。
    final gesture = await tester.startGesture(const Offset(354, 100));
    await gesture.moveTo(const Offset(354, 735));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(started, 0);
    expect(changed, 0);
    expect(ended, 0);
    expect(visibility().opacity, 0);
  });
}
