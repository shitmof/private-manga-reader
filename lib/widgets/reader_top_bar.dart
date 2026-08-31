import 'package:flutter/material.dart';

import '../theme.dart';

class ReaderTopBar extends StatelessWidget {
  const ReaderTopBar({
    required this.visible,
    required this.title,
    required this.onBack,
    required this.onRestart,
    this.onBookmark,
    this.onSettings,
    this.night = false,
    super.key,
  });

  final bool visible;
  final String title;
  final VoidCallback onBack;
  final VoidCallback onRestart;
  final VoidCallback? onBookmark;
  final VoidCallback? onSettings;
  final bool night;

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final foreground = night ? Colors.white : ShelfColors.blue;
    final textColor = night ? Colors.white : ShelfColors.ink;
    final duration = Duration(milliseconds: reduceMotion ? 80 : 170);
    return AnimatedSlide(
      offset: visible || reduceMotion ? Offset.zero : const Offset(0, -0.14),
      duration: duration,
      curve: Curves.easeOutCubic,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: duration,
        child: IgnorePointer(
          ignoring: !visible,
          child: DecoratedBox(
            key: const ValueKey<String>('reader-top-bar-surface'),
            decoration: BoxDecoration(
              color: night
                  ? const Color(0xE6111418)
                  : Colors.white.withValues(alpha: 0.96),
              border: Border(
                bottom: BorderSide(
                  color: night ? Colors.white10 : ShelfColors.line,
                ),
              ),
              boxShadow: night
                  ? const <BoxShadow>[]
                  : const <BoxShadow>[
                      BoxShadow(
                        color: Color(0x0F173A63),
                        blurRadius: 18,
                        offset: Offset(0, 5),
                      ),
                    ],
            ),
            child: SafeArea(
              bottom: false,
              child: SizedBox(
                height: 56,
                child: Row(
                  children: <Widget>[
                    IconButton(
                      tooltip: '返回',
                      onPressed: onBack,
                      color: foreground,
                      icon: const Icon(Icons.arrow_back_ios_new_rounded),
                    ),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: textColor,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (onBookmark != null)
                      IconButton(
                        tooltip: '收藏当前页',
                        onPressed: onBookmark,
                        color: foreground,
                        icon: const Icon(Icons.bookmark_add_outlined),
                      ),
                    if (onSettings != null)
                      IconButton(
                        tooltip: '阅读设置',
                        onPressed: onSettings,
                        color: foreground,
                        icon: const Icon(Icons.settings_outlined),
                      ),
                    PopupMenuButton<String>(
                      tooltip: '更多',
                      color: night ? const Color(0xFF20242A) : Colors.white,
                      iconColor: foreground,
                      onSelected: (_) => onRestart(),
                      itemBuilder: (context) => <PopupMenuEntry<String>>[
                        PopupMenuItem(
                          value: 'restart',
                          child: Text(
                            '从头开始',
                            style: TextStyle(color: textColor),
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
