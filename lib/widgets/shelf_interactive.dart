import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// 交互反馈组件集合。
///
/// 视觉参考 Uiverse 社区组件（MIT）的渐变/光晕/按压回弹语言，
/// 但全部在 Flutter 中以 widget + CustomPainter 重新实现，
/// 不引入任何 CSS 或 WebView 依赖。
///
/// 设计约束（遵守 docs/V1.2 的"UI 风格冻结"）：
/// - 只提升交互质感（按压、开关、加载），不改变布局结构与信息层级。
/// - 颜色一律取自 [ShelfColors]，夜间态由调用方传入 [night] 切换。

/// 带按压回弹与开关过渡的开关行，替代裸 [SwitchListTile]。
class ShelfSwitchTile extends StatelessWidget {
  const ShelfSwitchTile({
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.leading,
    this.night = false,
    super.key,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Widget? leading;
  final bool night;

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    final secondary = night ? Colors.white54 : ShelfColors.muted;
    return ListTile(
      enabled: enabled,
      leading: leading,
      title: Text(title),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, style: TextStyle(color: secondary, fontSize: 12)),
      trailing: _ShelfSwitch(
        value: value,
        enabled: enabled,
        onChanged: onChanged,
      ),
      onTap: enabled ? () => onChanged!(!value) : null,
    );
  }
}

class _ShelfSwitch extends StatelessWidget {
  const _ShelfSwitch({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final bool value;
  final bool enabled;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      toggled: value,
      child: GestureDetector(
        onTap: enabled ? () => onChanged!(!value) : null,
        child: AnimatedContainer(
          duration: ShelfMotion.control,
          curve: Curves.easeOutCubic,
          width: 50,
          height: 30,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            gradient: value
                ? LinearGradient(
                    colors: <Color>[
                      scheme.primary,
                      Color.lerp(scheme.primary, Colors.white, 0.22)!,
                    ],
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                  )
                : null,
            color: value
                ? null
                : (enabled
                      ? scheme.surfaceContainerHighest
                      : scheme.surfaceContainerHighest.withValues(alpha: 0.5)),
            borderRadius: BorderRadius.circular(15),
            boxShadow: value
                ? <BoxShadow>[
                    BoxShadow(
                      color: scheme.primary.withValues(alpha: 0.32),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ]
                : const <BoxShadow>[],
          ),
          child: AnimatedAlign(
            duration: ShelfMotion.control,
            curve: Curves.easeOutBack,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 4,
                    offset: Offset(0, 1),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 主行动按钮：按下时轻微下沉 + 光晕收缩，松开回弹。
class ShelfGlowButton extends StatefulWidget {
  const ShelfGlowButton({
    required this.label,
    required this.onPressed,
    this.icon,
    this.expanded = true,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool expanded;

  @override
  State<ShelfGlowButton> createState() => _ShelfGlowButtonState();
}

class _ShelfGlowButtonState extends State<ShelfGlowButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = widget.onPressed != null;
    final button = AnimatedScale(
      scale: _pressed ? 0.97 : 1,
      duration: ShelfMotion.press,
      curve: Curves.easeOut,
      child: AnimatedContainer(
        duration: ShelfMotion.toolbar,
        height: 52,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: <Color>[
              scheme.primary,
              Color.lerp(scheme.primary, Colors.white, 0.18)!,
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(15),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: scheme.primary.withValues(
                alpha: enabled ? (_pressed ? 0.16 : 0.34) : 0.12,
              ),
              blurRadius: _pressed ? 6 : 16,
              offset: Offset(0, _pressed ? 2 : 6),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(15),
            onTap: widget.onPressed,
            onHighlightChanged: (value) {
              if (mounted) setState(() => _pressed = value);
            },
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (widget.icon case final icon?) ...<Widget>[
                    Icon(icon, size: 18, color: scheme.onPrimary),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    widget.label,
                    style: TextStyle(
                      color: scheme.onPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (!widget.expanded) return button;
    return SizedBox(width: double.infinity, child: button);
  }
}

/// 加载指示器：外圈呼吸光环 + 内圈转速可变的弧。
///
/// 用单帧绘制替代 [CircularProgressIndicator]，让长任务等待不那么呆板；
/// [progress] 为 null 时进入不确定态。
class ShelfLoader extends StatefulWidget {
  const ShelfLoader({
    this.size = 40,
    this.strokeWidth = 3.4,
    this.progress,
    this.color,
    this.night = false,
    super.key,
  });

  final double size;
  final double strokeWidth;
  final double? progress;
  final Color? color;
  final bool night;

  @override
  State<ShelfLoader> createState() => _ShelfLoaderState();
}

class _ShelfLoaderState extends State<ShelfLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1250),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color =
        widget.color ?? (widget.night ? Colors.white : scheme.primary);
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => CustomPaint(
          painter: _LoaderPainter(
            t: _controller.value,
            color: color,
            strokeWidth: widget.strokeWidth,
            progress: widget.progress,
          ),
        ),
      ),
    );
  }
}

class _LoaderPainter extends CustomPainter {
  const _LoaderPainter({
    required this.t,
    required this.color,
    required this.strokeWidth,
    required this.progress,
  });

  final double t;
  final Color color;
  final double strokeWidth;
  final double? progress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - strokeWidth) / 2;

    // 呼吸光环
    final breath = 0.5 + 0.5 * math.sin(t * 2 * math.pi);
    canvas.drawCircle(
      center,
      radius + 3,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = color.withValues(alpha: 0.10 + 0.14 * breath),
    );

    // 轨道
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..color = color.withValues(alpha: 0.16),
    );

    final rect = Rect.fromCircle(center: center, radius: radius);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    if (progress case final value?) {
      final sweep = (value.clamp(0, 1)) * 2 * math.pi;
      if (sweep <= 0) return;
      paint.shader = SweepGradient(
        startAngle: -math.pi / 2,
        endAngle: -math.pi / 2 + 2 * math.pi,
        colors: <Color>[color.withValues(alpha: 0.45), color],
      ).createShader(rect);
      canvas.drawArc(rect, -math.pi / 2, sweep, false, paint);
      return;
    }

    // 不确定态：一段 90° 弧旋转 + 头部渐隐
    paint.shader = SweepGradient(
      startAngle: 0,
      endAngle: 2 * math.pi,
      colors: <Color>[
        color.withValues(alpha: 0.0),
        color.withValues(alpha: 0.55),
        color,
      ],
      stops: const <double>[0, 0.55, 1],
    ).createShader(rect);
    canvas.drawArc(rect, t * 2 * math.pi, math.pi / 2, false, paint);
  }

  @override
  bool shouldRepaint(_LoaderPainter oldDelegate) =>
      oldDelegate.t != t ||
      oldDelegate.progress != progress ||
      oldDelegate.color != color ||
      oldDelegate.strokeWidth != strokeWidth;
}
