import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:private_manga_reader/theme.dart';
import 'package:private_manga_reader/widgets/formatters.dart';

void main() {
  testWidgets('克制的空状态基础界面可渲染', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildShelfTheme(Brightness.light),
        home: const Scaffold(body: Center(child: Text('这里还没有漫画'))),
      ),
    );

    expect(find.text('这里还没有漫画'), findsOneWidget);
    expect(formatBytes(1024 * 1024), '1.0 MB');
  });

  test('应用图标是有效且非空的高清方图', () {
    final bytes = File('assets/branding/app_icon.png').readAsBytesSync();
    final icon = img.decodePng(bytes);
    expect(icon, isNotNull);
    expect(icon!.width, icon.height);
    expect(icon.width, greaterThanOrEqualTo(1024));
    var visibleSamples = 0;
    var coloredSamples = 0;
    for (var y = 0; y < icon.height; y += 32) {
      for (var x = 0; x < icon.width; x += 32) {
        final pixel = icon.getPixel(x, y);
        if (pixel.a > 0) visibleSamples++;
        if (pixel.r + pixel.g + pixel.b > 24) coloredSamples++;
      }
    }
    expect(visibleSamples, greaterThan(100));
    expect(coloredSamples, greaterThan(100));
  });
}
