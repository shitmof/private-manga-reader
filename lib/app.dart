import 'package:flutter/material.dart';

import 'models/entities.dart';
import 'screens/library_screen.dart';
import 'state/app_controller.dart';
import 'theme.dart';

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
        builder: (context, child) => Stack(
          children: <Widget>[
            child ?? const SizedBox.shrink(),
            if (controller.operation case final progress?)
              _OperationOverlay(progress: progress),
          ],
        ),
      ),
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
                    Text(
                      progress.title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 16),
                    LinearProgressIndicator(value: progress.fraction),
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
