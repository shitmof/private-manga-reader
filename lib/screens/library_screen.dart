import 'package:flutter/material.dart';

import '../models/entities.dart';
import '../state/app_controller.dart';
import '../theme.dart';
import '../widgets/formatters.dart';
import '../widgets/import_flow.dart';
import '../widgets/private_image.dart';
import 'comic_detail_screen.dart';
import 'editor_screen.dart';
import 'network_sources_screen.dart';
import 'settings_screen.dart';

enum _NewComicSource { archives, images, folder }

enum _LibraryScope { all, pinned, private }

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({required this.controller, super.key});

  final AppController controller;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen>
    with WidgetsBindingObserver {
  _LibraryScope _scope = _LibraryScope.all;
  String? _folderId;
  String? _readingListId;
  Set<String> _readingListComicIds = const <String>{};
  bool _privateUnlocked = false;
  bool _selectionMode = false;
  bool _handlingIncomingArchives = false;
  final Set<String> _selectedIds = <String>{};

  AppController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      setState(() {
        _privateUnlocked = false;
        if (_activeFolder?.isPrivate ?? false) _folderId = null;
        if (_scope == _LibraryScope.private) _scope = _LibraryScope.all;
      });
    }
  }

  List<ComicSummary> get _visibleComics => controller.library.where((summary) {
    final comic = summary.comic;
    final inPrivateFolder = controller.folders.any(
      (folder) => folder.isPrivate && folder.id == comic.folderId,
    );
    if (_readingListId != null) {
      return _readingListComicIds.contains(comic.id) &&
          (!(comic.isPrivate || inPrivateFolder) || _privateUnlocked);
    }
    if (_folderId != null) return comic.folderId == _folderId;
    return switch (_scope) {
      _LibraryScope.all => comic.folderId == null && !comic.isPrivate,
      _LibraryScope.pinned =>
        comic.isPinned && !comic.isPrivate && !inPrivateFolder,
      _LibraryScope.private =>
        comic.isPrivate && comic.folderId == null && _privateUnlocked,
    };
  }).toList();

  ShelfFolder? get _activeFolder {
    for (final folder in controller.folders) {
      if (folder.id == _folderId) return folder;
    }
    return null;
  }

  ReadingList? get _activeReadingList {
    for (final list in controller.readingLists) {
      if (list.id == _readingListId) return list;
    }
    return null;
  }

  bool get _hasInternalBackTarget =>
      _selectionMode ||
      _folderId != null ||
      _readingListId != null ||
      _scope != _LibraryScope.all;

  void _handleBack() {
    if (_selectionMode) {
      setState(() {
        _selectionMode = false;
        _selectedIds.clear();
      });
      return;
    }
    setState(() {
      _folderId = null;
      _readingListId = null;
      _readingListComicIds = const <String>{};
      _scope = _LibraryScope.all;
      _privateUnlocked = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        if (controller.hasIncomingArchives && !_handlingIncomingArchives) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _consumeIncomingArchives(),
          );
        }
        final comics = _visibleComics;
        final visibleFolders = _folderId != null || _readingListId != null
            ? const <ShelfFolder>[]
            : switch (_scope) {
                _LibraryScope.all =>
                  controller.folders
                      .where((folder) => !folder.isPrivate)
                      .toList(),
                _LibraryScope.private when _privateUnlocked =>
                  controller.folders
                      .where((folder) => folder.isPrivate)
                      .toList(),
                _ => const <ShelfFolder>[],
              };
        return PopScope<void>(
          canPop: !_hasInternalBackTarget,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _handleBack();
          },
          child: Scaffold(
            appBar: AppBar(
              leading: _folderId == null && _readingListId == null
                  ? null
                  : IconButton(
                      tooltip: '返回书架',
                      onPressed: _handleBack,
                      icon: const Icon(Icons.arrow_back_ios_new_rounded),
                    ),
              title: _selectionMode
                  ? Text('已选 ${_selectedIds.length} 本')
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          _activeFolder?.name ??
                              _activeReadingList?.name ??
                              '拾画阁',
                        ),
                        const Text(
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
              actions: _selectionMode
                  ? <Widget>[
                      TextButton(
                        onPressed: () => setState(() {
                          _selectionMode = false;
                          _selectedIds.clear();
                        }),
                        child: const Text('取消'),
                      ),
                    ]
                  : <Widget>[
                      IconButton(
                        tooltip: '搜索',
                        onPressed: () => showSearch<void>(
                          context: context,
                          delegate: _ComicSearchDelegate(
                            controller: controller,
                            includePrivate: _privateUnlocked,
                          ),
                        ),
                        icon: const Icon(Icons.search_rounded),
                      ),
                      IconButton(
                        tooltip: '批量管理',
                        onPressed: comics.isEmpty
                            ? null
                            : () => setState(() => _selectionMode = true),
                        icon: const Icon(Icons.checklist_rounded),
                      ),
                      PopupMenuButton<String>(
                        tooltip: '更多',
                        onSelected: (value) {
                          if (value == 'network') {
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => NetworkSourcesScreen(
                                  controller: controller,
                                ),
                              ),
                            );
                          } else {
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) =>
                                    SettingsScreen(controller: controller),
                              ),
                            );
                          }
                        },
                        itemBuilder: (_) => const <PopupMenuEntry<String>>[
                          PopupMenuItem(
                            value: 'network',
                            child: ListTile(
                              leading: Icon(Icons.cloud_outlined),
                              title: Text('网络书库'),
                            ),
                          ),
                          PopupMenuItem(
                            value: 'settings',
                            child: ListTile(
                              leading: Icon(Icons.tune_rounded),
                              title: Text('设置'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 4),
                    ],
            ),
            body: Column(
              children: <Widget>[
                if (_folderId == null && _readingListId == null)
                  _buildScopeBar(),
                Expanded(
                  child: _isCompletelyEmpty
                      ? _EmptyLibrary(onCreate: () => _createComic(context))
                      : comics.isEmpty && visibleFolders.isEmpty
                      ? _EmptySection(scope: _scope)
                      : _LibraryGrid(
                          controller: controller,
                          comics: comics,
                          folders: visibleFolders,
                          selectedIds: _selectedIds,
                          selectionMode: _selectionMode,
                          onComicTap: _openComic,
                          onComicToggle: _toggleComic,
                          onMoveComicToFolder: (comicId, folderId) => controller
                              .moveComicsToFolder(<String>[comicId], folderId),
                          onFolderTap: (folder) =>
                              setState(() => _folderId = folder.id),
                          onFolderMenu: _showFolderMenu,
                        ),
                ),
              ],
            ),
            bottomNavigationBar: _selectionMode
                ? _BatchActionBar(
                    hasSelection: _selectedIds.isNotEmpty,
                    onFolder: _moveSelectionToFolder,
                    onPrivate: () => _setSelectionPrivate(true),
                    onPin: () => _setSelectionPinned(true),
                    onReadingList: _addSelectionToReadingList,
                    onDelete: _deleteSelection,
                  )
                : null,
            floatingActionButton: _selectionMode
                ? null
                : FloatingActionButton(
                    onPressed: () => _createComic(context),
                    tooltip: '新建漫画或文件夹',
                    child: const Icon(Icons.add_rounded),
                  ),
          ),
        );
      },
    );
  }

  bool get _isCompletelyEmpty =>
      controller.library.isEmpty && controller.folders.isEmpty;

  Widget _buildScopeBar() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
      child: Row(
        children: <Widget>[
          SegmentedButton<_LibraryScope>(
            showSelectedIcon: false,
            segments: const <ButtonSegment<_LibraryScope>>[
              ButtonSegment(value: _LibraryScope.all, label: Text('书架')),
              ButtonSegment(value: _LibraryScope.pinned, label: Text('置顶')),
              ButtonSegment(
                value: _LibraryScope.private,
                label: Text('私密'),
                icon: Icon(Icons.lock_outline_rounded, size: 17),
              ),
            ],
            selected: <_LibraryScope>{_scope},
            onSelectionChanged: (value) async {
              final next = value.first;
              if (next == _LibraryScope.private && !_privateUnlocked) {
                if (!await controller.unlockPrivateShelf() || !mounted) return;
                _privateUnlocked = true;
              }
              setState(() {
                _readingListId = null;
                _readingListComicIds = const <String>{};
                _scope = next;
              });
            },
          ),
          const SizedBox(width: 8),
          ActionChip(
            avatar: const Icon(Icons.bookmarks_outlined, size: 17),
            label: const Text('书单'),
            onPressed: _chooseReadingList,
          ),
        ],
      ),
    );
  }

  Future<void> _chooseReadingList() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const ListTile(
              leading: Icon(Icons.bookmarks_outlined),
              title: Text('本地书单'),
              subtitle: Text('一本漫画可同时加入多个书单'),
            ),
            ...controller.readingLists.map(
              (list) => ListTile(
                leading: const Icon(Icons.bookmark_border_rounded),
                title: Text(list.name),
                trailing: IconButton(
                  tooltip: '删除书单',
                  onPressed: () =>
                      Navigator.pop(context, '__delete__${list.id}'),
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
                onTap: () => Navigator.pop(context, list.id),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.add_rounded),
              title: const Text('新建书单'),
              onTap: () => Navigator.pop(context, '__new__'),
            ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    if (selected == '__new__') {
      final name = await _askName('新建书单');
      if (name == null) return;
      final list = await controller.createReadingList(name);
      await _openReadingList(list.id);
      return;
    }
    if (selected.startsWith('__delete__')) {
      final id = selected.substring('__delete__'.length);
      await controller.deleteReadingList(id);
      if (_readingListId == id && mounted) {
        setState(() {
          _readingListId = null;
          _readingListComicIds = const <String>{};
        });
      }
      return;
    }
    await _openReadingList(selected);
  }

  Future<void> _openReadingList(String listId) async {
    final comicIds = await controller.loadReadingListComicIds(listId);
    if (!mounted) return;
    setState(() {
      _folderId = null;
      _readingListId = listId;
      _readingListComicIds = comicIds.toSet();
    });
  }

  void _openComic(ComicSummary summary) {
    if (_selectionMode) {
      _toggleComic(summary.comic.id);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ComicDetailScreen(
          controller: controller,
          comicId: summary.comic.id,
        ),
      ),
    );
  }

  void _toggleComic(String id) => setState(() {
    if (!_selectedIds.add(id)) _selectedIds.remove(id);
  });

  Future<void> _showFolderMenu(ShelfFolder folder) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline_rounded),
              title: const Text('重命名'),
              onTap: () => Navigator.pop(context, 'rename'),
            ),
            ListTile(
              leading: Icon(
                folder.isPrivate
                    ? Icons.lock_open_outlined
                    : Icons.lock_outline_rounded,
              ),
              title: Text(folder.isPrivate ? '取消私密' : '设为私密文件夹'),
              onTap: () => Navigator.pop(context, 'privacy'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded),
              title: const Text('删除文件夹（保留漫画）'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == 'rename' && mounted) {
      final name = await _askName('重命名文件夹', initial: folder.name);
      if (name != null) await controller.renameFolder(folder.id, name);
    } else if (action == 'privacy') {
      await controller.setFolderPrivate(folder.id, !folder.isPrivate);
    } else if (action == 'delete') {
      await controller.deleteFolder(folder.id);
    }
  }

  Future<String?> _askName(String title, {String initial = ''}) async {
    final textController = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: textController,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(hintText: '输入名称'),
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
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Future<void> _moveSelectionToFolder() async {
    final folderId = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.home_outlined),
              title: const Text('移到书架根目录'),
              onTap: () => Navigator.pop(context, '__root__'),
            ),
            ...controller.folders.map(
              (folder) => ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(folder.name),
                onTap: () => Navigator.pop(context, folder.id),
              ),
            ),
          ],
        ),
      ),
    );
    if (folderId == null) return;
    await controller.moveComicsToFolder(
      _selectedIds,
      folderId == '__root__' ? null : folderId,
    );
    _finishSelection();
  }

  Future<void> _setSelectionPrivate(bool value) async {
    await controller.setComicsPrivate(_selectedIds, value);
    _finishSelection();
  }

  Future<void> _setSelectionPinned(bool value) async {
    await controller.setComicsPinned(_selectedIds, value);
    _finishSelection();
  }

  Future<void> _addSelectionToReadingList() async {
    final result = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.add_rounded),
              title: const Text('新建书单'),
              onTap: () => Navigator.pop(context, '__new__'),
            ),
            ...controller.readingLists.map(
              (list) => ListTile(
                leading: const Icon(Icons.bookmarks_outlined),
                title: Text(list.name),
                onTap: () => Navigator.pop(context, list.id),
              ),
            ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    var listId = result;
    if (result == '__new__') {
      final name = await _askName('新建书单');
      if (name == null) return;
      listId = (await controller.createReadingList(name)).id;
    }
    await controller.addComicsToReadingList(listId, _selectedIds);
    _finishSelection();
  }

  Future<void> _deleteSelection() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移到回收站？'),
        content: Text('将 ${_selectedIds.length} 本漫画移到回收站，可稍后恢复。'),
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
    if (confirmed != true) return;
    for (final id in _selectedIds.toList()) {
      await controller.deleteComic(id);
    }
    _finishSelection();
  }

  void _finishSelection() {
    if (!mounted) return;
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
  }

  Future<void> _createComic(BuildContext context) async {
    final source = await showModalBottomSheet<_NewComicSource>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.folder_zip_outlined),
                title: const Text('导入漫画压缩包'),
                subtitle: const Text('自动识别名称、封面与原顺序'),
                onTap: () => Navigator.pop(context, _NewComicSource.archives),
              ),
              ListTile(
                leading: const Icon(Icons.add_photo_alternate_outlined),
                title: const Text('新建图片漫画'),
                subtitle: const Text('从相册或文件多选原图'),
                onTap: () => Navigator.pop(context, _NewComicSource.images),
              ),
              ListTile(
                leading: const Icon(Icons.create_new_folder_outlined),
                title: const Text('新建文件夹'),
                subtitle: const Text('将多本漫画收纳在一起'),
                onTap: () => Navigator.pop(context, _NewComicSource.folder),
              ),
            ],
          ),
        ),
      ),
    );
    if (source == null || !context.mounted) return;
    if (source == _NewComicSource.folder) {
      final name = await _askName('新建文件夹');
      if (name != null) await controller.createFolder(name);
      return;
    }
    if (source == _NewComicSource.archives) {
      final result = await runNewArchiveImportFlow(
        context: context,
        controller: controller,
      );
      if (result == null || !context.mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => result.report.imported > 0
              ? EditorScreen(controller: controller, comicId: result.comic.id)
              : ComicDetailScreen(
                  controller: controller,
                  comicId: result.comic.id,
                ),
        ),
      );
      return;
    }
    final title = await _askName('新建漫画');
    if (title == null || !context.mounted) return;
    final comic = await controller.createComic(title);
    if (!context.mounted) return;
    final report = await runImportFlow(
      context: context,
      controller: controller,
      comicId: comic.id,
      setCoverFromFirstArchive: true,
    );
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => report != null && report.imported > 0
            ? EditorScreen(controller: controller, comicId: comic.id)
            : ComicDetailScreen(controller: controller, comicId: comic.id),
      ),
    );
  }

  Future<void> _consumeIncomingArchives() async {
    if (_handlingIncomingArchives || !mounted) return;
    final files = controller.takeIncomingArchives();
    if (files.isEmpty) return;
    _handlingIncomingArchives = true;
    try {
      final result = await runNewArchiveImportFlow(
        context: context,
        controller: controller,
        providedFiles: files,
      );
      if (result == null || !mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              EditorScreen(controller: controller, comicId: result.comic.id),
        ),
      );
    } finally {
      _handlingIncomingArchives = false;
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
            Text('这里还没有漫画', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 10),
            const Text(
              '导入后会保留应用内副本；完整备份可另存到手机或云盘。',
              textAlign: TextAlign.center,
              style: TextStyle(color: ShelfColors.muted, height: 1.55),
            ),
            const SizedBox(height: 26),
            FilledButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: const Text('开始建立书架'),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptySection extends StatelessWidget {
  const _EmptySection({required this.scope});

  final _LibraryScope scope;

  @override
  Widget build(BuildContext context) {
    final text = switch (scope) {
      _LibraryScope.pinned => '还没有置顶的漫画',
      _LibraryScope.private => '私密书架还是空的',
      _LibraryScope.all => '这个文件夹还是空的',
    };
    return Center(
      child: Text(text, style: const TextStyle(color: ShelfColors.muted)),
    );
  }
}

class _LibraryGrid extends StatelessWidget {
  const _LibraryGrid({
    required this.controller,
    required this.comics,
    required this.folders,
    required this.selectedIds,
    required this.selectionMode,
    required this.onComicTap,
    required this.onComicToggle,
    required this.onMoveComicToFolder,
    required this.onFolderTap,
    required this.onFolderMenu,
  });

  final AppController controller;
  final List<ComicSummary> comics;
  final List<ShelfFolder> folders;
  final Set<String> selectedIds;
  final bool selectionMode;
  final ValueChanged<ComicSummary> onComicTap;
  final ValueChanged<String> onComicToggle;
  final void Function(String comicId, String folderId) onMoveComicToFolder;
  final ValueChanged<ShelfFolder> onFolderTap;
  final ValueChanged<ShelfFolder> onFolderMenu;

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      interactive: true,
      thickness: 5,
      radius: const Radius.circular(3),
      child: GridView.builder(
        key: const ValueKey<String>('library-three-column-grid'),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 104),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 9,
          mainAxisSpacing: 18,
          childAspectRatio: 0.57,
        ),
        itemCount: folders.length + comics.length,
        itemBuilder: (context, index) {
          if (index < folders.length) {
            final folder = folders[index];
            final contents = controller.library
                .where((summary) => summary.comic.folderId == folder.id)
                .toList();
            return DragTarget<String>(
              onWillAcceptWithDetails: (_) => true,
              onAcceptWithDetails: (details) =>
                  onMoveComicToFolder(details.data, folder.id),
              builder: (context, candidates, _) => AnimatedScale(
                scale: candidates.isEmpty ? 1 : 0.94,
                duration: const Duration(milliseconds: 140),
                child: _FolderCard(
                  controller: controller,
                  folder: folder,
                  contents: contents,
                  onTap: () => onFolderTap(folder),
                  onMenu: () => onFolderMenu(folder),
                ),
              ),
            );
          }
          final summary = comics[index - folders.length];
          final selected = selectedIds.contains(summary.comic.id);
          final card = _ComicCard(
            controller: controller,
            summary: summary,
            selected: selected,
            selectionMode: selectionMode,
            onTap: () => onComicTap(summary),
            onToggle: () => onComicToggle(summary.comic.id),
          );
          if (selectionMode) return card;
          return LongPressDraggable<String>(
            data: summary.comic.id,
            feedback: SizedBox(
              width: 112,
              height: 196,
              child: Material(
                elevation: 8,
                borderRadius: BorderRadius.circular(14),
                color: Theme.of(context).colorScheme.surface,
                child: card,
              ),
            ),
            childWhenDragging: Opacity(opacity: 0.25, child: card),
            child: card,
          );
        },
      ),
    );
  }
}

