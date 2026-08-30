import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/entities.dart';
import '../services/archive_import_service.dart';
import '../state/app_controller.dart';
import 'formatters.dart';

enum _ImportSource { gallery, files, archives }

class NewArchiveImportResult {
  const NewArchiveImportResult(this.comic, this.report);

  final Comic comic;
  final ImportReport report;
}

Future<NewArchiveImportResult?> runNewArchiveImportFlow({
  required BuildContext context,
  required AppController controller,
  List<PlatformFile>? providedFiles,
}) async {
  final files = providedFiles ?? await controller.pickArchives();
  if (files.isEmpty || !context.mounted) return null;
  PreparedArchiveSelection? selection;
  try {
    selection = await controller.prepareArchives(files);
    if (!context.mounted) return null;
    final preparedSelection = selection;
    final freeBytes = await controller.freeBytes();
    if (!context.mounted) return null;
    final insufficient =
        freeBytes != null && preparedSelection.decodedBytes > freeBytes;
    var title = preparedSelection.suggestedTitle;
    final choice = await showDialog<_NewArchiveChoice>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(insufficient ? '设备空间不足' : '导入为新漫画'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (!insufficient)
              TextFormField(
                initialValue: title,
                onChanged: (value) => title = value,
                maxLength: 80,
                decoration: const InputDecoration(
                  labelText: '漫画名称',
                  counterText: '',
                ),
              ),
            const SizedBox(height: 12),
            Text(
              insufficient
                  ? '解压后约需 ${formatBytes(preparedSelection.decodedBytes)}，当前可用 ${formatBytes(freeBytes)}。'
                  : '${preparedSelection.archives.length} 个压缩包 · ${preparedSelection.totalPages} 张\n'
                        '将使用原包队列和页面顺序自动建立书架。',
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          if (!insufficient)
            TextButton(
              onPressed: () {
                final normalized = title.trim();
                if (normalized.isNotEmpty) {
                  Navigator.pop(
                    context,
                    _NewArchiveChoice(normalized, DuplicatePolicy.keep),
                  );
                }
              },
              child: const Text('保留重复'),
            ),
          if (!insufficient)
            FilledButton(
              onPressed: () {
                final normalized = title.trim();
                if (normalized.isNotEmpty) {
                  Navigator.pop(
                    context,
                    _NewArchiveChoice(normalized, DuplicatePolicy.skip),
                  );
                }
              },
              child: const Text('开始导入'),
            ),
        ],
      ),
    );
    if (choice == null || !context.mounted) return null;
    final comic = await controller.createComic(choice.title);
    if (!context.mounted) return null;
    final report = await _importPreparedSelection(
      context: context,
      controller: controller,
      comicId: comic.id,
      selection: preparedSelection,
      policy: choice.policy,
      setCoverFromFirstArchive: true,
    );
    return NewArchiveImportResult(comic, report);
  } catch (error) {
    if (context.mounted) await _showArchiveError(context, error);
    return null;
  } finally {
    await selection?.dispose();
  }
}

Future<ImportReport?> runImportFlow({
  required BuildContext context,
  required AppController controller,
  required String comicId,
  bool setCoverFromFirstArchive = false,
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
            ListTile(
              leading: const Icon(Icons.folder_zip_outlined),
              title: const Text('导入漫画压缩包'),
              subtitle: const Text('CBZ、ZIP、CBR、RAR、CB7、7z、CBT、TAR'),
              onTap: () => Navigator.pop(context, _ImportSource.archives),
            ),
          ],
        ),
      ),
    ),
  );
  if (source == null || !context.mounted) return null;
  if (source == _ImportSource.archives) {
    return _runArchiveImportFlow(
      context: context,
      controller: controller,
      comicId: comicId,
      setCoverFromFirstArchive: setCoverFromFirstArchive,
    );
  }
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

