import 'package:flutter/material.dart';

import '../services/storage_service.dart';
import '../widgets/formatters.dart';

/// 只管理可重建的挂载缓存。原图、备份及离线页均不在清理范围。
class LocalStorageScreen extends StatefulWidget {
  const LocalStorageScreen({required this.storage, super.key});
  final StorageService storage;

  @override
  State<LocalStorageScreen> createState() => _LocalStorageScreenState();
}

class _LocalStorageScreenState extends State<LocalStorageScreen> {
  late Future<LocalStorageUsage> _usage = widget.storage.localUsage();
  bool _clearing = false;

  void _refresh() => setState(() {
    _usage = widget.storage.localUsage();
  });

  Future<void> _clearMountCache() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('清理挂载压缩包缓存？'),
        content: const Text(
          '只删除为了读取而复制的压缩包缓存。原始文件、已导入漫画、备份和阅读进度不受影响。\n\n再次阅读时可能需要重新从原目录或网络下载，请确认原文件仍可访问。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清理缓存'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    setState(() => _clearing = true);
    try {
      await widget.storage.clearMountArchiveCache();
      if (!mounted) return;
      _refresh();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('挂载缓存已清理，原图与阅读记录未删除')));
    } catch (error) {
      if (!mounted) return;
      _refresh();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('清理未完成：$error')));
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  Future<void> _chooseMountCacheBudget(LocalStorageUsage usage) async {
    final current = usage.mountArchiveBudgetBytes;
    if (current == null || _clearing) return;
    final available = await widget.storage.freeBytes();
    if (!mounted) return;
    final selected = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('选择挂载缓存上限', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                '缓存可重新生成，原始文件与阅读记录不变。较大的压缩包需要较高上限；提高前请留足手机空间。'
                '${available == null ? '' : '\n当前可用空间 ${formatBytes(available)}'}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              for (final bytes in StorageService.mountArchiveCacheBudgets)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(formatBytes(bytes)),
                  selected: bytes == current,
                  trailing: bytes == current
                      ? const Icon(Icons.check_rounded)
                      : null,
                  onTap: () => Navigator.pop(context, bytes),
                ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || selected == null || selected == current) return;
    if (selected > current &&
        available != null &&
        selected > available + (usage.mountArchiveBytes ?? 0)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前可用空间不足以容纳该缓存上限，请先释放手机空间。')),
      );
      return;
    }
    if (selected < current) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: const Text('降低缓存上限？'),
          content: Text(
            '将上限改为 ${formatBytes(selected)}，并立即清理超出上限的旧缓存。'
            '原文件、已导入漫画和阅读记录保留；再次阅读时可能需要重新下载。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('降低并清理旧缓存'),
            ),
          ],
        ),
      );
      if (!mounted || accepted != true) return;
    }
    setState(() => _clearing = true);
    try {
      await widget.storage.setMountArchiveCacheBudget(selected);
      if (!mounted) return;
      _refresh();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('挂载缓存上限已设为 ${formatBytes(selected)}')),
      );
    } catch (error) {
      if (!mounted) return;
      _refresh();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('缓存上限未能完成调整：$error。已重新读取实际占用与上限。')),
      );
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('本地资料与空间'),
        actions: [
          IconButton(
            tooltip: '重新统计',
            onPressed: _clearing ? null : _refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: FutureBuilder<LocalStorageUsage>(
        future: _usage,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('暂时无法统计空间，请稍后重试。'),
                    TextButton(onPressed: _refresh, child: const Text('重新统计')),
                  ],
                ),
              ),
            );
          }
          final usage = snapshot.data;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              Container(
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.folder_copy_outlined,
                          size: 20,
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '资料留在本机',
                          style: TextStyle(
                            color: theme.colorScheme.onPrimaryContainer,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Text(
                      usage == null ? '正在统计' : formatBytes(usage.knownBytes),
                      style: theme.textTheme.headlineLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '已统计的文件空间 · 保留原画质\n不含安装包、数据库与系统缓存${usage != null && usage.mountArchiveBytes == null ? '\n挂载缓存暂不可用，未计入合计' : ''}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Text('文件各有归处', style: theme.textTheme.titleMedium),
              const SizedBox(height: 12),
              Card(
                margin: EdgeInsets.zero,
                child: Column(
                  children: [
                    _UsageRow(
                      icon: Icons.image_outlined,
                      title: '漫画原图',
                      detail: '保留原始文件；相同内容共用一份',
                      bytes: usage?.originalBytes,
                    ),
                    const Divider(height: 1, indent: 56),
                    _UsageRow(
                      icon: Icons.photo_size_select_small_rounded,
                      title: '缩略图',
                      detail: '只用于封面与预览，可在设置中重建',
                      bytes: usage?.thumbnailBytes,
                    ),
                    const Divider(height: 1, indent: 56),
                    _UsageRow(
                      icon: Icons.inventory_2_outlined,
                      title: '应用内备份',
                      detail: '卸载通常会删除；重要副本请另存到手机',
                      bytes: usage?.backupBytes,
                    ),
                    const Divider(height: 1, indent: 56),
                    _UsageRow(
                      icon: Icons.offline_pin_outlined,
                      title: '网络阅读缓存',
                      detail: '已下载的页面；在对应网络漫画中管理',
                      bytes: usage?.networkBytes,
                    ),
                    const Divider(height: 1, indent: 56),
                    _UsageRow(
                      icon: Icons.folder_zip_outlined,
                      title: '挂载压缩包缓存',
                      detail: '文档提供者无法直接读取时产生的副本',
                      bytes: usage?.mountArchiveBytes,
                      unavailable:
                          usage != null && usage.mountArchiveBytes == null,
                    ),
                    if (usage?.mountArchiveBudgetBytes != null)
                      ListTile(
                        title: const Text('挂载缓存上限'),
                        subtitle: Text(
                          '当前 ${formatBytes(usage!.mountArchiveBudgetBytes)}',
                        ),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: _clearing
                            ? null
                            : () => _chooseMountCacheBudget(usage),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed:
                              _clearing || (usage?.mountArchiveBytes ?? 0) == 0
                              ? null
                              : _clearMountCache,
                          icon: const Icon(
                            Icons.cleaning_services_outlined,
                            size: 18,
                          ),
                          label: Text(_clearing ? '正在清理…' : '仅清理挂载缓存'),
                        ),
                      ),
                    ),
                    const Divider(height: 1, indent: 56),
                    _UsageRow(
                      icon: Icons.hourglass_empty_rounded,
                      title: '导入与恢复临时文件',
                      detail: '任务结束自动清理，不压缩或替换原图',
                      bytes: usage?.temporaryBytes,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('升级保留 · 卸载前先备份', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 8),
                      const Text(
                        '同签名覆盖升级会保留本地书架。卸载前，请在设置中保存完整备份到手机的“下载”或“文档”等公共目录，并确认文件已保存。重新安装后再选择该文件恢复。',
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '没有自动云上传。书架、书签与进度只在本机保存。',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              ExpansionTile(
                tilePadding: const EdgeInsets.symmetric(horizontal: 4),
                title: const Text('查看应用内存储位置'),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: SelectableText(
                      '${widget.storage.root.path}\n\nassets：原图\nthumbnails：缩略图\nbackups：应用内备份\nnetwork-cache：阅读缓存\nbackup-temp：临时文件\n\n书架、顺序与进度另存于应用私有数据库。上述目录及数据库均属于应用数据，不能依赖卸载后保留。',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _UsageRow extends StatelessWidget {
  const _UsageRow({
    required this.icon,
    required this.title,
    required this.detail,
    required this.bytes,
    this.unavailable = false,
  });
  final IconData icon;
  final String title;
  final String detail;
  final int? bytes;
  final bool unavailable;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: Theme.of(context).colorScheme.primary, size: 22),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleSmall),
                  Text(
                    bytes == null
                        ? (unavailable ? '暂不可用' : '统计中')
                        : formatBytes(bytes!),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Text(detail, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ],
    ),
  );
}