class _FolderCard extends StatelessWidget {
  const _FolderCard({
    required this.controller,
    required this.folder,
    required this.contents,
    required this.onTap,
    required this.onMenu,
  });

  final AppController controller;
  final ShelfFolder folder;
  final List<ComicSummary> contents;
  final VoidCallback onTap;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final previews = contents.take(4).toList();
    return InkWell(
      onTap: onTap,
      onLongPress: onMenu,
      borderRadius: BorderRadius.circular(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: ShelfColors.blueSoft,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: ShelfColors.line),
              ),
              child: previews.isEmpty
                  ? const Center(
                      child: Icon(
                        Icons.folder_outlined,
                        size: 34,
                        color: ShelfColors.blue,
                      ),
                    )
                  : GridView.builder(
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            crossAxisSpacing: 3,
                            mainAxisSpacing: 3,
                          ),
                      itemCount: previews.length,
                      itemBuilder: (_, index) {
                        final preview = previews[index];
                        return ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: preview.coverStoredPath == null
                              ? const ColoredBox(color: Colors.white)
                              : PrivateImage(
                                  controller: controller,
                                  originalPath: preview.coverStoredPath!,
                                  thumbnailPath: preview.coverThumbnailPath,
                                  cacheWidth: 160,
                                ),
                        );
                      },
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  folder.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              if (folder.isPrivate)
                const Padding(
                  padding: EdgeInsets.only(right: 3),
                  child: Icon(Icons.lock_rounded, size: 14),
                ),
              InkWell(
                onTap: onMenu,
                child: const Icon(Icons.more_horiz_rounded, size: 18),
              ),
            ],
          ),
          Text(
            '${contents.length} 本',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: ShelfColors.muted),
          ),
        ],
      ),
    );
  }
}

