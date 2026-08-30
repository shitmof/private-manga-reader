import 'package:flutter_test/flutter_test.dart';
import 'package:private_manga_reader/services/page_offset_index.dart';

void main() {
  test('600 页漫画可用预计算偏移快速定位到任意页', () {
    final index = PageOffsetIndex.fromExtents(
      List<double>.generate(600, (page) => 800 + page % 7),
      gap: 4,
    );

    expect(index.pageCount, 600);
    expect(index.offsetForPage(0), 0);
    expect(index.pageAtOffset(index.offsetForPage(418) + 10), 418);
    expect(index.pageAtFraction(1), 599);
    expect(index.fractionForPage(300), closeTo(300 / 599, 0.0001));
  });

  test('空书与越界拖动值不会导致异常', () {
    final empty = PageOffsetIndex.fromExtents(const <double>[], gap: 0);
    expect(empty.pageAtFraction(0.5), 0);
    expect(empty.offsetForPage(20), 0);

    final one = PageOffsetIndex.fromExtents(const <double>[100], gap: 0);
    expect(one.pageAtFraction(-2), 0);
    expect(one.pageAtFraction(3), 0);
  });
}
