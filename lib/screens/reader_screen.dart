import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../models/entities.dart';
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
    final summary = widget.controller.summaryFor(widget.comicId);
    final title = summary?.comic.title ?? '阅读';
    final gap = widget.controller.preferences.imageGap;
    final width = MediaQuery.sizeOf(context).width;
    _lastLayoutWidth = width;
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
            ),
            _ReaderBottomBar(
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

  void _restoreProgress() {
    if (!_scrollController.hasClients || _items.isEmpty) return;
    final comic = widget.controller.summaryFor(widget.comicId)?.comic;
    if (comic == null || !widget.controller.preferences.rememberProgress) {
      return;
    }
    final targetIndex = comic.lastReadPosition.clamp(0, _items.length - 1);
    var offset = 0.0;
    for (var index = 0; index < targetIndex; index++) {
      offset +=
          _displayHeight(_items[index], _lastLayoutWidth) +
          widget.controller.preferences.imageGap;
    }
    offset += comic.lastReadOffset;
    _scrollController.jumpTo(
      offset.clamp(0, _scrollController.position.maxScrollExtent),
    );
    _handleScroll();
  }

  void _handleScroll() {
    if (_items.isEmpty || _lastLayoutWidth <= 0) return;
    final offset = _scrollController.offset;
    var top = 0.0;
    var index = 0;
    final gap = widget.controller.preferences.imageGap;
    for (var current = 0; current < _items.length; current++) {
      final extent = _displayHeight(_items[current], _lastLayoutWidth) + gap;
      if (top + extent * 0.58 > offset) {
        index = current;
        break;
      }
      top += extent;
      index = current;
    }
    if (index != _currentIndex && mounted) {
      setState(() => _currentIndex = index);
    }
  }

  Future<void> _saveProgress() async {
    if (_items.isEmpty || _lastLayoutWidth <= 0) return;
    var top = 0.0;
    final gap = widget.controller.preferences.imageGap;
    for (var index = 0; index < _currentIndex; index++) {
      top += _displayHeight(_items[index], _lastLayoutWidth) + gap;
    }
    final within = _scrollController.hasClients
        ? (_scrollController.offset - top).clamp(0.0, double.infinity)
        : 0.0;
    await widget.controller.saveProgress(widget.comicId, _currentIndex, within);
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

class _ReaderBottomBar extends StatelessWidget {
  const _ReaderBottomBar({
    required this.visible,
    required this.current,
    required this.total,
  });

  final bool visible;
  final int current;
  final int total;

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
                        child: LinearProgressIndicator(
                          value: total == 0 ? 0 : current / total,
                          minHeight: 3,
                          color: const Color(0xFF78ADE5),
                          backgroundColor: Colors.white24,
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