class _ComicCard extends StatelessWidget {
  const _ComicCard({
    required this.controller,
    required this.summary,
    required this.selected,
    required this.selectionMode,
    required this.onTap,
    required this.onToggle,
  });

  final AppController controller;
  final ComicSummary summary;
  final bool selected;
  final bool selectionMode;
  final VoidCallback onTap;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final comic = summary.comic;
    return InkWell(
      onTap: selectionMode ? onToggle : onTap,
      borderRadius: BorderRadius.circular(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: summary.coverStoredPath == null
                      ? Container(
                          color: ShelfColors.blueSoft,
                          child: const Icon(
                            Icons.image_outlined,
                            color: ShelfColors.blue,
                          ),
                        )
                      : PrivateImage(
                          controller: controller,
                          originalPath: summary.coverStoredPath!,
                          thumbnailPath: summary.coverThumbnailPath,
                          cacheWidth: 300,
                        ),
                ),
                if (comic.isPrivate)
                  const Positioned(
                    left: 6,
                    top: 6,
                    child: _CardBadge(icon: Icons.lock_rounded),
                  ),
                if (comic.isPinned)
                  const Positioned(
                    right: 6,
                    top: 6,
                    child: _CardBadge(icon: Icons.push_pin_rounded),
                  ),
                if (selectionMode)
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: Checkbox(
                      value: selected,
                      onChanged: (_) => onToggle(),
                      fillColor: const WidgetStatePropertyAll(ShelfColors.blue),
                    ),
                  ),
                if (summary.itemCount > 0)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: LinearProgressIndicator(
                      value: ((comic.lastReadPosition + 1) / summary.itemCount)
                          .clamp(0, 1),
                      minHeight: 3,
                      backgroundColor: Colors.black12,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            comic.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 2),
          Text(
            '${summary.itemCount} 张 · ${formatBytes(summary.totalBytes)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: ShelfColors.muted,
              fontSize: 10.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _CardBadge extends StatelessWidget {
  const _CardBadge({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(icon, color: Colors.white, size: 13),
      ),
    );
  }
}

class _BatchActionBar extends StatelessWidget {
  const _BatchActionBar({
    required this.hasSelection,
    required this.onFolder,
    required this.onPrivate,
    required this.onPin,
    required this.onReadingList,
    required this.onDelete,
  });

