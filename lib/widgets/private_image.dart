import 'dart:io';

import 'package:flutter/material.dart';

import '../state/app_controller.dart';
import '../theme.dart';

class PrivateImage extends StatelessWidget {
  const PrivateImage({
    required this.controller,
    required this.originalPath,
    super.key,
    this.thumbnailPath,
    this.fit = BoxFit.cover,
    this.cacheWidth,
    this.borderRadius = const BorderRadius.all(Radius.circular(16)),
  });

  final AppController controller;
  final String originalPath;
  final String? thumbnailPath;
  final BoxFit fit;
  final int? cacheWidth;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final thumbnail = thumbnailPath == null
        ? null
        : File(controller.filePath(thumbnailPath!));
    final original = File(controller.filePath(originalPath));
    final source = thumbnail != null && thumbnail.existsSync()
        ? thumbnail
        : original;
    return ClipRRect(
      borderRadius: borderRadius,
      child: Image.file(
        source,
        fit: fit,
        width: double.infinity,
        height: double.infinity,
        cacheWidth: cacheWidth,
        filterQuality: FilterQuality.low,
        errorBuilder: (context, error, stackTrace) => ColoredBox(
          color: Theme.of(context).brightness == Brightness.dark
              ? Colors.white10
              : ShelfColors.blueSoft,
          child: const Center(
            child: Icon(Icons.broken_image_outlined, color: ShelfColors.muted),
          ),
        ),
      ),
    );
  }
}
