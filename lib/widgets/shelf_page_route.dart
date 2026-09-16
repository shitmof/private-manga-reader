import 'package:flutter/material.dart';

import '../theme.dart';

PageRoute<T> buildShelfReaderRoute<T>({required WidgetBuilder builder}) {
  return PageRouteBuilder<T>(
    opaque: true,
    transitionDuration: ShelfMotion.pageEnter,
    reverseTransitionDuration: ShelfMotion.pageExit,
    pageBuilder: (context, animation, secondaryAnimation) => builder(context),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final reduceMotion = MediaQuery.disableAnimationsOf(context);
      final curved = reduceMotion
          ? const AlwaysStoppedAnimation<double>(1)
          : CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      final scale = Tween<double>(begin: 0.985, end: 1).animate(curved);
      return ColoredBox(
        key: const ValueKey<String>('reader-route-transition-surface'),
        // 过渡底色必须跟随当前主题，而不是写死画纸色：
        // 夜间模式下写死浅色会先闪一下白底再变黑（规范 5.1 要求不得闪底）。
        color: Theme.of(context).scaffoldBackgroundColor,
        child: FadeTransition(
          opacity: curved,
          child: ScaleTransition(scale: scale, child: child),
        ),
      );
    },
  );
}
