import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/entities.dart';
import '../state/app_controller.dart';
import 'formatters.dart';

enum _ImportSource { gallery, files }

Future<ImportReport?> runImportFlow({
  required BuildContext context,
  required AppController controller,
  required String comicId,
}) async {
  final source = await showModalBottomSheet<_ImportSource>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择'),
              subtitle: const Text('复制原始文件到 App 私有存储'),
              onTap: () => Navigator.pop(context, _ImportSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('从文件选择'),
              subtitle: const Text('支持 JPG、PNG、WebP、GIF、HEIC 等'),
              onTap: () => Navigator.pop(context, _ImportSource.files),
            ),
          ],
        ),
      ),
    ),
  );
  if (source == null || !context.mounted) return null;
  final files = await controller.pickImages(
    fromGallery: source == _ImportSource.gallery,
  );
  if (files.isEmpty || !context.mounted) return null;
  final estimatedBytes = await controller.estimateBytes(files);
  final freeBytes = await controller.freeBytes();
  if (!context.mounted) return null;
  final insufficient = freeBytes != null && estimatedBytes > freeBytes;
  final policy = await showDialog<DuplicatePolicy>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(insufficient ? '设备空间不足' : '确认导入 ${files.length} 张图片'),
      content: Text(
        insufficient
            ? '预计需要 ${formatBytes(estimatedBytes)}，当前可用 '
                '${formatBytes(freeBytes)}。请先释放空间。'
            : '预计复制 ${formatBytes(estimatedBytes)} 到 App 私有目录。'
                '${freeBytes == null ? '' : '\n设备可用 ${formatBytes(freeBytes)}。'}'
                '\n\n如果当前漫画中出现内容完全相同的图片：',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        if (!insufficient) ...<Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, DuplicatePolicy.keep),
            child: const Text('仍然导入'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, DuplicatePolicy.skip),
            child: const Text('跳过重复'),
          ),
        ],
      ],
    ),
  );
  if (policy == null || !context.mounted) return null;
  var pending = files;
  var imported = 0;
  var skipped = 0;
  while (true) {
    final report = await controller.importFiles(
      comicId: comicId,
      files: pending,
      duplicatePolicy: policy,
    );
    imported += report.imported;
    skipped += report.skippedDuplicates;
    final aggregate = ImportReport(
      imported: imported,
      skippedDuplicates: skipped,
      failures: report.failures,
    );
    if (!context.mounted) return aggregate;
    final failureDetails = report.failures
        .take(4)
        .map((failure) => '${failure.fileName}：${failure.reason}')
        .join('\n');
    final retry = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(report.failures.isEmpty ? '导入完成' : '部分图片导入失败'),
        content: Text(
          '成功 $imported 张'
          '${skipped == 0 ? '' : '\n跳过重复 $skipped 张'}'
          '${report.failures.isEmpty ? '' : '\n失败 ${report.failures.length} 张\n\n$failureDetails'}',
        ),
        actions: <Widget>[
          if (report.failures.isNotEmpty)
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('稍后处理'),
            ),
          if (report.failures.isNotEmpty)
            FilledButton.icon(
              onPressed: () => Navigator.pop(context, true),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重试失败项'),
            )
          else
            FilledButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('知道了'),
            ),
        ],
      ),
    );
    if (retry != true) return aggregate;
    pending = <PlatformFile>[
      for (final failure in report.failures) pending[failure.sourceIndex],
    ];
  }
}
