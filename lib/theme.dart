import 'package:flutter/material.dart';

abstract final class ShelfColors {
  static const ink = Color(0xFF17202B);
  static const muted = Color(0xFF6D7784);
  static const blue = Color(0xFF2D75C7);
  static const blueSoft = Color(0xFFEAF2FC);
  static const paper = Color(0xFFF7F8FA);
  static const line = Color(0xFFE5E9EE);
  static const dark = Color(0xFF111418);
}

ThemeData buildShelfTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: ShelfColors.blue,
    brightness: brightness,
    primary: dark ? const Color(0xFF83B8F1) : ShelfColors.blue,
    surface: dark ? const Color(0xFF171B20) : Colors.white,
  );
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
      bodyMedium: TextStyle(height: 1.45),
    ),
    appBarTheme: AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      backgroundColor: dark ? ShelfColors.dark : ShelfColors.paper,
      foregroundColor: dark ? Colors.white : ShelfColors.ink,
      titleTextStyle: TextStyle(
        color: dark ? Colors.white : ShelfColors.ink,
        fontSize: 22,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.5,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: dark ? Colors.white10 : ShelfColors.line),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
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
