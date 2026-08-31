import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

class ReaderEdgeScrubber extends StatefulWidget {
  const ReaderEdgeScrubber({
    required this.currentFraction,
    required this.currentPage,
    required this.totalPages,
    required this.onChangeStart,
    required this.onChanged,
    required this.onChangeEnd,
    this.night = false,
    super.key,
  });

  final double currentFraction;
  final int currentPage;
  final int totalPages;
  final ValueChanged<double> onChangeStart;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  final bool night;

  @override
  State<ReaderEdgeScrubber> createState() => _ReaderEdgeScrubberState();
}

class _ReaderEdgeScrubberState extends State<ReaderEdgeScrubber> {
  Timer? _hideTimer;
  bool _visible = false;
  bool _dragging = false;

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  void _reveal({bool dragging = false}) {
    _hideTimer?.cancel();
    if (_visible && _dragging == dragging) return;
    setState(() {
      _visible = true;
      _dragging = dragging;
    });
  }

  void _hideLater() {
    _hideTimer?.cancel();
    if (_dragging) setState(() => _dragging = false);
    _hideTimer = Timer(const Duration(milliseconds: 1100), () {
      if (!mounted) return;
      setState(() => _visible = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 0,
      top: MediaQuery.paddingOf(context).top + 66,
      bottom: MediaQuery.paddingOf(context).bottom + 58,
      child: LayoutBuilder(
        builder: (layoutContext, constraints) {
          double fraction(Offset globalPosition) {
            final box = layoutContext.findRenderObject()! as RenderBox;
            return (box.globalToLocal(globalPosition).dy /
                    constraints.maxHeight)
                .clamp(0, 1);
          }

          return Semantics(
            label: '快速定位滑轮，触摸后显示',
            child: GestureDetector(
              key: const ValueKey<String>('reader-fast-scrubber'),
              behavior: HitTestBehavior.opaque,
              onTapDown: (details) {
                final value = fraction(details.globalPosition);
                _reveal();
                widget.onChangeStart(value);
                widget.onChanged(value);
              },
              onTapUp: (details) {
                widget.onChangeEnd(fraction(details.globalPosition));
                _hideLater();
              },
              onTapCancel: _hideLater,
              onVerticalDragStart: (details) {
                final value = fraction(details.globalPosition);
                _reveal(dragging: true);
                HapticFeedback.selectionClick();
                widget.onChangeStart(value);
                widget.onChanged(value);
              },
              onVerticalDragUpdate: (details) =>
                  widget.onChanged(fraction(details.globalPosition)),
              onVerticalDragEnd: (_) {
                widget.onChangeEnd(widget.currentFraction);
                _hideLater();
              },
              onVerticalDragCancel: _hideLater,
              child: SizedBox(
                width: 48,
                child: AnimatedOpacity(
                  key: const ValueKey<String>(
                    'reader-fast-scrubber-visibility',
                  ),
                  opacity: _visible ? 1 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: <Widget>[
                      Positioned(
                        right: 9,
                        top: 0,
                        bottom: 0,
                        child: Container(
                          key: const ValueKey<String>(
                            'reader-fast-scrubber-track',
                          ),
                          width: 3,
                          decoration: BoxDecoration(
                            color: widget.night
                                ? Colors.white30
                                : ShelfColors.blue.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ),
                      Positioned(
                        right: 3,
                        top:
                            (constraints.maxHeight - 28) *
                            widget.currentFraction.clamp(0, 1),
                        child: Container(
                          key: const ValueKey<String>(
                            'reader-fast-scrubber-thumb',
                          ),
                          width: 15,
                          height: 28,
                          decoration: BoxDecoration(
                            color: widget.night
                                ? const Color(0xFF78ADE5)
                                : ShelfColors.blue,
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: const <BoxShadow>[
                              BoxShadow(color: Colors.black45, blurRadius: 5),
                            ],
                          ),
                        ),
                      ),
                      if (_dragging)
                        Positioned(
                          right: 27,
                          top:
                              ((constraints.maxHeight - 42) *
                                      widget.currentFraction.clamp(0, 1))
                                  .clamp(0, constraints.maxHeight - 42),
                          child: Container(
                            key: const ValueKey<String>(
                              'reader-fast-scrubber-label',
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: widget.night
                                  ? const Color(0xE6111418)
                                  : Colors.white,
                              borderRadius: BorderRadius.circular(9),
                              border: widget.night
                                  ? null
                                  : Border.all(color: ShelfColors.line),
                              boxShadow: widget.night
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
                              '${widget.currentPage} / ${widget.totalPages}',
                              style: TextStyle(
                                color: widget.night
                                    ? Colors.white
                                    : ShelfColors.blue,
                                fontWeight: FontWeight.w700,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
