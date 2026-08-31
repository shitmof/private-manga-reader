import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:screen_brightness/screen_brightness.dart';

import '../models/entities.dart';
import '../services/page_offset_index.dart';
import '../services/privacy_service.dart';
import '../state/app_controller.dart';
import '../theme.dart';
import '../widgets/reader_edge_scrubber.dart';
import '../widgets/reader_page_pill.dart';
import '../widgets/reader_top_bar.dart';

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
    final night =
        widget.controller.preferences.surfaceMode == ReaderSurfaceMode.night;
    final canvasColor = night ? const Color(0xFF0B0D10) : ShelfColors.paper;
    final width = MediaQuery.sizeOf(context).width;
    _ensureOffsetIndex(width, gap);
    return Scaffold(
      key: const ValueKey<String>('reader-canvas'),
      backgroundColor: canvasColor,
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => setState(() => _controlsVisible = !_controlsVisible),
        child: Stack(
          children: <Widget>[
            if (_loading)
              Center(
                child: CircularProgressIndicator(
                  color: night ? Colors.white : ShelfColors.blue,
                ),
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
                        child: ColoredBox(
                          color: night ? const Color(0xFF0B0D10) : Colors.white,
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
                                Center(
                                  child: Icon(
                                    Icons.broken_image_outlined,
                                    size: 42,
                                    color: night
                                        ? Colors.white54
                                        : ShelfColors.muted,
                                  ),
                                ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ReaderTopBar(
              visible: _controlsVisible,
              title: title,
              night: night,
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
              ReaderEdgeScrubber(
                night: night,
                currentFraction: _scrubbing
                    ? _scrubFraction
                    : _offsetIndex.fractionForPage(_currentIndex),
                currentPage: _scrubbing
                    ? _offsetIndex.pageAtFraction(_scrubFraction) + 1
                    : _currentIndex + 1,
                totalPages: _items.length,
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
            ReaderPagePill(
              night: night,
              visible:
                  _controlsVisible &&
                  widget.controller.preferences.showPageNumber,
              current: _items.isEmpty ? 0 : _currentIndex + 1,
              total: _items.length,
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
    var surfaceMode = widget.controller.preferences.surfaceMode;
    final bookmarks = await widget.controller.loadBookmarks(widget.comicId);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: surfaceMode == ReaderSurfaceMode.night
          ? const Color(0xFF20242A)
          : Colors.white,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          final night = surfaceMode == ReaderSurfaceMode.night;
          final foreground = night ? Colors.white : ShelfColors.ink;
          final secondary = night ? Colors.white54 : ShelfColors.muted;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    '阅读设置',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 14),
                  SegmentedButton<ReaderSurfaceMode>(
                    showSelectedIcon: false,
                    segments: const <ButtonSegment<ReaderSurfaceMode>>[
                      ButtonSegment(
                        value: ReaderSurfaceMode.paper,
                        icon: Icon(Icons.light_mode_outlined),
                        label: Text('画纸'),
                      ),
                      ButtonSegment(
                        value: ReaderSurfaceMode.night,
                        icon: Icon(Icons.dark_mode_outlined),
                        label: Text('夜间'),
                      ),
                    ],
                    selected: <ReaderSurfaceMode>{surfaceMode},
                    onSelectionChanged: (selection) {
                      surfaceMode = selection.first;
                      setSheetState(() {});
                      widget.controller.updatePreferences(
                        widget.controller.preferences.copyWith(
                          surfaceMode: surfaceMode,
                        ),
                      );
                      if (mounted) setState(() {});
                    },
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: <Widget>[
                      Icon(Icons.brightness_low, color: secondary),
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
                      Icon(Icons.brightness_high, color: secondary),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.bookmarks_outlined, color: foreground),
                    title: Text(
                      '页面书签（${bookmarks.length}）',
                      style: TextStyle(color: foreground),
                    ),
                    subtitle: Text(
                      '点击书签可快速返回对应页',
                      style: TextStyle(color: secondary),
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
          );
        },
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
    final night =
        widget.controller.preferences.surfaceMode == ReaderSurfaceMode.night;
    final background = night ? Colors.black : ShelfColors.paper;
    await Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: true,
        pageBuilder: (context, animation, secondaryAnimation) => Scaffold(
          backgroundColor: background,
          appBar: AppBar(
            backgroundColor: night ? Colors.black : Colors.white,
            foregroundColor: night ? Colors.white : ShelfColors.blue,
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
