import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_manga_reader/widgets/reader_page_pill.dart';

void main() {
  testWidgets('阅读页码是紧凑胶囊且不包含横向滑杆', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: <Widget>[
              ReaderPagePill(visible: true, current: 156, total: 628),
            ],
          ),
        ),
      ),
    );

    expect(find.text('156 / 628'), findsOneWidget);
    expect(find.byType(Slider), findsNothing);
    final size = tester.getSize(
      find.byKey(const ValueKey<String>('reader-page-pill')),
    );
    expect(size.width, lessThan(140));
  });
}
