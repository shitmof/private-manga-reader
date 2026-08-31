import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_manga_reader/theme.dart';
import 'package:private_manga_reader/widgets/reader_edge_scrubber.dart';
import 'package:private_manga_reader/widgets/reader_page_pill.dart';
import 'package:private_manga_reader/widgets/reader_top_bar.dart';

void main() {
  testWidgets('阅读页码胶囊使用白底蓝字而不是黑色工具条', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildShelfTheme(Brightness.light),
        home: const Scaffold(
          body: Stack(
            children: <Widget>[
              ReaderPagePill(visible: true, current: 12, total: 628),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final container = tester.widget<Container>(
      find.byKey(const ValueKey<String>('reader-page-pill')),
    );
    final decoration = container.decoration! as BoxDecoration;
    final label = tester.widget<Text>(find.text('12 / 628'));

    expect(decoration.color, Colors.white);
    expect(decoration.border!.top.color, ShelfColors.line);
    expect(label.style!.color, ShelfColors.blue);
  });

  testWidgets('阅读快速定位器显现后使用拾画阁蓝色', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: <Widget>[
              ReaderEdgeScrubber(
                currentFraction: 0.5,
                currentPage: 50,
                totalPages: 100,
                onChangeStart: (_) {},
                onChanged: (_) {},
                onChangeEnd: (_) {},
              ),
            ],
          ),
        ),
      ),
    );

    final track = tester.widget<Container>(
      find.byKey(const ValueKey<String>('reader-fast-scrubber-track')),
    );
    final decoration = track.decoration! as BoxDecoration;

    expect(decoration.color, ShelfColors.blue.withValues(alpha: 0.18));
  });

  testWidgets('阅读顶部控制栏使用白色画纸表面并保留蓝色操作', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildShelfTheme(Brightness.light),
        home: Scaffold(
          body: Stack(
            children: <Widget>[
              ReaderTopBar(
                visible: true,
                title: '夏日的午后',
                onBack: () {},
                onRestart: () {},
                onBookmark: () {},
                onSettings: () {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final surface = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey<String>('reader-top-bar-surface')),
    );
    final decoration = surface.decoration as BoxDecoration;
    final back = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.arrow_back_ios_new_rounded),
    );

    expect(decoration.color, Colors.white.withValues(alpha: 0.96));
    expect(back.color, ShelfColors.blue);
    expect(find.text('夏日的午后'), findsOneWidget);
  });
}
