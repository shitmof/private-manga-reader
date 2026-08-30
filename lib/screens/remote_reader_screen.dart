import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../models/entities.dart';
import '../services/page_offset_index.dart';
import '../state/app_controller.dart';

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
              Scrollbar(
                controller: _scrollController,
                interactive: true,
                thumbVisibility: true,
                thickness: 6,
                radius: const Radius.circular(3),
                child: ListView.builder(
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
                          child: Image.file(
                            File(widget.controller.filePath(page.relativePath)),
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
              ),
            _RemoteReaderTopBar(
              visible: _controlsVisible,
              title: book?.title ?? '网络漫画',
              onBack: () async {
                await _saveProgress();
                if (context.mounted) Navigator.pop(context);
              },
              onRestart: () => _scrollController.animateTo(
                0,
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeOutCubic,
              ),
            ),
            _RemoteReaderBottomBar(
              visible:
                  _controlsVisible &&
                  widget.controller.preferences.showPageNumber,
              current: _pages.isEmpty ? 0 : _currentIndex + 1,
              total: _pages.length,
              onPageChanged: _jumpToPage,
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
    await Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: true,
        pageBuilder: (context, animation, secondaryAnimation) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: Text('${_currentIndex + 1} / ${_pages.length}'),
          ),
          body: InteractiveViewer(
            minScale: 0.8,
            maxScale: 5,
            child: Center(
              child: Image.file(
                File(widget.controller.filePath(page.relativePath)),
                fit: BoxFit.contain,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RemoteReaderTopBar extends StatelessWidget {
  const _RemoteReaderTopBar({
    required this.visible,
    required this.title,
    required this.onBack,
    required this.onRestart,
  });

  final bool visible;
  final String title;
  final VoidCallback onBack;
  final VoidCallback onRestart;

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

class _RemoteReaderBottomBar extends StatelessWidget {
  const _RemoteReaderBottomBar({
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
                          value: total <= 1 ? 0 : (current - 1).toDouble(),
                          min: 0,
                          max: total <= 1 ? 0 : (total - 1).toDouble(),
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
