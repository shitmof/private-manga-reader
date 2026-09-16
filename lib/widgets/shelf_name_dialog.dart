import 'package:flutter/material.dart';

/// 统一的命名输入对话框。
///
/// 规范 4.3 要求「名称不能为空；错误直接显示在输入框附近」。
/// 原先的两处实现（新建/重命名、合组面板）在名称为空时都是**静默返回**，
/// 用户点了按钮没有任何反应，也不知道原因。这里统一为内联错误提示。
///
/// 返回去除首尾空格后的名称；取消时返回 null。
Future<String?> showShelfNameDialog(
  BuildContext context, {
  required String title,
  String initial = '',
  String hintText = '输入名称',
  String confirmLabel = '保存',
  String emptyError = '名称不能为空',
  int maxLength = 40,
}) {
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => _ShelfNameDialog(
      title: title,
      initial: initial,
      hintText: hintText,
      confirmLabel: confirmLabel,
      emptyError: emptyError,
      maxLength: maxLength,
    ),
  );
}

class _ShelfNameDialog extends StatefulWidget {
  const _ShelfNameDialog({
    required this.title,
    required this.initial,
    required this.hintText,
    required this.confirmLabel,
    required this.emptyError,
    required this.maxLength,
  });

  final String title;
  final String initial;
  final String hintText;
  final String confirmLabel;
  final String emptyError;
  final int maxLength;

  @override
  State<_ShelfNameDialog> createState() => _ShelfNameDialogState();
}

class _ShelfNameDialogState extends State<_ShelfNameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _controller.text.length,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    if (value.isEmpty) {
      // 直接在输入框下方报错，而不是静默无反应。
      setState(() => _error = widget.emptyError);
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        key: const ValueKey<String>('shelf-name-field'),
        controller: _controller,
        autofocus: true,
        maxLength: widget.maxLength,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        decoration: InputDecoration(
          hintText: widget.hintText,
          errorText: _error,
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey<String>('shelf-name-confirm'),
          onPressed: _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
