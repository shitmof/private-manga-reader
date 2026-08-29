import 'package:flutter/material.dart';

import '../models/entities.dart';
import '../state/app_controller.dart';
import '../theme.dart';
import '../widgets/formatters.dart';
import '../widgets/import_flow.dart';
import '../widgets/private_image.dart';
import 'comic_detail_screen.dart';
import 'editor_screen.dart';
import 'settings_screen.dart';

class LibraryScreen extends StatelessWidget {
  const LibraryScreen({required this.controller, super.key});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('私人书架'),
              Text(
                '只保存在你的设备中',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: ShelfColors.muted,
                  letterSpacing: 0.15,
                ),
              ),
            ],
          ),
          actions: <Widget>[
            IconButton(
              tooltip: '设置',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SettingsScreen(controller: controller),
                ),
              ),
              icon: const Icon(Icons.tune_rounded),
            ),
            const SizedBox(width: 6),
          ],
        ),
        body: controller.library.isEmpty
            ? _EmptyLibrary(onCreate: () => _createComic(context))
            : _LibraryGrid(controller: controller),
        floatingActionButton: FloatingActionButton(
          onPressed: () => _createComic(context),
          tooltip: '新建漫画',
          child: const Icon(Icons.add_rounded),
        ),
      ),
    );
  }

  Future<void> _createComic(BuildContext context) async {
    final textController = TextEditingController();
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建漫画'),
        content: TextField(
          controller: textController,
          autofocus: true,
          maxLength: 80,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            hintText: '输入漫画或图集名称',
            counterText: '',
          ),
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) Navigator.pop(context, value.trim());
          },
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final value = textController.text.trim();
              if (value.isNotEmpty) Navigator.pop(context, value);
            },
            child: const Text('下一步'),
          ),
        ],
      ),
    );
    if (title == null || !context.mounted) return;
    final comic = await controller.createComic(title);
    if (!context.mounted) return;
    final report = await runImportFlow(
      context: context,
      controller: controller,
      comicId: comic.id,
    );
    if (!context.mounted) return;
    if (report != null && report.imported > 0) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => EditorScreen(
            controller: controller,
            comicId: comic.id,
          ),
        ),
      );
    } else {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ComicDetailScreen(
            controller: controller,
            comicId: comic.id,
          ),
        ),
      );
    }
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Container(
              width: 92,
              height: 92,
              decoration: BoxDecoration(
                color: ShelfColors.blueSoft,
                borderRadius: BorderRadius.circular(28),
              ),
              child: const Icon(
                Icons.collections_bookmark_outlined,
                size: 42,
                color: ShelfColors.blue,
              ),
            ),
            const SizedBox(height: 24),
            Text('这里还没有漫画',
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 10),
            const Text(
              '从相册或文件导入原图。导入后即使源图被删除，书架中的副本仍可正常阅读。',
              textAlign: TextAlign.center,
              style: TextStyle(color: ShelfColors.muted, height: 1.55),
            ),
            const SizedBox(height: 26),
            FilledButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: const Text('新建第一本漫画'),
            ),
          ],
        ),
      ),
    );
  }
}

class _LibraryGrid extends StatelessWidget {
  const _LibraryGrid({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final cardWidth = (width - 44) / 2;
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 104),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 22,
        childAspectRatio: 0.68,
      ),
      itemCount: controller.library.length,
      itemBuilder: (context, index) {
        final summary = controller.library[index];
        return DragTarget<int>(
          onWillAcceptWithDetails: (details) => details.data != index,
          onAcceptWithDetails: (details) =>
              controller.reorderComics(details.data, index),
          builder: (context, candidates, rejected) => LongPressDraggable<int>(
            data: index,
            feedback: SizedBox(
              width: cardWidth,
              height: cardWidth / 0.68,
              child: Material(
                color: Colors.transparent,
                elevation: 8,
                borderRadius: BorderRadius.circular(18),
                child: _ComicCard(
                  controller: controller,
                  summary: summary,
                  onTap: null,
                  onDelete: null,
                ),
              ),
            ),
            childWhenDragging: Opacity(
              opacity: 0.26,
              child: _ComicCard(
                controller: controller,
                summary: summary,
                onTap: null,
                onDelete: null,
              ),
            ),
            child: AnimatedScale(
              duration: const Duration(milliseconds: 150),
              scale: candidates.isEmpty ? 1 : 0.96,
              child: _ComicCard(
                controller: controller,
                summary: summary,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ComicDetailScreen(
                      controller: controller,
                      comicId: summary.comic.id,
                    ),
                  ),
                ),
                onDelete: () => _moveToTrash(context, summary),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _moveToTrash(
    BuildContext context,
    ComicSummary summary,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移到回收站？'),
        content: Text('“${summary.comic.title}”可以稍后在设置的回收站中恢复，原图不会立即删除。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移到回收站'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await controller.deleteComic(summary.comic.id);
    }
  }
}

class _ComicCard extends StatelessWidget {
  const _ComicCard({
    required this.controller,
    required this.summary,
    required this.onTap,
    required this.onDelete,
  });

  final AppController controller;
  final ComicSummary summary;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                Hero(
                  tag: 'cover-${summary.comic.id}',
                  child: summary.coverStoredPath == null
                      ? Container(
                      decoration: BoxDecoration(
                        color: ShelfColors.blueSoft,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: ShelfColors.line),
                      ),
                      child: const Center(
                        child: Icon(Icons.image_outlined,
                            color: ShelfColors.blue, size: 34),
                      ),
                    )
                      : PrivateImage(
                      controller: controller,
                      originalPath: summary.coverStoredPath!,
                      thumbnailPath: summary.coverThumbnailPath,
                      cacheWidth: 420,
                        ),
                ),
                if (onDelete != null)
                  Positioned(
                    right: 6,
                    top: 6,
                    child: Material(
                      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.9),
                      shape: const CircleBorder(),
                      child: IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: '移到回收站',
                        onPressed: onDelete,
                        icon: const Icon(Icons.more_horiz_rounded, size: 19),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            summary.comic.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 3),
          Text(
            '${summary.itemCount} 张 · ${formatBytes(summary.totalBytes)}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: ShelfColors.muted,
                ),
          ),
        ],
      ),
    );
  }
}
