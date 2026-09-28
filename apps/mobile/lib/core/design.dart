import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Shared colors and controls for the native mobile screens.
abstract final class HisaabColors {
  static const primary = Color(0xFF176B50);
  static const deep = Color(0xFF12392F);
  static const ink = Color(0xFF1C2421);
  static const muted = Color(0xFF66716B);
  static const surface = Color(0xFFF4F5F7);
  static const teal = primary;
  static const lime = Color(0xFFD8F36A);
  static const mint = Color(0xFFEAF3EE);
  static const peach = Color(0xFFF9EDE6);
  static const lilac = Color(0xFFF0EFF6);
  static const line = Color(0xFFE1E5E2);
  static const positive = Color(0xFF176B50);
  static const warning = Color(0xFFAD492C);
  static const balanceAmount = Color(0xFFEDFFB1);
  static const illustrationBackground = Color(0xFFF3F0E5);
  static const fieldBorder = Color(0xFFD3DAD6);
}

abstract final class HisaabTheme {
  static ThemeData get light {
    final base = ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: HisaabColors.surface,
      colorScheme: ColorScheme.fromSeed(
        seedColor: HisaabColors.primary,
        primary: HisaabColors.primary,
        onPrimary: Colors.white,
        surface: Colors.white,
        onSurface: HisaabColors.ink,
        onSurfaceVariant: HisaabColors.muted,
        secondary: HisaabColors.positive,
        secondaryContainer: HisaabColors.mint,
        onSecondaryContainer: HisaabColors.ink,
        tertiaryContainer: HisaabColors.lilac,
        outline: HisaabColors.fieldBorder,
        outlineVariant: HisaabColors.line,
        error: HisaabColors.warning,
      ),
    );
    final text = base.textTheme;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
    );
    return base.copyWith(
      // Let Flutter use each platform's system typeface and route transitions.
      cupertinoOverrideTheme: const CupertinoThemeData(
        primaryColor: HisaabColors.primary,
        scaffoldBackgroundColor: HisaabColors.surface,
        barBackgroundColor: Colors.white,
      ),
      textTheme: text.copyWith(
        headlineLarge: text.headlineLarge?.copyWith(
          fontSize: 30,
          fontWeight: FontWeight.w700,
        ),
        headlineMedium: text.headlineMedium?.copyWith(
          fontSize: 24,
          fontWeight: FontWeight.w600,
        ),
        headlineSmall: text.headlineSmall?.copyWith(
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
        titleLarge: text.titleLarge?.copyWith(
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
        titleMedium: text.titleMedium?.copyWith(
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
        bodyLarge: text.bodyLarge?.copyWith(fontSize: 16, height: 1.35),
        bodyMedium: text.bodyMedium?.copyWith(fontSize: 15, height: 1.35),
        bodySmall: text.bodySmall?.copyWith(
          fontSize: 13,
          height: 1.35,
          color: HisaabColors.muted,
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: HisaabColors.ink,
        surfaceTintColor: Colors.transparent,
        centerTitle: base.platform == TargetPlatform.iOS,
        toolbarHeight: base.platform == TargetPlatform.iOS ? 44 : 56,
        elevation: 0,
        scrolledUnderElevation: 0,
        shape: const Border(
          bottom: BorderSide(color: HisaabColors.line, width: .5),
        ),
        titleTextStyle: text.titleMedium?.copyWith(
          fontSize: base.platform == TargetPlatform.iOS ? 17 : 20,
          fontWeight: FontWeight.w600,
          color: HisaabColors.ink,
        ),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: shape,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        labelStyle: const TextStyle(fontSize: 14, color: HisaabColors.muted),
        helperStyle: const TextStyle(fontSize: 13),
        errorStyle: const TextStyle(fontSize: 13),
        errorMaxLines: 3,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: HisaabColors.fieldBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: HisaabColors.primary, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: shape,
          textStyle: text.labelLarge?.copyWith(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: shape,
          side: const BorderSide(color: HisaabColors.fieldBorder),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: shape,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(48, 48),
          foregroundColor: HisaabColors.primary,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: HisaabColors.primary,
        foregroundColor: Colors.white,
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        extendedTextStyle: text.labelLarge?.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        minVerticalPadding: 10,
        iconColor: HisaabColors.primary,
        titleTextStyle: text.titleMedium?.copyWith(
          fontSize: 16,
          fontWeight: FontWeight.w500,
          color: HisaabColors.ink,
        ),
        subtitleTextStyle: text.bodySmall?.copyWith(
          fontSize: 13,
          height: 1.35,
          color: HisaabColors.muted,
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: HisaabColors.line,
        thickness: .5,
        space: 1,
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 64,
        backgroundColor: Colors.white,
        indicatorColor: HisaabColors.mint,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w400,
            color: states.contains(WidgetState.selected)
                ? HisaabColors.primary
                : HisaabColors.muted,
          ),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: HisaabColors.surface,
        showDragHandle: true,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: Colors.white,
        selectedColor: HisaabColors.mint,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        side: const BorderSide(color: HisaabColors.line),
        labelStyle: text.labelLarge?.copyWith(
          fontSize: 13,
          color: HisaabColors.ink,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: HisaabColors.deep,
        contentTextStyle: text.bodyMedium?.copyWith(
          fontSize: 14,
          color: Colors.white,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