  final bool hasSelection;
  final VoidCallback onFolder;
  final VoidCallback onPrivate;
  final VoidCallback onPin;
  final VoidCallback onReadingList;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    Widget action(IconData icon, String label, VoidCallback callback) =>
        Expanded(
          child: InkWell(
            onTap: hasSelection ? callback : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(icon, size: 21),
                  const SizedBox(height: 3),
                  Text(label, style: const TextStyle(fontSize: 10.5)),
                ],
              ),
            ),
          ),
        );

    return SafeArea(
      top: false,
      child: Material(
        elevation: 8,
        child: Row(
          children: <Widget>[
            action(Icons.folder_outlined, '分组', onFolder),
            action(Icons.lock_outline_rounded, '私密', onPrivate),
            action(Icons.push_pin_outlined, '置顶', onPin),
            action(Icons.bookmarks_outlined, '书单', onReadingList),
            action(Icons.delete_outline_rounded, '删除', onDelete),
          ],
        ),
      ),
    );
  }
}

class _ComicSearchDelegate extends SearchDelegate<void> {
  _ComicSearchDelegate({
    required this.controller,
    required this.includePrivate,
  });

  final AppController controller;
  final bool includePrivate;

  @override
  String get searchFieldLabel => '搜索漫画';

  @override
  List<Widget>? buildActions(BuildContext context) => <Widget>[
    if (query.isNotEmpty)
      IconButton(
        onPressed: () => query = '',
        icon: const Icon(Icons.clear_rounded),
      ),
  ];

