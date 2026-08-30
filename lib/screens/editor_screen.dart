import 'package:flutter/material.dart';

import '../models/entities.dart';
import '../state/app_controller.dart';
import '../theme.dart';
import '../widgets/import_flow.dart';
import '../widgets/private_image.dart';

class EditorScreen extends StatefulWidget {
  const EditorScreen({
    required this.controller,
    required this.comicId,
    super.key,
  });

  final AppController controller;
  final String comicId;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  final ScrollController _scrollController = ScrollController();
  List<ComicItemRecord> _items = <ComicItemRecord>[];
  final Set<String> _removedIds = <String>{};
  final Set<String> _addedIds = <String>{};
  List<String> _originalIds = <String>[];
  String? _originalCoverAssetId;
  String? _coverAssetId;
  final Set<String> _selectedItemIds = <String>{};
  bool _loading = true;
  bool _saving = false;
  bool _allowPop = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load({bool initial = true}) async {
    final items = await widget.controller.loadItems(widget.comicId);
    if (!mounted) return;
    setState(() {
      _items = List<ComicItemRecord>.of(items);
      if (initial) {
        _originalIds = items.map((item) => item.id).toList(growable: false);
        _originalCoverAssetId = widget.controller
            .summaryFor(widget.comicId)
            ?.comic
            .coverAssetId;
        _coverAssetId = _originalCoverAssetId;
      }
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final title =
        widget.controller.summaryFor(widget.comicId)?.comic.title ?? '编辑';
    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && !_allowPop) _cancel();
      },
      child: Scaffold(
        appBar: AppBar(
          leadingWidth: 72,
          leading: TextButton(
            onPressed: _saving ? null : _cancel,
            child: const Text('取消'),
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(
                _selectedItemIds.isEmpty
                    ? '${_items.length} / 1000 张'
                    : '已选择 ${_selectedItemIds.length} 张',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: _selectedItemIds.isEmpty
                      ? ShelfColors.muted
                      : ShelfColors.blue,
                ),
              ),
            ],
          ),
          centerTitle: true,
          actions: <Widget>[
            PopupMenuButton<String>(
              tooltip: '选择范围或全选',
              enabled: !_saving && _items.isNotEmpty,
              onSelected: (value) {
                if (value == 'all') _toggleSelectAll();
                if (value == 'range') _selectRange();
              },
              itemBuilder: (_) => <PopupMenuEntry<String>>[
                PopupMenuItem(
                  value: 'all',
                  child: Text(
                    _selectedItemIds.length == _items.length
                        ? '取消全选'
                        : '全选 ${_items.length} 张',
                  ),
                ),
                const PopupMenuItem(value: 'range', child: Text('选择范围')),
              ],
            ),
            TextButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('保存'),
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _items.isEmpty
            ? Center(
                child: FilledButton.icon(
                  onPressed: _addImages,
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  label: const Text('添加图片'),
                ),
              )
            : Scrollbar(
                controller: _scrollController,
                interactive: true,
                thickness: 6,
                radius: const Radius.circular(3),
                child: GridView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 108),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    childAspectRatio: 0.72,
                  ),
                  itemCount: _items.length,
                  itemBuilder: (context, index) => _buildDraggableItem(index),
                ),
              ),
        bottomNavigationBar: _EditorToolbar(
          hasSelection: _selectedItemIds.isNotEmpty,
          canAdd: _items.length < 1000,
          onAscending: _sortAscending,
          onDescending: _reverse,
          onAdd: _addImages,
          onDelete: _deleteSelected,
          onCover: _setSelectedAsCover,
          onMove: _moveSelected,
        ),
      ),
    );
  }

  Widget _buildDraggableItem(int index) {
    final item = _items[index];
    final selected = _selectedItemIds.contains(item.id);
    final isCover =
        item.asset.id == _coverAssetId || (_coverAssetId == null && index == 0);
    return DragTarget<int>(
      onWillAcceptWithDetails: (details) => details.data != index,
      onAcceptWithDetails: (details) {
        setState(() {
          final moving = _items.removeAt(details.data);
          _items.insert(index, moving);
        });
      },
      builder: (context, candidates, rejected) => LongPressDraggable<int>(
        data: index,
        feedback: SizedBox(
          width: 112,
          height: 156,
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(14),
            child: _ImageTile(
              controller: widget.controller,
              item: item,
              index: index,
              selected: true,
              isCover: isCover,
            ),
          ),
        ),
        childWhenDragging: Opacity(
          opacity: 0.25,
          child: _ImageTile(
            controller: widget.controller,
            item: item,
            index: index,
            selected: selected,
            isCover: isCover,
          ),
        ),
        child: Semantics(
          container: true,
          button: true,
          selected: selected,
          label: '第 ${index + 1} 张，${selected ? '已选择，点按取消选择' : '未选择，点按选择'}',
          excludeSemantics: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() {
              if (selected) {
                _selectedItemIds.remove(item.id);
              } else {
                _selectedItemIds.add(item.id);
              }
            }),
            child: AnimatedScale(
              scale: candidates.isEmpty ? 1 : 0.94,
              duration: const Duration(milliseconds: 120),
              child: _ImageTile(
                controller: widget.controller,
                item: item,
                index: index,
                selected: selected,
                isCover: isCover,
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _sortAscending() {
    setState(() {
      _items.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    });
  }

  void _reverse() => setState(() => _items = _items.reversed.toList());

  void _toggleSelectAll() => setState(() {
    if (_selectedItemIds.length == _items.length) {
      _selectedItemIds.clear();
    } else {
      _selectedItemIds
        ..clear()
        ..addAll(_items.map((item) => item.id));
    }
  });

  Future<void> _selectRange() async {
    var startText = '';
    var endText = '';
    final range = await showDialog<(int, int)>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('选择范围'),
        content: Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                key: const ValueKey<String>('range-start'),
                autofocus: true,
                keyboardType: TextInputType.number,
                onChanged: (value) => startText = value,
                decoration: const InputDecoration(labelText: '起始页'),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: Text('至'),
            ),
            Expanded(
              child: TextField(
                key: const ValueKey<String>('range-end'),
                keyboardType: TextInputType.number,
                onChanged: (value) => endText = value,
                decoration: InputDecoration(
                  labelText: '结束页',
                  helperText: '最大 ${_items.length}',
                ),
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final start = int.tryParse(startText.trim());
              final end = int.tryParse(endText.trim());
              if (start != null &&
                  end != null &&
                  start >= 1 &&
                  end >= start &&
                  end <= _items.length) {
                Navigator.pop(context, (start, end));
              }
            },
            child: const Text('选中'),
          ),
        ],
      ),
    );
    if (range == null || !mounted) return;
    setState(() {
      _selectedItemIds.addAll(
        _items.sublist(range.$1 - 1, range.$2).map((item) => item.id),
      );
    });
  }

  Future<void> _addImages() async {
    final before = _items.map((item) => item.id).toSet();
    final report = await runImportFlow(
      context: context,
      controller: widget.controller,
      comicId: widget.comicId,
    );
    if (report == null || !mounted) return;
    final items = await widget.controller.loadItems(widget.comicId);
    if (!mounted) return;
    setState(() {
      for (final item in items) {
        if (!before.contains(item.id)) _addedIds.add(item.id);
      }
      _items = List<ComicItemRecord>.of(items);
    });
  }

  Future<void> _deleteSelected() async {
    if (_selectedItemIds.isEmpty) return;
    final count = _selectedItemIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除选中的 $count 张图片？'),
        content: const Text('保存后将从这本漫画中移除。其他漫画引用的原图不会受影响。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      final removed = _items
          .where((item) => _selectedItemIds.contains(item.id))
          .toList(growable: false);
      _items.removeWhere((item) => _selectedItemIds.contains(item.id));
      _removedIds.addAll(_selectedItemIds);
      if (removed.any((item) => item.asset.id == _coverAssetId)) {
        _coverAssetId = null;
      }
      _selectedItemIds.clear();
    });
  }

  Future<void> _moveSelected() async {
    if (_selectedItemIds.isEmpty) return;
    var targetText = '';
    final targetPage = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移动到指定页'),
        content: TextField(
          autofocus: true,
          keyboardType: TextInputType.number,
          onChanged: (value) => targetText = value,
          decoration: InputDecoration(
            labelText: '目标页码',
            helperText: '可输入 1 到 ${_items.length}',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final value = int.tryParse(targetText.trim());
              if (value != null && value >= 1 && value <= _items.length) {
                Navigator.pop(context, value);
              }
            },
            child: const Text('移动'),
          ),
        ],
      ),
    );
    if (targetPage == null || !mounted) return;
    setState(() {
      final moving = _items
          .where((item) => _selectedItemIds.contains(item.id))
          .toList(growable: false);
      final remaining = _items
          .where((item) => !_selectedItemIds.contains(item.id))
          .toList();
      final insertion = (targetPage - 1).clamp(0, remaining.length);
      remaining.insertAll(insertion, moving);
      _items = remaining;
      _selectedItemIds.clear();
    });
  }

  void _setSelectedAsCover() {
    if (_selectedItemIds.length != 1) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('设置封面时请选择一张图片')));
      return;
    }
    final id = _selectedItemIds.single;
    final item = _items.firstWhere((item) => item.id == id);
    setState(() => _coverAssetId = item.asset.id);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已选择新封面，保存后生效')));
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.controller.applyItemEdits(
        comicId: widget.comicId,
        orderedItemIds: _items.map((item) => item.id).toList(growable: false),
        removedItemIds: _removedIds.toList(growable: false),
        coverAssetId: _coverAssetId,
      );
      if (mounted) {
        setState(() => _allowPop = true);
        Navigator.pop(context);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _cancel() async {
    if (_addedIds.isNotEmpty) {
      await widget.controller.applyItemEdits(
        comicId: widget.comicId,
        orderedItemIds: _originalIds,
        removedItemIds: _addedIds.toList(growable: false),
        coverAssetId: _originalCoverAssetId,
      );
    }
    if (mounted) {
      setState(() => _allowPop = true);
      Navigator.pop(context);
    }
  }
}

