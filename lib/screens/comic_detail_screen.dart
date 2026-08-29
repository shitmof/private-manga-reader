import 'package:flutter/material.dart';

import '../state/app_controller.dart';
import '../theme.dart';
import '../widgets/formatters.dart';
import '../widgets/import_flow.dart';
import '../widgets/private_image.dart';
import 'editor_screen.dart';
import 'reader_screen.dart';

class ComicDetailScreen extends StatelessWidget {
  const ComicDetailScreen({
    required this.controller,
    required this.comicId,
    super.key,
  });

  final AppController controller;
  final String comicId;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final summary = controller.summaryFor(comicId);
        if (summary == null) {
          return const Scaffold(body: Center(child: Text('这本漫画已不存在')));
        }
        final comic = summary.comic;
        return Scaffold(
          appBar: AppBar(
            title: Text(comic.title),
            actions: <Widget>[
              PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'rename') _rename(context, comic.title);
                  if (value == 'delete') _delete(context);
                },
                itemBuilder: (context) => const <PopupMenuEntry<String>>[
                  PopupMenuItem(value: 'rename', child: Text('重命名')),
                  PopupMenuItem(value: 'delete', child: Text('删除漫画')),
                ],
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
            children: <Widget>[
              Hero(
                tag: 'cover-$comicId',
                child: AspectRatio(
                  aspectRatio: 1.55,
                  child: summary.coverStoredPath == null
                      ? Container(
                          decoration: BoxDecoration(
                            color: ShelfColors.blueSoft,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Center(
                            child: Icon(Icons.image_outlined,
                                size: 48, color: ShelfColors.blue),
                          ),
                        )
                      : PrivateImage(
                          controller: controller,
                          originalPath: summary.coverStoredPath!,
                          thumbnailPath: summary.coverThumbnailPath,
                          cacheWidth: 900,
                          borderRadius: BorderRadius.circular(20),
                        ),
                ),
              ),
              const SizedBox(height: 22),
              Row(
                children: <Widget>[
                  Expanded(child: _Metric(label: '图片', value: '${summary.itemCount} 张')),
                  const SizedBox(width: 10),
                  Expanded(child: _Metric(label: '原图占用', value: formatBytes(summary.totalBytes))),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _Metric(
                      label: '上次阅读',
                      value: summary.itemCount == 0
                          ? '—'
                          : '第 ${comic.lastReadPosition + 1} 张',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              if (summary.itemCount > 0) ...<Widget>[
                FilledButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ReaderScreen(
                        controller: controller,
                        comicId: comicId,
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.auto_stories_outlined),
                  label: Text(
                    comic.lastReadPosition > 0 ? '继续阅读' : '开始阅读',
                  ),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => EditorScreen(
                        controller: controller,
                        comicId: comicId,
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.grid_view_outlined),
                  label: const Text('编辑图片顺序'),
                ),
              ] else ...<Widget>[
                FilledButton.icon(
                  onPressed: () => runImportFlow(
                    context: context,
                    controller: controller,
                    comicId: comicId,
                  ),
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  label: const Text('导入图片'),
                ),
                const SizedBox(height: 12),
                const Text(
                  '空漫画不会显示任何占位图片。导入后，第一张图片会自动作为默认封面。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: ShelfColors.muted, height: 1.5),
                ),
              ],
              const SizedBox(height: 28),
              Text('管理', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 10),
              Card(
                margin: EdgeInsets.zero,
                child: Column(
                  children: <Widget>[
                    ListTile(
                      leading: const Icon(Icons.add_photo_alternate_outlined),
                      title: const Text('追加图片'),
                      subtitle: const Text('新图片默认添加到末尾'),
                      enabled: summary.itemCount < 1000,
                      onTap: () async {
                        await runImportFlow(
                          context: context,
                          controller: controller,
                          comicId: comicId,
                        );
                      },
                    ),
                    const Divider(height: 1, indent: 56),
                    ListTile(
                      leading: const Icon(Icons.cloud_download_outlined),
                      title: const Text('创建完整备份'),
                      subtitle: const Text('包含整个书架结构与所有原图'),
                      onTap: () => _backup(context),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '创建于 ${formatDate(comic.createdAt)} · 最多 1000 张',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: ShelfColors.muted,
                    ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _rename(BuildContext context, String current) async {
    final text = TextEditingController(text: current);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(controller: text, autofocus: true, maxLength: 80),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              if (text.text.trim().isNotEmpty) Navigator.pop(context, text.text.trim());
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (value != null) await controller.renameComic(comicId, value);
  }

  Future<void> _delete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这本漫画？'),
        content: const Text('漫画会移到回收站，可以稍后恢复。原图不会立即删除。'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移到回收站'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await controller.deleteComic(comicId);
    if (context.mounted) Navigator.pop(context);
  }

  Future<void> _backup(BuildContext context) async {
    try {
      final file = await controller.createAndShareBackup();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('备份已创建：${file.path.split(RegExp(r'[/\\]')).last}')),
        );
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('备份失败：$error')),
        );
      }
    }
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: ShelfColors.muted,
                  )),
          const SizedBox(height: 4),
          Text(value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  )),
        ],
      ),
    );
  }
}
