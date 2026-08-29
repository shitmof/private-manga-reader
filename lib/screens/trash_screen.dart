import 'package:flutter/material.dart';

import '../models/entities.dart';
import '../state/app_controller.dart';
import '../theme.dart';
import '../widgets/private_image.dart';

class TrashScreen extends StatefulWidget {
  const TrashScreen({required this.controller, super.key});

  final AppController controller;

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  late Future<List<ComicSummary>> _items =
      widget.controller.loadDeletedComics();

  void _reload() {
    setState(() => _items = widget.controller.loadDeletedComics());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('回收站')),
      body: FutureBuilder<List<ComicSummary>>(
        future: _items,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = snapshot.data!;
          if (items.isEmpty) {
            return const Center(
              child: Text(
                '回收站是空的',
                style: TextStyle(color: ShelfColors.muted),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final summary = items[index];
              return Card(
                margin: EdgeInsets.zero,
                child: ListTile(
                  contentPadding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                  leading: SizedBox(
                    width: 48,
                    height: 64,
                    child: summary.coverStoredPath == null
                        ? const DecoratedBox(
                            decoration: BoxDecoration(
                              color: ShelfColors.blueSoft,
                              borderRadius: BorderRadius.all(Radius.circular(8)),
                            ),
                            child: Icon(Icons.image_outlined),
                          )
                        : PrivateImage(
                            controller: widget.controller,
                            originalPath: summary.coverStoredPath!,
                            thumbnailPath: summary.coverThumbnailPath,
                            cacheWidth: 180,
                            borderRadius: BorderRadius.circular(8),
                          ),
                  ),
                  title: Text(
                    summary.comic.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text('${summary.itemCount} 张'),
                  trailing: PopupMenuButton<String>(
                    onSelected: (value) {
                      if (value == 'restore') _restore(summary.comic.id);
                      if (value == 'delete') _permanentDelete(summary);
                    },
                    itemBuilder: (_) => const <PopupMenuEntry<String>>[
                      PopupMenuItem(value: 'restore', child: Text('恢复')),
                      PopupMenuItem(value: 'delete', child: Text('永久删除')),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _restore(String comicId) async {
    await widget.controller.restoreComic(comicId);
    _reload();
  }

  Future<void> _permanentDelete(ComicSummary summary) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('永久删除这本漫画？'),
        content: Text(
          '“${summary.comic.title}”将无法从回收站恢复。仅由它引用的本地原图也会被删除；被其他漫画引用的原图会保留。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('永久删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.controller.permanentlyDeleteComic(summary.comic.id);
    _reload();
  }
}
