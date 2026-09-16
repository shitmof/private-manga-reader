import 'package:flutter/material.dart';

import '../theme.dart';

/// 阅读器共用的加载与错误状态。
///
/// 本地漫画与挂载/网络漫画必须使用同一套呈现，避免同一个应用中
/// 出现两种加载动画和两种错误样式。原先本地阅读器没有错误态，
/// 挂载阅读器则把错误图标写了两遍且样式不一致。
class ReaderLoadingState extends StatelessWidget {
  const ReaderLoadingState({this.night = false, this.label, super.key});

  final bool night;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final secondary = night ? Colors.white70 : ShelfColors.muted;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            width: 34,
            height: 34,
            child: CircularProgressIndicator(
              strokeWidth: 2.6,
              color: night ? Colors.white : ShelfColors.blue,
            ),
          ),
          if (label case final text?) ...<Widget>[
            const SizedBox(height: 14),
            Text(
              text,
              style: TextStyle(
                color: secondary,
                fontSize: ShelfType.caption,
                height: ShelfType.captionHeight,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 单页或整册读取失败时的统一呈现。
///
/// 只说明发生了什么，不承诺重试成功；需要重试入口时由调用方在
/// [action] 里传入，避免各处自行发明按钮样式。
class ReaderErrorState extends StatelessWidget {
  const ReaderErrorState({
    required this.message,
    this.night = false,
    this.action,
    super.key,
  });

  final String message;
  final bool night;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final secondary = night ? Colors.white54 : ShelfColors.muted;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.broken_image_outlined,
              size: 40,
              color: secondary,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: secondary,
                fontSize: ShelfType.body,
                height: ShelfType.captionHeight,
              ),
            ),
            if (action case final widget?) ...<Widget>[
              const SizedBox(height: 16),
              widget,
            ],
          ],
        ),
      ),
    );
  }
}
