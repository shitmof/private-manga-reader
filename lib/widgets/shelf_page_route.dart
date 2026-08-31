import 'package:flutter/material.dart';

import '../theme.dart';

PageRoute<T> buildShelfReaderRoute<T>({required WidgetBuilder builder}) {
  return PageRouteBuilder<T>(
    opaque: true,
    transitionDuration: const Duration(milliseconds: 240),
    reverseTransitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (context, animation, secondaryAnimation) => builder(context),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final reduceMotion = MediaQuery.disableAnimationsOf(context);
      final curved = reduceMotion
          ? const AlwaysStoppedAnimation<double>(1)
          : CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      final scale = Tween<double>(begin: 0.985, end: 1).animate(curved);
      return ColoredBox(
        key: const ValueKey<String>('reader-route-transition-surface'),
        color: ShelfColors.paper,
        child: FadeTransition(
          opacity: curved,
          child: ScaleTransition(scale: scale, child: child),
        ),
      );
    },
  );
}
