/// 预计算长漫画每一页的起始偏移，让滚动和拖动定位都是 O(log n)。
class PageOffsetIndex {
  PageOffsetIndex._(this._offsets, this.totalExtent);

  factory PageOffsetIndex.fromExtents(
    List<double> extents, {
    required double gap,
  }) {
    final offsets = <double>[];
    var cursor = 0.0;
    for (var page = 0; page < extents.length; page++) {
      offsets.add(cursor);
      cursor += extents[page].clamp(0, double.infinity);
      if (page != extents.length - 1) cursor += gap.clamp(0, double.infinity);
    }
    return PageOffsetIndex._(List<double>.unmodifiable(offsets), cursor);
  }

  final List<double> _offsets;
  final double totalExtent;

  int get pageCount => _offsets.length;

  double offsetForPage(int page) {
    if (_offsets.isEmpty) return 0;
    return _offsets[page.clamp(0, _offsets.length - 1)];
  }

  int pageAtOffset(double offset) {
    if (_offsets.isEmpty) return 0;
    final target = offset.clamp(0, totalExtent);
    var low = 0;
    var high = _offsets.length - 1;
    while (low <= high) {
      final middle = (low + high) >> 1;
      if (_offsets[middle] <= target) {
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return high.clamp(0, _offsets.length - 1);
  }

  int pageAtFraction(double fraction) {
    if (_offsets.length <= 1) return 0;
    return (fraction.clamp(0, 1) * (_offsets.length - 1)).round();
  }

  double fractionForPage(int page) {
    if (_offsets.length <= 1) return 0;
    return page.clamp(0, _offsets.length - 1) / (_offsets.length - 1);
  }
}