class _ImageTile extends StatelessWidget {
  const _ImageTile({
    required this.controller,
    required this.item,
    required this.index,
    required this.selected,
    required this.isCover,
  });

  final AppController controller;
  final ComicItemRecord item;
  final int index;
  final bool selected;
  final bool isCover;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: selected ? ShelfColors.blue : Colors.transparent,
          width: selected ? 3 : 0,
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          PrivateImage(
            controller: controller,
            originalPath: item.asset.storedPath,
            thumbnailPath: item.asset.thumbnailPath,
            cacheWidth: 300,
            borderRadius: BorderRadius.circular(selected ? 10 : 14),
          ),
          Positioned(
            left: 6,
            top: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xCC111418),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Text(
                '${index + 1}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          if (isCover)
            const Positioned(
              right: 7,
              top: 7,
              child: CircleAvatar(
                radius: 12,
                backgroundColor: ShelfColors.blue,
                child: Icon(
                  Icons.bookmark_rounded,
                  size: 14,
                  color: Colors.white,
                ),
              ),
            ),
          if (selected)
            const Positioned(
              right: 7,
              bottom: 7,
              child: CircleAvatar(
                radius: 12,
                backgroundColor: ShelfColors.blue,
                child: Icon(Icons.check_rounded, size: 15, color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }
}

class _EditorToolbar extends StatelessWidget {
  const _EditorToolbar({
    required this.hasSelection,
    required this.canAdd,
    required this.onAscending,
    required this.onDescending,
    required this.onAdd,
    required this.onDelete,
    required this.onCover,
    required this.onMove,
  });

  final bool hasSelection;
  final bool canAdd;
  final VoidCallback onAscending;
  final VoidCallback onDescending;
  final VoidCallback onAdd;
  final VoidCallback onDelete;
  final VoidCallback onCover;
  final VoidCallback onMove;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 72,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: <Widget>[
              _Tool(
                icon: Icons.arrow_upward_rounded,
                label: '正序',
                onTap: onAscending,
              ),
              _Tool(
                icon: Icons.swap_vert_rounded,
                label: '倒序',
                onTap: onDescending,
              ),
              _Tool(
                icon: Icons.add_rounded,
                label: '添加',
                onTap: canAdd ? onAdd : null,
              ),
              _Tool(
                icon: Icons.low_priority_rounded,
                label: '移动',
                onTap: hasSelection ? onMove : null,
              ),
              _Tool(
                icon: Icons.delete_outline_rounded,
                label: '删除',
                onTap: hasSelection ? onDelete : null,
              ),
              _Tool(
                icon: Icons.bookmark_outline_rounded,
                label: '封面',
                onTap: hasSelection ? onCover : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tool extends StatelessWidget {
  const _Tool({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: onTap,
      radius: 30,
      child: SizedBox(
        width: 58,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(icon, size: 22, color: onTap == null ? Colors.grey : null),
            const SizedBox(height: 3),
            Text(label, style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
      ),
    );
  }
}
