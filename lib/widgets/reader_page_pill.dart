import 'package:flutter/material.dart';

import '../theme.dart';

class ReaderPagePill extends StatelessWidget {
  const ReaderPagePill({
    required this.visible,
    required this.current,
    required this.total,
    this.night = false,
    super.key,
  });

  final bool visible;
  final int current;
  final int total;
  final bool night;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: AnimatedSlide(
            offset: visible ? Offset.zero : const Offset(0, 0.7),
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            child: AnimatedOpacity(
              opacity: visible ? 1 : 0,
              duration: const Duration(milliseconds: 150),
              child: IgnorePointer(
                ignoring: !visible,
                child: Container(
                  key: const ValueKey<String>('reader-page-pill'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: night ? const Color(0xE6111418) : Colors.white,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: night ? Colors.white12 : ShelfColors.line,
                    ),
                    boxShadow: night
                        ? const <BoxShadow>[]
                        : const <BoxShadow>[
                            BoxShadow(
                              color: Color(0x14173A63),
                              blurRadius: 14,
                              offset: Offset(0, 4),
                            ),
                          ],
                  ),
                  child: Text(
                    '$current / $total',
                    style: TextStyle(
                      color: night ? Colors.white : ShelfColors.blue,
                      fontWeight: FontWeight.w700,
                      fontSize: 11.5,
                      height: 1,
                    ),
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
