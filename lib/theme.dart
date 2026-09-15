import 'package:flutter/material.dart';

/// 拾画阁统一设计参数。
///
/// 所有页面必须复用这里的取值，不要在各自文件里再写一套颜色和尺寸。
/// 取值依据《整体 UI 升级、功能补齐与版本验收任务》第二节「统一视觉规范」。
abstract final class ShelfColors {
  /// 页面背景。
  static const paper = Color(0xFFF7F8FA);

  /// 卡片、面板背景。
  static const surface = Color(0xFFFFFFFF);

  /// 主文字。
  static const ink = Color(0xFF17202B);

  /// 次要文字、说明。
  static const muted = Color(0xFF6D7784);

  /// 品牌蓝、主要按钮。
  static const blue = Color(0xFF2D75C7);

  /// 浅蓝选中背景。
  static const blueSoft = Color(0xFFEAF2FC);

  /// 边框、分隔线。
  static const line = Color(0xFFE5E9EE);

  /// 夜间画布。仅用于用户主动选择的夜间阅读，不作为默认。
  static const dark = Color(0xFF111418);
}

/// 间距与尺寸。
abstract final class ShelfMetrics {
  /// 页面左右留白。
  static const pagePadding = 16.0;

  /// 封面到标题。
  static const coverToTitle = 10.0;

  /// 标题到说明。
  static const titleToCaption = 5.0;

  /// 三列网格：列间距。
  static const gridColumnGap = 14.0;

  /// 三列网格：行间距。
  static const gridRowGap = 24.0;

  /// 封面宽 ÷ 高。
  static const coverAspect = 0.72;

  /// 普通封面圆角。
  static const coverRadius = 12.0;

  /// 卡片、分组容器圆角。
  static const cardRadius = 16.0;

  /// 底部弹层顶部圆角。
  static const sheetRadius = 24.0;

  /// 常用按钮最小高度。
  static const buttonHeight = 48.0;

  /// 图标本体尺寸。点击区域不得小于 [minTapTarget]。
  static const iconSize = 22.0;

  /// 最小点击区域。
  static const minTapTarget = 48.0;

  /// 分组四宫格：内边距。
  static const groupPadding = 8.0;

  /// 分组四宫格：槽位间距。
  static const groupGap = 4.0;

  /// 标题固定占两行高度，保证同排卡片底部对齐。
  static const cardTitleLines = 2;

  /// 卡片文字区总高度：封面到标题 + 两行标题 + 标题到说明 + 一行说明。
  ///
  /// 单独拎出来是为了让网格用「封面高度（按宽高比算）+ 固定文字区」确定卡片高度，
  /// 而不是反复调 childAspectRatio 去猜。
  static const cardTextBlockHeight =
      coverToTitle + titleBlockHeight + titleToCaption + captionLineHeight;

  /// 两行标题的固定高度。
  static const titleBlockHeight = 38.0;

  /// 一行说明的固定高度。
  static const captionLineHeight = 16.0;
}

/// 字号层级。标题、正文、说明必须有明显区分。
abstract final class ShelfType {
  /// 页面标题。
  static const pageTitle = 22.0;

  /// 卡片标题。
  static const cardTitle = 14.0;

  /// 正文、设置项名称。
  static const body = 15.0;

  /// 次要说明。
  static const caption = 12.0;

  /// 说明文字行高。字号放大时增加行高，而不是缩小文字。
  static const captionHeight = 1.45;
}

/// 动效时长。只做必要、清楚、轻量的动画。
abstract final class ShelfMotion {
  /// 按钮、选中状态反馈。
  static const feedback = Duration(milliseconds: 120);

  /// 阅读工具栏显示与隐藏。
  static const toolbar = Duration(milliseconds: 180);

  /// 卡片让位、面板开合。
  static const reflow = Duration(milliseconds: 240);

  /// 合组完成。
  static const groupFormed = Duration(milliseconds: 300);

  /// 快速定位条松手后隐藏的等待时间。
  static const scrubberHideDelay = Duration(milliseconds: 1100);
}

ThemeData buildShelfTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: ShelfColors.blue,
    brightness: brightness,
    primary: dark ? const Color(0xFF83B8F1) : ShelfColors.blue,
    surface: dark ? const Color(0xFF171B20) : ShelfColors.surface,
  );
  final foreground = dark ? Colors.white : ShelfColors.ink;
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark ? ShelfColors.dark : ShelfColors.paper,
    fontFamily: 'Noto Sans CJK SC',
    fontFamilyFallback: const <String>[
      'Source Han Sans SC',
      'PingFang SC',
      'Microsoft YaHei',
    ],
    textTheme: const TextTheme(
      headlineMedium: TextStyle(
        fontWeight: FontWeight.w800,
        letterSpacing: -0.8,
      ),
      titleLarge: TextStyle(fontWeight: FontWeight.w800, letterSpacing: -0.35),
      titleMedium: TextStyle(fontWeight: FontWeight.w700),
      bodyMedium: TextStyle(fontSize: ShelfType.body, height: 1.45),
      bodySmall: TextStyle(
        fontSize: ShelfType.caption,
        height: ShelfType.captionHeight,
      ),
    ),
    appBarTheme: AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      backgroundColor: dark ? ShelfColors.dark : ShelfColors.paper,
      foregroundColor: foreground,
      toolbarHeight: 60,
      titleTextStyle: TextStyle(
        color: foreground,
        fontSize: ShelfType.pageTitle,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.5,
      ),
    ),
    // 同级页面复用同一套卡片、按钮、分隔线与弹层样式。
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ShelfMetrics.cardRadius),
        side: BorderSide(color: dark ? Colors.white10 : ShelfColors.line),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: dark ? const Color(0xFF20242A) : ShelfColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(ShelfMetrics.sheetRadius),
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      elevation: 0,
      backgroundColor: dark ? const Color(0xFF20242A) : ShelfColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ShelfMetrics.cardRadius),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, ShelfMetrics.buttonHeight),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ShelfMetrics.cardRadius),
        ),
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(0, ShelfMetrics.buttonHeight),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? Colors.white.withValues(alpha: 0.06) : Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    ),
    dividerTheme: DividerThemeData(
      color: dark ? Colors.white12 : ShelfColors.line,
      thickness: 1,
    ),
  );
}