Future<ImportReport?> _runArchiveImportFlow({
  required BuildContext context,
  required AppController controller,
  required String comicId,
  required bool setCoverFromFirstArchive,
}) async {
  final files = await controller.pickArchives();
  if (files.isEmpty || !context.mounted) return null;

  PreparedArchiveSelection? selection;
  try {
    selection = await controller.prepareArchives(files);
    if (!context.mounted) return null;
    final preparedSelection = selection;
    final freeBytes = await controller.freeBytes();
    if (!context.mounted) return null;
    final insufficient =
        freeBytes != null && preparedSelection.decodedBytes > freeBytes;
    final queue = preparedSelection.archives
        .take(5)
        .map(
          (item) =>
              '${item.displayName} · ${item.pages.length} 张 · ${item.format.toUpperCase()}',
        )
        .join('\n');
    final extra = preparedSelection.archives.length > 5
        ? '\n还有 ${preparedSelection.archives.length - 5} 个压缩包'
        : '';
    final policy = await showDialog<DuplicatePolicy>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          insufficient
              ? '设备空间不足'
              : '确认导入 ${preparedSelection.archives.length} 个压缩包',
        ),
        content: Text(
          insufficient
              ? '解压后约需 ${formatBytes(preparedSelection.decodedBytes)}，当前可用 '
                    '${formatBytes(freeBytes)}。请先释放空间。'
              : '将按下列队列顺序连续追加：\n\n$queue$extra'
                    '\n\n共 ${preparedSelection.totalPages} 张，解压后约 '
                    '${formatBytes(preparedSelection.decodedBytes)}。'
                    '\n文件名使用数字自然排序，ComicInfo.xml 顺序优先。'
                    '\n\n当前漫画中出现内容完全相同的图片：',
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

    return _importPreparedSelection(
      context: context,
      controller: controller,
      comicId: comicId,
      selection: preparedSelection,
      policy: policy,
      setCoverFromFirstArchive: setCoverFromFirstArchive,
    );
  } catch (error) {
    if (context.mounted) await _showArchiveError(context, error);
    return null;
  } finally {
    await selection?.dispose();
  }
}

Future<ImportReport> _importPreparedSelection({
  required BuildContext context,
  required AppController controller,
  required String comicId,
  required PreparedArchiveSelection selection,
  required DuplicatePolicy policy,
  required bool setCoverFromFirstArchive,
}) async {
  var pending = selection;
  var imported = 0;
  var skipped = 0;
  while (true) {
    final report = await controller.importArchives(
      comicId: comicId,
      selection: pending,
      duplicatePolicy: policy,
      setCoverFromFirstArchive:
          setCoverFromFirstArchive && pending.archives.first.sourceIndex == 0,
    );
    imported += report.imported;
    skipped += report.skippedDuplicates;
    final aggregate = ImportReport(
      imported: imported,
      skippedDuplicates: skipped,
      failures: report.failures,
    );
    if (!context.mounted) return aggregate;
    final retry = await _showArchiveResult(context, aggregate);
    if (retry != true || report.failures.isEmpty) return aggregate;
    final failedSourceIndex = report.failures.first.sourceIndex;
    pending = PreparedArchiveSelection(
      selection.archives
          .where((item) => item.sourceIndex >= failedSourceIndex)
          .toList(growable: false),
    );
  }
}

Future<void> _showArchiveError(BuildContext context, Object error) =>
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('无法导入压缩包'),
        content: Text(error.toString().replaceFirst('FormatException: ', '')),
        actions: <Widget>[
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );

class _NewArchiveChoice {
  const _NewArchiveChoice(this.title, this.policy);

  final String title;
  final DuplicatePolicy policy;
}

Future<bool?> _showArchiveResult(BuildContext context, ImportReport report) {
  final failure = report.failures.firstOrNull;
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(failure == null ? '压缩包导入完成' : '已暂停后续压缩包'),
      content: Text(
        '成功 ${report.imported} 张'
        '${report.skippedDuplicates == 0 ? '' : '\n跳过重复 ${report.skippedDuplicates} 张'}'
        '${failure == null ? '' : '\n\n${failure.fileName}：${failure.reason}\n失败压缩包已自动回滚，不会打乱后续顺序。'}',
      ),
      actions: <Widget>[
        if (failure != null)
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('稍后处理'),
          ),
        if (failure != null)
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('重试该包'),
          )
        else
          FilledButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('知道了'),
          ),
      ],
    ),
  );
}
