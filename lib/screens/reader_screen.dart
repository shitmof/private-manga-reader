import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:screen_brightness/screen_brightness.dart';

import '../models/entities.dart';
import '../services/page_offset_index.dart';
import '../services/privacy_service.dart';
import '../state/app_controller.dart';

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({
    required this.controller,
    required this.comicId,
    super.key,
  });

  final AppController controller;
  final String comicId;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen>
    with WidgetsBindingObserver {
  final ScrollController _scrollController = ScrollController();
  List<ComicItemRecord> _items = const <ComicItemRecord>[];
  bool _loading = true;
  bool _controlsVisible = false;
  int _currentIndex = 0;
  double _lastLayoutWidth = 0;
  PageOffsetIndex _offsetIndex = PageOffsetIndex.fromExtents(
    const <double>[],
    gap: 0,
  );
  bool _scrubbing = false;
  double _scrubFraction = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_handleScroll);
    _load();
  }

  Future<void> _load() async {
    final items = await widget.controller.loadItems(widget.comicId);
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
    if (widget.controller.summaryFor(widget.comicId)?.comic.isPrivate ??
        false) {
      await PrivateScreenGuard.setSecure(true);
    }
    await _applyBrightness(widget.controller.preferences.readerBrightness);
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreProgress());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      unawaited(_saveProgress());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.removeListener(_handleScroll);
    unawaited(_saveProgress());
    unawaited(ScreenBrightness().resetApplicationScreenBrightness());
    unawaited(PrivateScreenGuard.setSecure(false));
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final summary = widget.controller.summaryFor(widget.comicId);
    final title = summary?.comic.title ?? '阅读';
    final gap = widget.controller.preferences.imageGap;
    final width = MediaQuery.sizeOf(context).width;
    _ensureOffsetIndex(width, gap);
    return Scaffold(
      backgroundColor: const Color(0xFF0B0D10),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => setState(() => _controlsVisible = !_controlsVisible),
        child: Stack(
          children: <Widget>[
            if (_loading)
              const Center(
                child: CircularProgressIndicator(color: Colors.white),
              )
            else
              ListView.builder(
                controller: _scrollController,
                padding: EdgeInsets.zero,
                scrollCacheExtent: const ScrollCacheExtent.pixels(1200),
                itemCount: _items.length,
                itemBuilder: (context, index) {
                  final item = _items[index];
                  final height = _displayHeight(item, width);
                  return Padding(
                    padding: EdgeInsets.only(
                      bottom: index == _items.length - 1 ? 0 : gap,
                    ),
                    child: GestureDetector(
                      onDoubleTap: () => _showZoom(item),
                      child: SizedBox(
                        width: width,
                        height: height,
                        child: Image.file(
                          File(
                            widget.controller.filePath(item.asset.storedPath),
                          ),
                          fit: BoxFit.contain,
                          alignment: Alignment.topCenter,
                          cacheWidth:
                              (width * MediaQuery.devicePixelRatioOf(context))
                                  .round()
                                  .clamp(360, 2400),
                          filterQuality: FilterQuality.medium,
                          errorBuilder: (context, error, stackTrace) =>
                              const Center(
                                child: Icon(
                                  Icons.broken_image_outlined,
                                  size: 42,
                                  color: Colors.white54,
                                ),
                              ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            _ReaderTopBar(
              visible: _controlsVisible,
              title: title,
              onBack: () async {
                await _saveProgress();
                if (context.mounted) Navigator.pop(context);
              },
              onRestart: () => _scrollController.animateTo(
                0,
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeOutCubic,
              ),
              onBookmark: _saveBookmark,
              onSettings: _showReaderSettings,
            ),
            if (!_loading && _items.length > 1)
              _PageScrubber(
                currentFraction: _scrubbing
                    ? _scrubFraction
                    : _offsetIndex.fractionForPage(_currentIndex),
                currentPage: _scrubbing
                    ? _offsetIndex.pageAtFraction(_scrubFraction) + 1
                    : _currentIndex + 1,
                totalPages: _items.length,
                active: _scrubbing,
                onChangeStart: (fraction) => setState(() {
                  _scrubbing = true;
                  _scrubFraction = fraction;
                }),
                onChanged: (fraction) {
                  _scrubFraction = fraction;
                  _jumpToPage(_offsetIndex.pageAtFraction(fraction));
                },
                onChangeEnd: (fraction) {
                  _jumpToPage(_offsetIndex.pageAtFraction(fraction));
                  setState(() => _scrubbing = false);
                },
              ),
            _ReaderBottomBar(
              visible:
                  _controlsVisible &&
                  widget.controller.preferences.showPageNumber,
              current: _items.isEmpty ? 0 : _currentIndex + 1,
              total: _items.length,
              onPageChanged: (page) => _jumpToPage(page - 1),
            ),
          ],
        ),
      ),
    );
  }

  double _displayHeight(ComicItemRecord item, double width) {
    if (item.asset.width <= 0 || item.asset.height <= 0) return width;
    return width * item.asset.height / item.asset.width;
  }

  void _ensureOffsetIndex(double width, double gap) {
    if (_lastLayoutWidth == width && _offsetIndex.pageCount == _items.length) {
      return;
    }
    _lastLayoutWidth = width;
    _offsetIndex = PageOffsetIndex.fromExtents(
      _items.map((item) => _displayHeight(item, width)).toList(),
      gap: gap,
    );
  }

  void _restoreProgress() {
    if (!_scrollController.hasClients || _items.isEmpty) return;
    final comic = widget.controller.summaryFor(widget.comicId)?.comic;
    if (comic == null || !widget.controller.preferences.rememberProgress) {
      return;
    }
    final targetIndex = comic.lastReadPosition.clamp(0, _items.length - 1);
    final offset =
        _offsetIndex.offsetForPage(targetIndex) + comic.lastReadOffset;
    _scrollController.jumpTo(
      offset.clamp(0, _scrollController.position.maxScrollExtent),
    );
    _handleScroll();
  }

  void _handleScroll() {
    if (_items.isEmpty || _lastLayoutWidth <= 0) return;
    final index = _offsetIndex.pageAtOffset(_scrollController.offset + 1);
    if (index != _currentIndex && mounted) {
      setState(() => _currentIndex = index);
    }
  }

  Future<void> _saveProgress() async {
    if (_items.isEmpty || _lastLayoutWidth <= 0) return;
    final top = _offsetIndex.offsetForPage(_currentIndex);
    final within = _scrollController.hasClients
        ? (_scrollController.offset - top).clamp(0.0, double.infinity)
        : 0.0;
    await widget.controller.saveProgress(widget.comicId, _currentIndex, within);
  }

  void _jumpToPage(int page) {
    if (!_scrollController.hasClients || _items.isEmpty) return;
    final targetPage = page.clamp(0, _items.length - 1);
    final target = _offsetIndex
        .offsetForPage(targetPage)
        .clamp(0.0, _scrollController.position.maxScrollExtent);
    _scrollController.jumpTo(target);
    if (_currentIndex != targetPage && mounted) {
      setState(() => _currentIndex = targetPage);
    }
  }

  Future<void> _saveBookmark() async {
    if (_items.isEmpty) return;
    await widget.controller.saveBookmark(
      comicId: widget.comicId,
      itemId: _items[_currentIndex].id,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已收藏第 ${_currentIndex + 1} 页')));
  }

  Future<void> _showReaderSettings() async {
    var brightness = widget.controller.preferences.readerBrightness;
    final bookmarks = await widget.controller.loadBookmarks(widget.comicId);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: const Color(0xFF20242A),
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  '阅读设置',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: <Widget>[
                    const Icon(Icons.brightness_low, color: Colors.white70),
                    Expanded(
                      child: Slider(
                        value: brightness,
                        min: 0.05,
                        max: 1,
                        onChanged: (value) {
                          brightness = value;
                          setSheetState(() {});
                          _applyBrightness(value);
                        },
                        onChangeEnd: (value) =>
                            widget.controller.updatePreferences(
                              widget.controller.preferences.copyWith(
                                readerBrightness: value,
                              ),
                            ),
                      ),
                    ),
                    const Icon(Icons.brightness_high, color: Colors.white70),
                  ],
                ),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.bookmarks_outlined,
                    color: Colors.white,
                  ),
                  title: Text(
                    '页面书签（${bookmarks.length}）',
                    style: const TextStyle(color: Colors.white),
                  ),
                  subtitle: const Text(
                    '点击书签可快速返回对应页',
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
                if (bookmarks.isNotEmpty)
                  SizedBox(
                    height: 56,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: bookmarks.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (context, index) {
                        final bookmark = bookmarks[index];
                        return ActionChip(
                          label: Text('第 ${bookmark.position + 1} 页'),
                          onPressed: () {
                            Navigator.pop(context);
                            _jumpToPage(bookmark.position);
                          },
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _applyBrightness(double value) async {
    try {
      await ScreenBrightness().setApplicationScreenBrightness(value);
    } catch (_) {
      // 桌面测试环境或不支持的设备保持系统亮度。
    }
  }

  Future<void> _showZoom(ComicItemRecord item) async {
    await Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: true,
        pageBuilder: (context, animation, secondaryAnimation) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: Text('${_currentIndex + 1} / ${_items.length}'),
          ),
          body: InteractiveViewer(
            minScale: 0.8,
            maxScale: 5,
            child: Center(
              child: Image.file(
                File(widget.controller.filePath(item.asset.storedPath)),
                fit: BoxFit.contain,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReaderTopBar extends StatelessWidget {
  const _ReaderTopBar({
    required this.visible,
    required this.title,
    required this.onBack,
    required this.onRestart,
    required this.onBookmark,
    required this.onSettings,
  });

  final bool visible;
  final String title;
  final VoidCallback onBack;
  final VoidCallback onRestart;
  final VoidCallback onBookmark;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return AnimatedSlide(
      offset: visible ? Offset.zero : const Offset(0, -1),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 160),
        child: IgnorePointer(
          ignoring: !visible,
          child: Container(
            color: const Color(0xE6111418),
            child: SafeArea(
              bottom: false,
              child: SizedBox(
                height: 56,
                child: Row(
                  children: <Widget>[
                    IconButton(
                      onPressed: onBack,
                      color: Colors.white,
                      icon: const Icon(Icons.arrow_back_ios_new_rounded),
                    ),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '收藏当前页',
                      onPressed: onBookmark,
                      color: Colors.white,
                      icon: const Icon(Icons.bookmark_add_outlined),
                    ),
                    IconButton(
                      tooltip: '阅读设置',
                      onPressed: onSettings,
                      color: Colors.white,
                      icon: const Icon(Icons.settings_outlined),
                    ),
                    PopupMenuButton<String>(
                      color: const Color(0xFF20242A),
                      iconColor: Colors.white,
                      onSelected: (_) => onRestart(),
                      itemBuilder: (context) => const <PopupMenuEntry<String>>[
                        PopupMenuItem(
                          value: 'restart',
                          child: Text(
                            '从头开始',
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReaderBottomBar extends StatelessWidget {
  const _ReaderBottomBar({
    required this.visible,
    required this.current,
    required this.total,
    required this.onPageChanged,
  });

  final bool visible;
  final int current;
  final int total;
  final ValueChanged<int> onPageChanged;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: AnimatedSlide(
        offset: visible ? Offset.zero : const Offset(0, 1),
        duration: const Duration(milliseconds: 180),
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 160),
          child: IgnorePointer(
            ignoring: !visible,
            child: Container(
              color: const Color(0xE6111418),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 13,
                  ),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Slider(
                          value: total <= 1 ? 1 : current.toDouble(),
                          min: 1,
                          max: total <= 1 ? 1 : total.toDouble(),
                          divisions: total <= 1 ? null : total - 1,
                          onChanged: total <= 1
                              ? null
                              : (value) => onPageChanged(value.round()),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Text(
                        '$current / $total',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PageScrubber extends StatelessWidget {
  const _PageScrubber({
    required this.currentFraction,
    required this.currentPage,
    required this.totalPages,
    required this.active,
    required this.onChangeStart,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final double currentFraction;
  final int currentPage;
  final int totalPages;
  final bool active;
  final ValueChanged<double> onChangeStart;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 2,
      top: MediaQuery.paddingOf(context).top + 74,
      bottom: MediaQuery.paddingOf(context).bottom + 82,
      child: LayoutBuilder(
        builder: (context, constraints) {
          double fraction(Offset globalPosition) {
            final box = context.findRenderObject()! as RenderBox;
            return (box.globalToLocal(globalPosition).dy /
                    constraints.maxHeight)
                .clamp(0, 1);
          }

          return GestureDetector(
            key: const ValueKey<String>('reader-fast-scrubber'),
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: (details) =>
                onChangeStart(fraction(details.globalPosition)),
            onVerticalDragUpdate: (details) =>
                onChanged(fraction(details.globalPosition)),
            onVerticalDragEnd: (_) => onChangeEnd(currentFraction),
            onTapDown: (details) {
              final value = fraction(details.globalPosition);
              onChangeStart(value);
              onChanged(value);
              onChangeEnd(value);
            },
            child: SizedBox(
              width: 48,
              child: Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  Positioned(
                    right: 8,
                    top: 0,
                    bottom: 0,
                    child: Container(
                      width: 4,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                  Positioned(
                    right: 3,
                    top:
                        (constraints.maxHeight - 18) *
                        currentFraction.clamp(0, 1),
                    child: Container(
                      width: 14,
                      height: 18,
                      decoration: BoxDecoration(
                        color: const Color(0xFF78ADE5),
                        borderRadius: BorderRadius.circular(7),
                        boxShadow: const <BoxShadow>[
                          BoxShadow(color: Colors.black45, blurRadius: 4),
                        ],
                      ),
                    ),
                  ),
                  if (active)
                    Positioned(
                      right: 24,
                      top:
                          ((constraints.maxHeight - 42) *
                                  currentFraction.clamp(0, 1))
                              .clamp(0, constraints.maxHeight - 42),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xE6111418),
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Text(
                          '$currentPage / $totalPages',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
