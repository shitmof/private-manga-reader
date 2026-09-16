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
import '../widgets/reader_state_views.dart';
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

  /// 本阅读页是否持有一次截屏保护申请。
  ///
  /// 必须与实际申请严格配对：阅读页只在「私密漫画」时才申请，
  /// 但退出时无条件释放会让计数凭空减一，
  /// 从而把无痕模式（或其他持有者）的保护一并解除。
  bool _holdsGuard = false;

  /// 加载失败的说明；null 表示没有失败。
  String? _loadError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_handleScroll);
    _load();
  }

  Future<void> _load() async {
    List<ComicItemRecord> items;
    try {
      items = await widget.controller.loadItems(widget.comicId);
    } catch (error) {
      // 原先这里没有错误处理：读取失败会抛出未处理的异步异常，
      // 界面永久停在加载状态且没有任何说明。
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = '无法读取这本漫画的页面：$error';
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
      _loadError = null;
    });
    if (widget.controller.summaryFor(widget.comicId)?.comic.isPrivate ??
        false) {
      _holdsGuard = true;
      await PrivateScreenGuard.acquireSecure();
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
    unawaited(_restoreSystemBrightness());
    if (_holdsGuard) {
      _holdsGuard = false;
      unawaited(PrivateScreenGuard.releaseSecure());
    }
    _scrollController.dispose();
    super.dispose();
  }

  /// 退出阅读页时交还亮度控制权。
  ///
  /// 必须自行吞掉异常：该平台通道在部分 ROM 或非 Android 环境下没有实现，
  /// 而 dispose 里的 `unawaited` 位于 try/catch 之外，
  /// 一旦抛出就会变成未处理的异步异常（测试环境下会直接判定失败）。
  Future<void> _restoreSystemBrightness() async {
    try {
      await ScreenBrightness().resetApplicationScreenBrightness();
    } catch (_) {
      // 亮度还原是尽力而为，失败不应影响退出阅读页。
    }
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
              ReaderLoadingState(night: night, label: '正在打开漫画')
            else if (_loadError case final message?)
              ReaderErrorState(
                night: night,
                message: message,
                action: FilledButton(
                  onPressed: () {
                    setState(() {
                      _loading = true;
                      _loadError = null;
                    });
                    _load();
                  },
                  child: const Text('重试'),
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
                enabled: widget.controller.preferences.readerScrubber,
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
              onTap: _items.isEmpty ? null : _promptPageInput,
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

  /// 直接输入页码跳转。
  ///
  /// 输入超范围时**修正到有效范围并明确告知**，而不是静默夹取；
  /// 输入非数字同样提示，不抛异常。
  Future<void> _promptPageInput() async {
    final total = _items.length;
    if (total == 0) return;
    final controller = TextEditingController(
      text: '${_currentIndex + 1}',
    );
    final input = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('跳转到页码'),
        content: TextField(
          key: const ValueKey<String>('reader-page-input'),
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.go,
          decoration: InputDecoration(
            labelText: '页码',
            helperText: '本漫画共 $total 页',
          ),
          onSubmitted: (value) =>
              Navigator.of(dialogContext).pop(value),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('跳转'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (input == null || !mounted) return;

    final trimmed = input.trim();
    if (trimmed.isEmpty) return;
    final parsed = int.tryParse(trimmed);
    if (parsed == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('“$trimmed”不是有效页码，请输入 1 到 $total 之间的数字')),
      );
      return;
    }
    final corrected = parsed.clamp(1, total);
    if (corrected != parsed) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已修正为第 $corrected 页（有效范围 1 到 $total）')),
      );
    }
    _jumpToPage(corrected - 1);
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
    var autoBrightness = widget.controller.preferences.followSystemBrightness;
    var surfaceMode = widget.controller.preferences.surfaceMode;
    var imageGap = widget.controller.preferences.imageGap;
    final bookmarks = await widget.controller.loadBookmarks(widget.comicId);
    if (!mounted) return;

    /// 基于**最新**偏好写入，避免同一次会话里改两项时后一项覆盖前一项。
    void apply(ReaderPreferences Function(ReaderPreferences current) mutate) {
      widget.controller.updatePreferences(
        mutate(widget.controller.preferences),
      );
    }

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      // 夜间阅读时面板跟随夜间底色，其余一律白色。
      backgroundColor: surfaceMode == ReaderSurfaceMode.night
          ? const Color(0xFF20242A)
          : ShelfColors.surface,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          final night = surfaceMode == ReaderSurfaceMode.night;
          final foreground = night ? Colors.white : ShelfColors.ink;
          final secondary = night ? Colors.white54 : ShelfColors.muted;

          Widget sectionLabel(String text) => Padding(
            padding: const EdgeInsets.only(top: 18, bottom: 6),
            child: Text(
              text,
              style: TextStyle(
                fontSize: ShelfType.caption,
                fontWeight: FontWeight.w700,
                color: secondary,
                letterSpacing: 0.4,
              ),
            ),
          );

          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    '阅读设置',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),

                  // —— 阅读背景 ——
                  sectionLabel('阅读背景'),
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
                      apply((c) => c.copyWith(surfaceMode: surfaceMode));
                      if (mounted) setState(() {});
                    },
                  ),

                  // —— 亮度 ——
                  sectionLabel('亮度'),
                  SwitchListTile(
                    key: const ValueKey<String>('reader-auto-brightness'),
                    contentPadding: EdgeInsets.zero,
                    value: autoBrightness,
                    activeThumbColor: foreground,
                    secondary: Icon(
                      Icons.brightness_auto_outlined,
                      color: secondary,
                    ),
                    title: Text(
                      '跟随手机亮度',
                      style: TextStyle(color: foreground),
                    ),
                    subtitle: Text(
                      autoBrightness
                          ? '当前使用手机自身亮度，下方滑块不生效'
                          : '使用应用内固定亮度，不随手机变化',
                      style: TextStyle(color: secondary, fontSize: 12),
                    ),
                    onChanged: (value) {
                      autoBrightness = value;
                      setSheetState(() {});
                      apply((c) => c.copyWith(followSystemBrightness: value));
                      if (value) {
                        // 交还控制权给系统，避免残留应用级覆盖。
                        _releaseBrightnessOverride();
                      } else {
                        _applyBrightness(brightness);
                      }
                    },
                  ),
                  Row(
                    children: <Widget>[
                      Icon(Icons.brightness_low, color: secondary),
                      Expanded(
                        child: Slider(
                          key: const ValueKey<String>('reader-brightness'),
                          value: brightness,
                          min: 0.05,
                          max: 1,
                          onChanged: autoBrightness
                              ? null
                              : (value) {
                                  brightness = value;
                                  setSheetState(() {});
                                  _applyBrightness(value);
                                },
                          onChangeEnd: (value) => apply(
                            (c) => c.copyWith(
                              readerBrightness: value,
                              followSystemBrightness: false,
                            ),
                          ),
                        ),
                      ),
                      Icon(Icons.brightness_high, color: secondary),
                    ],
                  ),

                  // —— 版式 ——
                  sectionLabel('版式'),
                  Row(
                    children: <Widget>[
                      Icon(Icons.space_bar_rounded, color: secondary),
                      Expanded(
                        child: Slider(
                          key: const ValueKey<String>('reader-image-gap'),
                          value: imageGap.clamp(0, 10),
                          min: 0,
                          max: 10,
                          divisions: 10,
                          label: '${imageGap.round()} dp',
                          onChanged: (value) {
                            imageGap = value;
                            setSheetState(() {});
                            apply((c) => c.copyWith(imageGap: value));
                          },
                        ),
                      ),
                      SizedBox(
                        width: 42,
                        child: Text(
                          '${imageGap.round()} dp',
                          textAlign: TextAlign.right,
                          style: TextStyle(color: secondary, fontSize: 12),
                        ),
                      ),
                    ],
                  ),

                  // —— 阅读辅助 ——
                  sectionLabel('阅读辅助'),
                  SwitchListTile(
                    key: const ValueKey<String>('reader-show-page-number'),
                    contentPadding: EdgeInsets.zero,
                    value: widget.controller.preferences.showPageNumber,
                    activeThumbColor: foreground,
                    secondary: Icon(Icons.tag_rounded, color: secondary),
                    title: Text('显示页码', style: TextStyle(color: foreground)),
                    onChanged: (value) {
                      setSheetState(() {});
                      apply((c) => c.copyWith(showPageNumber: value));
                    },
                  ),
                  SwitchListTile(
                    key: const ValueKey<String>('reader-scrubber-toggle'),
                    contentPadding: EdgeInsets.zero,
                    value: widget.controller.preferences.readerScrubber,
                    activeThumbColor: foreground,
                    secondary: Icon(
                      Icons.vertical_align_center_rounded,
                      color: secondary,
                    ),
                    title: Text(
                      '快速定位条',
                      style: TextStyle(color: foreground),
                    ),
                    subtitle: Text(
                      '关闭后右侧定位热区不响应触摸，避免翻页误触',
                      style: TextStyle(color: secondary, fontSize: 12),
                    ),
                    onChanged: (value) {
                      setSheetState(() {});
                      apply((c) => c.copyWith(readerScrubber: value));
                    },
                  ),
                  SwitchListTile(
                    key: const ValueKey<String>('reader-remember-progress'),
                    contentPadding: EdgeInsets.zero,
                    value: widget.controller.preferences.rememberProgress,
                    activeThumbColor: foreground,
                    secondary: Icon(Icons.history_rounded, color: secondary),
                    title: Text(
                      '记住阅读位置',
                      style: TextStyle(color: foreground),
                    ),
                    onChanged: (value) {
                      setSheetState(() {});
                      apply((c) => c.copyWith(rememberProgress: value));
                    },
                  ),

                  // —— 书签 ——
                  sectionLabel('书签（${bookmarks.length}）'),
                  if (bookmarks.isEmpty)
                    Text(
                      '还没有书签。阅读时点击顶部书签按钮即可收藏当前页。',
                      style: TextStyle(color: secondary, fontSize: 12),
                    )
                  else
                    SizedBox(
                      height: 40,
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
    if (widget.controller.preferences.followSystemBrightness) return;
    try {
      await ScreenBrightness().setApplicationScreenBrightness(value);
    } catch (_) {
      // 桌面测试环境或不支持的设备保持系统亮度。
    }
  }

  /// 交还亮度控制权给系统，用于用户切到"跟随手机亮度"。
  Future<void> _releaseBrightnessOverride() async {
    try {
      await ScreenBrightness().resetApplicationScreenBrightness();
    } catch (_) {
      // 未设置过应用级亮度时部分平台会抛错，忽略即可。
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
