import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_manga_reader/theme.dart';
import 'package:private_manga_reader/widgets/shelf_page_route.dart';

void main() {
  testWidgets('阅读页使用白色无黑闪的淡入缩放转场', (tester) async {
    late BuildContext hostContext;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildShelfTheme(Brightness.light),
        home: Builder(
          builder: (context) {
            hostContext = context;
            return const Scaffold(body: Text('书籍详情'));
          },
        ),
      ),
    );

    final route = buildShelfReaderRoute<void>(
      builder: (_) => const Scaffold(
        key: ValueKey<String>('reader-destination'),
        backgroundColor: ShelfColors.paper,
      ),
    );
    expect(route.transitionDuration, const Duration(milliseconds: 240));
    expect(route.reverseTransitionDuration, const Duration(milliseconds: 200));

    Navigator.of(hostContext).push(route);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(
      find.byKey(const ValueKey<String>('reader-route-transition-surface')),
      findsOneWidget,
    );
    final surface = tester.widget<ColoredBox>(
      find.byKey(const ValueKey<String>('reader-route-transition-surface')),
    );
    expect(surface.color, ShelfColors.paper);
    expect(find.byType(FadeTransition), findsWidgets);
    expect(find.byType(ScaleTransition), findsWidgets);

    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('reader-destination')),
      findsOneWidget,
    );
  });
}
