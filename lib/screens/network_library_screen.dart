import 'dart:io';

import 'package:flutter/material.dart';

import '../models/entities.dart';
import '../state/app_controller.dart';
import '../theme.dart';
import '../widgets/formatters.dart';
import 'remote_reader_screen.dart';

class NetworkLibraryScreen extends StatelessWidget {
  const NetworkLibraryScreen({
    required this.controller,
    required this.sourceId,
    super.key,
  });

  final AppController controller;
  final String sourceId;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final source = controller.networkSources
            .where((item) => item.id == sourceId)
            .firstOrNull;
        if (source == null) {
          return const Scaffold(body: Center(child: Text('网络书库已被移除')));
        }
        final books = controller.booksForSource(sourceId);
        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(source.name),
                Text(
                  source.type == NetworkSourceType.local
                      ? '原地直读 · 不复制原图'
                      : '远程只读 · 进度仅存本机',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: ShelfColors.muted,
                  ),
                ),
              ],
            ),
            actions: <Widget>[
              IconButton(
                tooltip: '重新扫描',
                onPressed: () => _refresh(context, source),
                icon: const Icon(Icons.refresh_rounded),
              ),
              const SizedBox(width: 6),
            ],
          ),
          body: books.isEmpty
              ? _EmptyMountedSource(
                  isLocal: source.type == NetworkSourceType.local,
                  onRefresh: () => _refresh(context, source),
                )
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 22,
                    childAspectRatio: 0.68,
                  ),
                  itemCount: books.length,
                  itemBuilder: (context, index) => _RemoteBookCard(
                    controller: controller,
                    book: books[index],
                    isLocal: source.type == NetworkSourceType.local,
                    onTap: () => _openBook(context, books[index]),
                    onClearCache:
                        source.type == NetworkSourceType.local ||
                            books[index].pageCount == 0
                        ? null
                        : () => _clearCache(context, books[index]),
                  ),
                ),
        );
      },
    );
  }

  Future<void> _refresh(BuildContext context, NetworkSource source) async {
    try {
      await controller.scanNetworkSource(source);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已同步 ${source.name}')));
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('同步失败：${_friendly(error)}')));
      }
    }
  }

  Future<void> _openBook(BuildContext context, RemoteBook book) async {
    if (!book.isAvailable && !book.isCached) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('远程文件当前不可用，请先重新扫描')));
      return;
    }
    try {
      await controller.prepareRemoteBook(book.id);
      if (!context.mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              RemoteReaderScreen(controller: controller, bookId: book.id),
        ),
      );
    } catch (error) {
      if (context.mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('无法打开漫画'),
            content: Text(_friendly(error)),
            actions: <Widget>[
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('知道了'),
              ),
            ],
          ),
        );
      }
    }
  }

  Future<void> _clearCache(BuildContext context, RemoteBook book) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除本地缓存？'),
        content: const Text('不会删除远程文件，也不会清除阅读进度。下次打开时会重新读取。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清除缓存'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.clearRemoteBookCache(book.id);
  }
}

class _RemoteBookCard extends StatelessWidget {
  const _RemoteBookCard({
    required this.controller,
    required this.book,
    required this.isLocal,
    required this.onTap,
    required this.onClearCache,
  });

  final AppController controller;
  final RemoteBook book;
  final bool isLocal;
  final VoidCallback onTap;
  final VoidCallback? onClearCache;

  @override
  Widget build(BuildContext context) {
    final cover = book.coverRelativePath == null
        ? null
        : File(controller.filePath(book.coverRelativePath!));
    return Opacity(
      opacity: book.isAvailable || book.isCached ? 1 : 0.55,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: cover != null && cover.existsSync()
                        ? Image.file(
                            cover,
                            fit: BoxFit.cover,
                            cacheWidth: 420,
                            filterQuality: FilterQuality.low,
                          )
                        : ColoredBox(
                            color: ShelfColors.blueSoft,
                            child: Center(
                              child: Icon(
                                isLocal
                                    ? Icons.folder_open_rounded
                                    : Icons.cloud_outlined,
                                color: ShelfColors.blue,
                                size: 36,
                              ),
                            ),
                          ),
                  ),
                  Positioned(
                    left: 8,
                    bottom: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xCC111418),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        isLocal
                            ? (book.isExternalIndexed ? '原地直读' : '本地')
                            : (book.isCached ? '已缓存' : '网络'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  if (onClearCache != null)
                    Positioned(
                      right: 6,
                      top: 6,
                      child: Material(
                        color: Theme.of(
                          context,
                        ).colorScheme.surface.withValues(alpha: 0.9),
                        shape: const CircleBorder(),
                        child: PopupMenuButton<String>(
                          tooltip: '缓存管理',
                          icon: const Icon(Icons.more_horiz_rounded, size: 19),
                          onSelected: (_) => onClearCache?.call(),
                          itemBuilder: (context) =>
                              const <PopupMenuEntry<String>>[
                                PopupMenuItem(
                                  value: 'clear',
                                  child: Text('清除本地缓存'),
                                ),
                              ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Text(
              book.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 3),
            Text(
              book.pageCount > 0
                  ? '${book.pageCount} 张 · 读到第 ${book.lastReadPosition + 1} 张'
                  : formatBytes(book.byteSize),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: ShelfColors.muted),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyMountedSource extends StatelessWidget {
  const _EmptyMountedSource({required this.isLocal, required this.onRefresh});

  final bool isLocal;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.cloud_sync_outlined,
              size: 46,
              color: ShelfColors.blue,
            ),
            const SizedBox(height: 18),
            Text('还没有扫描到漫画', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              isLocal
                  ? '检查目录中是否有 ZIP/CBZ，或存放 JPG、PNG、WebP 的图片文件夹。'
                  : '检查根目录中是否有 CBZ、CBR、CB7、CBT、ZIP、RAR、7z 或 TAR 文件。',
              textAlign: TextAlign.center,
              style: const TextStyle(color: ShelfColors.muted, height: 1.5),
            ),
            const SizedBox(height: 22),
            FilledButton.icon(
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重新扫描'),
            ),
          ],
        ),
      ),
    );
  }
}

String _friendly(Object error) => error
    .toString()
    .replaceFirst('FormatException: ', '')
    .replaceFirst('Bad state: ', '');
