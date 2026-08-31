import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../models/entities.dart';
import '../services/page_offset_index.dart';
import '../state/app_controller.dart';
import '../theme.dart';
import '../widgets/reader_edge_scrubber.dart';
import '../widgets/reader_page_pill.dart';
import '../widgets/reader_top_bar.dart';

class RemoteReaderScreen extends StatefulWidget {
  const RemoteReaderScreen({
    required this.controller,
    required this.bookId,
    super.key,
  });

  final AppController controller;
  final String bookId;

  @override
  State<RemoteReaderScreen> createState() => _RemoteReaderScreenState();
}

class _RemoteReaderScreenState extends State<RemoteReaderScreen>
    with WidgetsBindingObserver {
  final ScrollController _scrollController = ScrollController();
  List<RemotePage> _pages = const <RemotePage>[];
  bool _loading = true;
  bool _controlsVisible = false;
  bool _scrubbing = false;
  double _scrubFraction = 0;
  int _currentIndex = 0;
  double _lastLayoutWidth = 0;
  PageOffsetIndex _offsetIndex = PageOffsetIndex.fromExtents(
    const <double>[],
    gap: 0,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_handleScroll);
    _load();
  }

  Future<void> _load() async {
    final pages = await widget.controller.loadRemotePages(widget.bookId);
    if (!mounted) return;
    setState(() {
      _pages = pages;
      _loading = false;
    });
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
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final book = widget.controller.remoteBookFor(widget.bookId);
    final gap = widget.controller.preferences.imageGap;
    final night =
        widget.controller.preferences.surfaceMode == ReaderSurfaceMode.night;
    final canvasColor = night ? const Color(0xFF0B0D10) : ShelfColors.paper;
    final width = MediaQuery.sizeOf(context).width;
    _ensureOffsetIndex(width, gap);
    return Scaffold(
      key: const ValueKey<String>('remote-reader-canvas'),
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
                itemCount: _pages.length,
                itemBuilder: (context, index) {
                  final page = _pages[index];
                  return Padding(
                    padding: EdgeInsets.only(
                      bottom: index == _pages.length - 1 ? 0 : gap,
                    ),
                    child: GestureDetector(
                      onDoubleTap: () => _showZoom(page),
                      child: SizedBox(
                        width: width,
                        height: _displayHeight(page, width),
                        child: ColoredBox(
                          color: night ? const Color(0xFF0B0D10) : Colors.white,
                          child: _pageImage(page, width, night: night),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ReaderTopBar(
              visible: _controlsVisible,
              title: book?.title ?? '网络漫画',
              night: night,
              onBack: () => Navigator.of(context).pop(),
              onRestart: () => _scrollController.animateTo(
                0,
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeOutCubic,
              ),
            ),
            if (_pages.length > 1)
              ReaderEdgeScrubber(
                night: night,
                currentFraction: _scrubbing
                    ? _scrubFraction
                    : _offsetIndex.fractionForPage(_currentIndex),
                currentPage: _pages.isEmpty ? 0 : _currentIndex + 1,
                totalPages: _pages.length,
                onChangeStart: (fraction) => setState(() {
                  _scrubbing = true;
                  _scrubFraction = fraction;
                }),
                onChanged: (fraction) {
                  setState(() => _scrubFraction = fraction);
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
              current: _pages.isEmpty ? 0 : _currentIndex + 1,
              total: _pages.length,
            ),
          ],
        ),
      ),
    );
  }

  double _displayHeight(RemotePage page, double width) {
    if (page.width <= 0 || page.height <= 0) return width;
    return width * page.height / page.width;
  }

  void _ensureOffsetIndex(double width, double gap) {
    if (_lastLayoutWidth == width && _offsetIndex.pageCount == _pages.length) {
      return;
    }
    _lastLayoutWidth = width;
    _offsetIndex = PageOffsetIndex.fromExtents(
      _pages.map((page) => _displayHeight(page, width)).toList(),
      gap: gap,
    );
  }

  void _restoreProgress() {
    if (!_scrollController.hasClients || _pages.isEmpty) return;
    final book = widget.controller.remoteBookFor(widget.bookId);
    if (book == null || !widget.controller.preferences.rememberProgress) return;
    final targetIndex = book.lastReadPosition.clamp(0, _pages.length - 1);
    final offset =
        _offsetIndex.offsetForPage(targetIndex) + book.lastReadOffset;
    _scrollController.jumpTo(
      offset.clamp(0, _scrollController.position.maxScrollExtent),
    );
    _handleScroll();
  }

  void _handleScroll() {
    if (_pages.isEmpty || _lastLayoutWidth <= 0) return;
    final index = _offsetIndex.pageAtOffset(_scrollController.offset + 1);
    if (index != _currentIndex && mounted) {
      setState(() => _currentIndex = index);
    }
  }

  Future<void> _saveProgress() async {
    if (_pages.isEmpty || _lastLayoutWidth <= 0) return;
    final top = _offsetIndex.offsetForPage(_currentIndex);
    final within = _scrollController.hasClients
        ? (_scrollController.offset - top).clamp(0.0, double.infinity)
        : 0.0;
    await widget.controller.saveRemoteProgress(
      widget.bookId,
      _currentIndex,
      within,
    );
  }

  void _jumpToPage(int page) {
    if (!_scrollController.hasClients || _pages.isEmpty) return;
    final targetPage = page.clamp(0, _pages.length - 1);
    _scrollController.jumpTo(
      _offsetIndex
          .offsetForPage(targetPage)
          .clamp(0.0, _scrollController.position.maxScrollExtent),
    );
    if (_currentIndex != targetPage) setState(() => _currentIndex = targetPage);
  }

  Future<void> _showZoom(RemotePage page) async {
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
            title: Text('${_currentIndex + 1} / ${_pages.length}'),
          ),
          body: InteractiveViewer(
            minScale: 0.8,
            maxScale: 5,
            child: Center(
              child: _pageImage(
                page,
                MediaQuery.sizeOf(context).width,
                night: night,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _pageImage(RemotePage page, double width, {required bool night}) {
    final cacheWidth = (width * MediaQuery.devicePixelRatioOf(context))
        .round()
        .clamp(360, 2400);
    if (!page.isExternal) {
      return Image.file(
        File(widget.controller.filePath(page.relativePath)),
        fit: BoxFit.contain,
        alignment: Alignment.topCenter,
        cacheWidth: cacheWidth,
        filterQuality: FilterQuality.medium,
        errorBuilder: (context, error, stack) => _imageError(night),
      );
    }
    return _ExternalPageImage(
      controller: widget.controller,
      page: page,
      cacheWidth: cacheWidth,
      night: night,
    );
  }

  Widget _imageError(bool night) => Center(
    child: Icon(
      Icons.broken_image_outlined,
      size: 42,
      color: night ? Colors.white54 : ShelfColors.muted,
    ),
  );
}

class _ExternalPageImage extends StatefulWidget {
  const _ExternalPageImage({
    required this.controller,
    required this.page,
    required this.cacheWidth,
    required this.night,
  });

  final AppController controller;
  final RemotePage page;
  final int cacheWidth;
  final bool night;

  @override
  State<_ExternalPageImage> createState() => _ExternalPageImageState();
}

class _ExternalPageImageState extends State<_ExternalPageImage> {
  late Future<Uint8List> _load = widget.controller.loadExternalPage(
    widget.page,
  );

  @override
  void didUpdateWidget(covariant _ExternalPageImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.page.id != widget.page.id) {
      _load = widget.controller.loadExternalPage(widget.page);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: _load,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Center(
          child: Icon(
            Icons.broken_image_outlined,
            size: 42,
            color: widget.night ? Colors.white54 : ShelfColors.muted,
          ),
        );
      }
      final bytes = snapshot.data;
      if (bytes == null) {
        return Center(
          child: CircularProgressIndicator(
            color: widget.night ? Colors.white54 : ShelfColors.blue,
          ),
        );
      }
      return Image.memory(
        bytes,
        fit: BoxFit.contain,
        alignment: Alignment.topCenter,
        cacheWidth: widget.cacheWidth,
        filterQuality: FilterQuality.medium,
        errorBuilder: (context, error, stackTrace) => Center(
          child: Icon(
            Icons.broken_image_outlined,
            size: 42,
            color: widget.night ? Colors.white54 : ShelfColors.muted,
          ),
        ),
      );
    },
  );
}