  @override
  Widget? buildLeading(BuildContext context) => IconButton(
    onPressed: () => close(context, null),
    icon: const Icon(Icons.arrow_back_rounded),
  );

  @override
  Widget buildResults(BuildContext context) => _results(context);

  @override
  Widget buildSuggestions(BuildContext context) => _results(context);

  Widget _results(BuildContext context) {
    final normalized = query.trim().toLowerCase();
    final matches = controller.library.where((summary) {
      final inPrivateFolder = controller.folders.any(
        (folder) => folder.isPrivate && folder.id == summary.comic.folderId,
      );
      if ((summary.comic.isPrivate || inPrivateFolder) && !includePrivate) {
        return false;
      }
      return normalized.isEmpty ||
          summary.comic.title.toLowerCase().contains(normalized);
    }).toList();
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: matches.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final summary = matches[index];
        return ListTile(
          leading: SizedBox(
            width: 42,
            child: summary.coverStoredPath == null
                ? const Icon(Icons.image_outlined)
                : PrivateImage(
                    controller: controller,
                    originalPath: summary.coverStoredPath!,
                    thumbnailPath: summary.coverThumbnailPath,
                    cacheWidth: 120,
                  ),
          ),
          title: Text(summary.comic.title),
          subtitle: Text('${summary.itemCount} 张'),
          trailing: summary.comic.isPrivate
              ? const Icon(Icons.lock_outline_rounded, size: 18)
              : null,
          onTap: () {
            close(context, null);
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ComicDetailScreen(
                  controller: controller,
                  comicId: summary.comic.id,
                ),
              ),
            );
          },
        );
      },
    );
  }
}
