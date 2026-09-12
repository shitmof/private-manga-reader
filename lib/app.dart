import 'package:flutter/material.dart';

import 'models/entities.dart';
import 'screens/library_screen.dart';
import 'services/privacy_service.dart';
import 'state/app_controller.dart';
import 'theme.dart';
import 'widgets/shelf_interactive.dart';

class PrivateShelfApp extends StatelessWidget {
  const PrivateShelfApp({required this.controller, super.key});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => MaterialApp(
        title: '拾画阁',
        debugShowCheckedModeBanner: false,
        theme: buildShelfTheme(Brightness.light),
        darkTheme: buildShelfTheme(Brightness.dark),
        themeMode: switch (controller.preferences.theme) {
          AppThemePreference.system => ThemeMode.system,
          AppThemePreference.light => ThemeMode.light,
          AppThemePreference.dark => ThemeMode.dark,
        },
        home: LibraryScreen(controller: controller),
        builder: (context, child) => _PrivacyShield(
          incognito: controller.preferences.incognito,
          child: Stack(
            children: <Widget>[
              child ?? const SizedBox.shrink(),
              if (controller.operation case final progress?)
                _OperationOverlay(progress: progress),
            ],
          ),
        ),
      ),
    );
  }
}

/// 无痕模式的两道保护：
/// 1. 整个应用禁止截屏与录屏（FLAG_SECURE，经 [PrivateScreenGuard] 引用计数）；
/// 2. 切到后台时立刻用不透明遮罩覆盖内容，避免多任务切换器泄露书架。
class _PrivacyShield extends StatefulWidget {
  const _PrivacyShield({required this.incognito, required this.child});

  final bool incognito;
  final Widget child;

  @override
  State<_PrivacyShield> createState() => _PrivacyShieldState();
}

class _PrivacyShieldState extends State<_PrivacyShield>
    with WidgetsBindingObserver {
  bool _masked = false;

  /// 是否已持有一次禁止截屏申请。
  ///
  /// 必须与本 widget 的申请严格配对：快速反复切换开关时，
  /// [didUpdateWidget] 可能在上一次异步申请完成前再次触发，
  /// 没有这个标记就会出现"释放多于申请"，进而误关私密漫画的保护。
  bool _holdsGuard = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _syncGuard();
  }

  @override
  void didUpdateWidget(_PrivacyShield oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.incognito != widget.incognito) _syncGuard();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final shouldMask =
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached;
    if (!widget.incognito || shouldMask == _masked) return;
    setState(() => _masked = shouldMask);
  }

  Future<void> _syncGuard() async {
    if (widget.incognito == _holdsGuard) return;
    if (widget.incognito) {
      _holdsGuard = true;
      await PrivateScreenGuard.acquireSecure();
    } else {
      _holdsGuard = false;
      await PrivateScreenGuard.releaseSecure();
      // 本方法可能在 build 期间被触发，遮罩复位放到帧末执行。
      if (_masked) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _masked) setState(() => _masked = false);
        });
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_holdsGuard) {
      _holdsGuard = false;
      // ignore: discarded_futures
      PrivateScreenGuard.releaseSecure();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        widget.child,
        if (widget.incognito && _masked)
          const Positioned.fill(
            child: ColoredBox(
              key: ValueKey<String>('incognito-background-mask'),
              color: ShelfColors.dark,
              child: Center(
                child: Icon(
                  Icons.visibility_off_outlined,
                  color: Colors.white24,
                  size: 56,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _OperationOverlay extends StatelessWidget {
  const _OperationOverlay({required this.progress});

  final OperationProgress progress;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        const ModalBarrier(dismissible: false, color: Color(0x66000000)),
        Center(
          child: Material(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(20),
            child: SizedBox(
              width: 286,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        ShelfLoader(
                          size: 22,
                          strokeWidth: 2.6,
                          progress: progress.fraction,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            progress.title,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: progress.fraction,
                        minHeight: 5,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      progress.detail,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (progress.total > 0) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        '${progress.completed} / ${progress.total}',
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
