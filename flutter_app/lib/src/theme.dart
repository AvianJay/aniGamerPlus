/// 配色照 Dashboard/static/css/agp.css 的那組 custom property 搬過來,
/// 手機跟瀏覽器上看起來才是同一個產品.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AgpColors {
  static const bg = Color(0xFF0B0C0E);
  static const bgElev = Color(0xFF131519);
  static const card = Color(0xFF191C21);
  static const cardHover = Color(0xFF21252B);
  static const line = Color(0x17FFFFFF);
  static const lineStrong = Color(0x29FFFFFF);
  static const fg = Color(0xFFF3F4F6);
  static const fgDim = Color(0xA3FFFFFF);
  static const fgFaint = Color(0x66FFFFFF);
  static const accent = Color(0xFFFF0033);
  static const accentSoft = Color(0x24FF0033);

  /// 動畫瘋自己的那個青色. 播放器跟選集刻意跟著站上走 —— 這兩塊是使用者拿來
  /// 跟官方 app 對照著用的地方, 顏色一樣才不會每次都要重新找按鈕在哪.
  static const bahamut = Color(0xFF00B5D4);
  static const bahamutSoft = Color(0x2900B5D4);

  // 淺色模式: 同一個紅, 底換成近白
  static const lightBg = Color(0xFFF7F7F8);
  static const lightCard = Color(0xFFFFFFFF);
  static const lightFg = Color(0xFF16181D);
}

const double kRadius = 14;
const double kRadiusSmall = 10;

ThemeData buildTheme({required Brightness brightness}) {
  final dark = brightness == Brightness.dark;

  final scheme = ColorScheme.fromSeed(
    seedColor: AgpColors.accent,
    brightness: brightness,
  ).copyWith(
    primary: AgpColors.accent,
    surface: dark ? AgpColors.bg : AgpColors.lightBg,
    surfaceContainerHighest: dark ? AgpColors.card : AgpColors.lightCard,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark ? AgpColors.bg : AgpColors.lightBg,
    splashFactory: InkSparkle.splashFactory,
  );

  return base.copyWith(
    appBarTheme: AppBarTheme(
      backgroundColor: dark ? AgpColors.bg : AgpColors.lightBg,
      surfaceTintColor: Colors.transparent,
      foregroundColor: dark ? AgpColors.fg : AgpColors.lightFg,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      systemOverlayStyle:
          dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      titleTextStyle: TextStyle(
        color: dark ? AgpColors.fg : AgpColors.lightFg,
        fontSize: 19,
        fontWeight: FontWeight.w700,
      ),
    ),
    cardTheme: CardThemeData(
      color: dark ? AgpColors.card : AgpColors.lightCard,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadius)),
    ),
    dividerTheme: DividerThemeData(
      color: dark ? AgpColors.line : const Color(0x14000000),
      thickness: 1,
      space: 1,
    ),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 2),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? AgpColors.card : AgpColors.lightCard,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kRadiusSmall),
        borderSide: BorderSide(color: dark ? AgpColors.line : const Color(0x1F000000)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kRadiusSmall),
        borderSide: BorderSide(color: dark ? AgpColors.line : const Color(0x1F000000)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kRadiusSmall),
        borderSide: const BorderSide(color: AgpColors.accent, width: 1.4),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AgpColors.accent,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadiusSmall),
        ),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: dark ? AgpColors.fg : AgpColors.lightFg,
        side: BorderSide(color: dark ? AgpColors.lineStrong : const Color(0x33000000)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadiusSmall),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: AgpColors.accent),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: dark ? AgpColors.card : AgpColors.lightCard,
      side: BorderSide(color: dark ? AgpColors.line : const Color(0x14000000)),
      labelStyle: TextStyle(
        color: dark ? AgpColors.fgDim : AgpColors.lightFg,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: dark ? const Color(0xF2101216) : Colors.white,
      surfaceTintColor: Colors.transparent,
      indicatorColor: AgpColors.accentSoft,
      height: 62,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      labelTextStyle: WidgetStatePropertyAll(
        TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: dark ? AgpColors.fgDim : AgpColors.lightFg,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          size: 23,
          color: selected
              ? AgpColors.accent
              : (dark ? AgpColors.fgFaint : const Color(0x99000000)),
        );
      }),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: dark ? AgpColors.cardHover : const Color(0xFF23262C),
      contentTextStyle: const TextStyle(color: AgpColors.fg, fontSize: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadiusSmall)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: dark ? AgpColors.bgElev : Colors.white,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: dark ? AgpColors.bgElev : Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AgpColors.accent,
      linearMinHeight: 3,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? Colors.white : null),
      trackColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? AgpColors.accent : null),
    ),
  );
}
