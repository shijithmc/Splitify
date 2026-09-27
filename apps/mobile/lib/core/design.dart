import 'package:flutter/material.dart';

/// Shared tokens from the approved illustrated mobile design.
abstract final class HisaabColors {
  static const primary = Color(0xFF173F35);
  static const deep = Color(0xFF12392F);
  static const ink = Color(0xFF203C32);
  static const muted = Color(0xFF52645B);
  static const surface = Color(0xFFFAF9F4);
  static const teal = primary;
  static const lime = Color(0xFFD8F36A);
  static const mint = Color(0xFFECF3D9);
  static const peach = Color(0xFFF8DFCB);
  static const lilac = Color(0xFFE4E0EF);
  static const line = Color(0xFFDFE5D9);
  static const positive = Color(0xFF37694D);
  static const warning = Color(0xFF9D4D30);
  static const balanceAmount = Color(0xFFEDFFB1);
  static const illustrationBackground = Color(0xFFF3F0E5);
  static const fieldBorder = Color(0xFFCCD9C5);
}

abstract final class HisaabTheme {
  static ThemeData get light {
    final base = ThemeData(
      useMaterial3: true,
      fontFamily: 'WorkSans',
      scaffoldBackgroundColor: HisaabColors.surface,
      colorScheme: ColorScheme.fromSeed(
        seedColor: HisaabColors.primary,
        primary: HisaabColors.primary,
        onPrimary: Colors.white,
        surface: HisaabColors.surface,
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
    TextStyle heading(double size) => TextStyle(
      fontFamily: 'Outfit',
      fontSize: size,
      fontWeight: FontWeight.w600,
      color: HisaabColors.ink,
      height: 1.2,
      letterSpacing: -.5,
    );
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(15),
    );
    return base.copyWith(
      textTheme: base.textTheme.copyWith(
        displayLarge: heading(48),
        displayMedium: heading(42),
        displaySmall: heading(36),
        headlineLarge: heading(32),
        headlineMedium: heading(28),
        headlineSmall: heading(24),
        titleLarge: heading(21),
        titleMedium: const TextStyle(
          fontFamily: 'WorkSans',
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: HisaabColors.ink,
          height: 1.4,
        ),
        bodyLarge: const TextStyle(
          fontFamily: 'WorkSans',
          fontSize: 16,
          height: 1.5,
          color: HisaabColors.ink,
        ),
        bodyMedium: const TextStyle(
          fontFamily: 'WorkSans',
          fontSize: 16,
          height: 1.5,
          color: HisaabColors.ink,
        ),
        bodySmall: const TextStyle(
          fontFamily: 'WorkSans',
          fontSize: 14,
          height: 1.5,
          color: HisaabColors.muted,
        ),
        labelLarge: const TextStyle(
          fontFamily: 'WorkSans',
          fontSize: 16,
          fontWeight: FontWeight.w500,
        ),
        labelMedium: const TextStyle(
          fontFamily: 'WorkSans',
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: HisaabColors.surface,
        foregroundColor: HisaabColors.teal,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: heading(22),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(21),
          side: const BorderSide(color: HisaabColors.line),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        labelStyle: const TextStyle(fontSize: 14, color: HisaabColors.muted),
        helperStyle: const TextStyle(fontSize: 14, height: 1.5),
        errorStyle: const TextStyle(fontSize: 14, height: 1.5),
        errorMaxLines: 3,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(13)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(13),
          borderSide: const BorderSide(color: HisaabColors.fieldBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(13),
          borderSide: const BorderSide(color: HisaabColors.primary, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 52),
          shape: shape,
          textStyle: const TextStyle(
            fontFamily: 'WorkSans',
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 52),
          shape: shape,
          side: const BorderSide(color: HisaabColors.fieldBorder),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
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
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        iconColor: HisaabColors.primary,
        titleTextStyle: TextStyle(
          fontFamily: 'WorkSans',
          fontSize: 16,
          fontWeight: FontWeight.w500,
          color: HisaabColors.ink,
        ),
        subtitleTextStyle: TextStyle(
          fontFamily: 'WorkSans',
          fontSize: 14,
          height: 1.5,
          color: HisaabColors.muted,
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: HisaabColors.line,
        thickness: 1,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.white,
        indicatorColor: HisaabColors.mint,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontFamily: 'WorkSans',
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
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: Colors.white,
        selectedColor: HisaabColors.mint,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        side: const BorderSide(color: HisaabColors.line),
        labelStyle: const TextStyle(fontFamily: 'WorkSans', fontSize: 14),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: HisaabColors.teal,
        contentTextStyle: const TextStyle(
          fontFamily: 'WorkSans',
          fontSize: 14,
          color: Colors.white,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
