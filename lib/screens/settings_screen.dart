import 'package:flutter/material.dart';

import '../models/entities.dart';
import '../state/app_controller.dart';
import '../theme.dart';
import '../widgets/formatters.dart';
import 'network_sources_screen.dart';
import 'trash_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({required this.controller, super.key});

  final AppController controller;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late Future<LibraryStats> _stats = widget.controller.loadStats();

  void _refreshStats() =>
      setState(() => _stats = widget.controller.loadStats());

  @override
  Widget build(BuildContext context) {
    final preferences = widget.controller.preferences;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: <Widget>[
          const _SectionLabel('阅读'),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: <Widget>[
                const ListTile(
                  title: Text('阅读画布'),
                  subtitle: Text('默认使用白蓝画纸；夜间模式仅改变阅读页'),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                  child: SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<ReaderSurfaceMode>(
                      key: const ValueKey<String>('reader-surface-setting'),
                      showSelectedIcon: false,
                      segments: const <ButtonSegment<ReaderSurfaceMode>>[
                        ButtonSegment(
                          value: ReaderSurfaceMode.paper,
                          icon: Icon(Icons.light_mode_outlined),
                          label: Text('画纸'),
                        ),
                        ButtonSegment(
                          value: ReaderSurfaceMode.night,
                          icon: Icon(Icons.dark_mode_outlined),
                          label: Text('夜间'),
                        ),
                      ],
                      selected: <ReaderSurfaceMode>{preferences.surfaceMode},
                      onSelectionChanged: (selection) async {
                        await widget.controller.updatePreferences(
                          preferences.copyWith(surfaceMode: selection.first),
                        );
                        if (mounted) setState(() {});
                      },
                    ),
                  ),
                ),
                const Divider(height: 1, indent: 16),
                ListTile(
                  title: const Text('图片间距'),
                  subtitle: const Text('调整连续阅读时图片之间的留白'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text('${preferences.imageGap.round()} dp'),
                      const SizedBox(width: 4),
                      const Icon(Icons.chevron_right_rounded),
                    ],
                  ),
                  onTap: () => _chooseImageGap(preferences),
                ),
                const Divider(height: 1, indent: 16),
                SwitchListTile(
                  title: const Text('显示阅读页码'),
                  value: preferences.showPageNumber,
                  onChanged: (value) => widget.controller.updatePreferences(
                    preferences.copyWith(showPageNumber: value),
                  ),
                ),
                const Divider(height: 1, indent: 16),
                SwitchListTile(
                  title: const Text('记住阅读位置'),
                  subtitle: const Text('再次打开时回到上次位置'),
                  value: preferences.rememberProgress,
                  onChanged: (value) => widget.controller.updatePreferences(
                    preferences.copyWith(rememberProgress: value),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const _SectionLabel('外观'),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: SegmentedButton<AppThemePreference>(
                segments: const <ButtonSegment<AppThemePreference>>[
                  ButtonSegment(
                    value: AppThemePreference.system,
                    icon: Icon(Icons.brightness_auto_outlined),
                    label: Text('系统'),
                  ),
                  ButtonSegment(
                    value: AppThemePreference.light,
                    icon: Icon(Icons.light_mode_outlined),
                    label: Text('浅色'),
                  ),
                  ButtonSegment(
                    value: AppThemePreference.dark,
                    icon: Icon(Icons.dark_mode_outlined),
                    label: Text('深色'),
                  ),
                ],
                selected: <AppThemePreference>{preferences.theme},
                onSelectionChanged: (selection) =>
                    widget.controller.updatePreferences(
                      preferences.copyWith(theme: selection.first),
                    ),
              ),
            ),
          ),
          const SizedBox(height: 24),
          const _SectionLabel('挂载与网络书库'),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: <Widget>[
                ListTile(
                  leading: const Icon(Icons.cloud_outlined),
                  title: const Text('挂载与网络书库'),
                  subtitle: Text(
                    controllerLabel(widget.controller.networkSources.length),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          NetworkSourcesScreen(controller: widget.controller),
                    ),
                  ),
                ),
                const Divider(height: 1, indent: 56),
                FutureBuilder<int>(
                  future: widget.controller.networkCacheBytes(),
                  builder: (context, snapshot) => ListTile(
                    leading: const Icon(Icons.offline_pin_outlined),
                    title: const Text('网络阅读缓存'),
                    subtitle: const Text('清缓存不会清除本地阅读记录'),
                    trailing: Text(
                      snapshot.hasData ? formatBytes(snapshot.data!) : '计算中',
                      style: const TextStyle(color: ShelfColors.muted),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const _SectionLabel('存储'),
          FutureBuilder<LibraryStats>(
            future: _stats,
            builder: (context, snapshot) {
              final stats = snapshot.data;
              return Card(
                margin: EdgeInsets.zero,
                child: Column(
                  children: <Widget>[
                    _StorageRow(
                      color: ShelfColors.blue,
                      title: '私有原图',
                      value: stats == null
                          ? '计算中'
                          : formatBytes(stats.originalBytes),
                    ),
                    const Divider(height: 1, indent: 54),
                    _StorageRow(
                      color: const Color(0xFF91A4B7),
                      title: '缩略图缓存',
                      value: stats == null
                          ? '计算中'
                          : formatBytes(stats.thumbnailBytes),
                    ),
                    const Divider(height: 1, indent: 54),
                    _StorageRow(
                      color: const Color(0xFFD49A63),
                      title: '待清理原图',
                      value: stats == null
                          ? '计算中'
                          : '${stats.orphanCount} 个 · ${formatBytes(stats.orphanBytes)}',
                    ),
                    const Divider(height: 1, indent: 16),
                    ListTile(
                      leading: const Icon(Icons.delete_outline_rounded),
                      title: const Text('回收站'),
                      subtitle: const Text('恢复或永久删除漫画'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => Navigator.of(context)
                          .push(
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  TrashScreen(controller: widget.controller),
                            ),
                          )
                          .then((_) {
                            _refreshStats();
                            widget.controller.refresh();
                          }),
                    ),
                    ListTile(
                      leading: const Icon(Icons.cleaning_services_outlined),
                      title: const Text('清理缩略图缓存'),
                      subtitle: const Text('原图不受影响，可随时重建'),
                      onTap: _clearThumbnails,
                    ),
                    ListTile(
                      leading: const Icon(Icons.auto_awesome_mosaic_outlined),
                      title: const Text('重建缩略图'),
                      onTap: _rebuildThumbnails,
                    ),
                    ListTile(
                      leading: const Icon(Icons.delete_sweep_outlined),
                      title: const Text('彻底清理无引用原图'),
                      subtitle: const Text('仅处理不再被任何漫画引用的文件'),
                      enabled: (stats?.orphanCount ?? 0) > 0,
                      onTap: _deleteOrphans,
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 24),
          const _SectionLabel('备份与恢复'),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: <Widget>[
                ListTile(
                  leading: const Icon(Icons.archive_outlined),
                  title: const Text('保存完整备份到手机/云盘'),
                  subtitle: const Text('包含漫画、分组、书单、书签、进度与原图；卸载后仍可找回'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: _createBackup,
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.settings_backup_restore_rounded),
                  title: const Text('从备份恢复'),
                  subtitle: const Text('恢复前自动保留当前书架安全备份'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: _restore,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const _SectionLabel('隐私'),
          const Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: Icon(Icons.lock_outline_rounded),
              title: Text('完全本地'),
              subtitle: Text('不建立 App 账号，没有社交、广告或云同步。网络书库始终只读，阅读记录只留在本机。'),
            ),
          ),
          const SizedBox(height: 24),
          const Center(
            child: Text(
              '拾画阁 1.5.0',
              style: TextStyle(color: ShelfColors.muted, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _chooseImageGap(ReaderPreferences initial) async {
    var value = initial.imageGap.round().clamp(0, 10);
    final selected = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('图片间距', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 6),
                const Text(
                  '只改变阅读显示，不处理或重编码原图。',
                  style: TextStyle(color: ShelfColors.muted),
                ),
                const SizedBox(height: 18),
                SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: const <ButtonSegment<int>>[
                    ButtonSegment(value: 0, label: Text('无缝 0')),
                    ButtonSegment(value: 4, label: Text('窄缝 4')),
                    ButtonSegment(value: 10, label: Text('舒适 10')),
                  ],
                  selected: <int>{
                    value <= 2
                        ? 0
                        : value >= 7
                        ? 10
                        : 4,
                  },
                  onSelectionChanged: (selection) =>
                      setSheetState(() => value = selection.first),
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    IconButton.filledTonal(
                      tooltip: '减小间距',
                      onPressed: value <= 0
                          ? null
                          : () => setSheetState(() => value--),
                      icon: const Icon(Icons.remove_rounded),
                    ),
                    SizedBox(
                      width: 92,
                      child: Text(
                        '$value dp',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    IconButton.filledTonal(
                      tooltip: '增大间距',
                      onPressed: value >= 10
                          ? null
                          : () => setSheetState(() => value++),
                      icon: const Icon(Icons.add_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context, value),
                    child: const Text('保存'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    await widget.controller.updatePreferences(
      initial.copyWith(imageGap: selected.toDouble()),
    );
  }

  Future<void> _clearThumbnails() async {
    await widget.controller.clearThumbnails();
    _refreshStats();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('缩略图缓存已清理，原图未删除')));
    }
  }

  Future<void> _rebuildThumbnails() async {
    await widget.controller.rebuildThumbnails();
    _refreshStats();
  }

  Future<void> _deleteOrphans() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('彻底删除待清理原图？'),
        content: const Text('这些文件已不被任何漫画引用。删除后只能通过此前创建的备份恢复。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('彻底删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final count = await widget.controller.deleteOrphanedAssets();
    _refreshStats();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已彻底删除 $count 个无引用原图')));
    }
  }

  Future<void> _createBackup() async {
    try {
      final result = await widget.controller.createAndExportBackup();
      final file = result.$1;
      final destination = result.$2;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              destination == null
                  ? '已取消另存；应用内安全副本仍在：${file.path.split(RegExp(r'[/\\]')).last}'
                  : '完整备份已保存到你选择的手机或云盘位置',
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('备份失败：$error')));
      }
    }
  }

  Future<void> _restore() async {
    final source = await widget.controller.pickBackup();
    if (source == null || !mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复这个备份？'),
        content: Text('当前书架结构会被备份内容替换。恢复前会自动创建一份安全备份。\n\n${source.name}'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('开始恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final safety = await widget.controller.restoreBackup(source);
      _refreshStats();
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('恢复完成'),
            content: Text('书架已恢复。恢复前安全备份保存在：\n${safety.path}'),
            actions: <Widget>[
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('知道了'),
              ),
            ],
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('恢复失败，当前书架未替换：$error')));
      }
    }
  }
}

String controllerLabel(int count) =>
    count == 0 ? 'WebDAV、OPDS 与 SMB/NAS' : '已挂载 $count 个远程书库';

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 9),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: ShelfColors.muted,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _StorageRow extends StatelessWidget {
  const _StorageRow({
    required this.color,
    required this.title,
    required this.value,
  });
  final Color color;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      title: Text(title),
      trailing: Text(value, style: const TextStyle(color: ShelfColors.muted)),
    );
  }
}
