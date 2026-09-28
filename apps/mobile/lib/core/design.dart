import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Shared colors and controls for the native mobile screens.
abstract final class HisaabColors {
  static const primary = Color(0xFF7252DF);
  static const deep = Color(0xFF332554);
  static const ink = Color(0xFF27233B);
  static const muted = Color(0xFF696477);
  static const surface = Color(0xFFFCFAF7);
  static const teal = primary;
  static const lime = Color(0xFFE8F2BA);
  static const mint = Color(0xFFDFF3E7);
  static const peach = Color(0xFFFFE5D7);
  static const lilac = Color(0xFFEEE9FC);
  static const line = Color(0xFFEAE6EE);
  static const positive = Color(0xFF176B50);
  static const warning = Color(0xFFAF432A);
  static const balanceAmount = Color(0xFF27233B);
  static const illustrationBackground = Color(0xFFFCFAF7);
  static const fieldBorder = Color(0xFFDDD7E7);
}

/// Locally bundled editorial illustrations; no network requests on UI paths.
abstract final class HisaabArt {
  static const welcome = 'assets/illustrations/welcome-v2.png';
  static const sharing = 'assets/illustrations/sharing-v2.png';
  static const trip = 'assets/illustrations/trip-v2.png';
  static const home = 'assets/illustrations/home-v2.png';
  static const receipt = 'assets/illustrations/receipt-v2.png';
  static const together = 'assets/illustrations/together-v2.png';

  static String forGroup(String type) => switch (type) {
    'Trip' => trip,
    'Home' => home,
    'Direct' || 'Couple' => sharing,
    _ => together,
  };
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
      borderRadius: BorderRadius.circular(18),
    );
    return base.copyWith(
      // Rounded display type adds character; body and controls keep native fonts.
      cupertinoOverrideTheme: const CupertinoThemeData(
        primaryColor: HisaabColors.primary,
        scaffoldBackgroundColor: HisaabColors.surface,
        barBackgroundColor: Colors.white,
      ),
      textTheme: text.copyWith(
        displaySmall: text.displaySmall?.copyWith(
          fontFamily: 'Outfit',
          fontSize: 36,
          fontWeight: FontWeight.w700,
          height: 1.08,
          letterSpacing: -1.1,
          color: HisaabColors.ink,
        ),
        headlineLarge: text.headlineLarge?.copyWith(
          fontFamily: 'Outfit',
          fontSize: 30,
          height: 1.12,
          letterSpacing: -.7,
          fontWeight: FontWeight.w700,
        ),
        headlineMedium: text.headlineMedium?.copyWith(
          fontFamily: 'Outfit',
          fontSize: 26,
          height: 1.15,
          fontWeight: FontWeight.w700,
        ),
        headlineSmall: text.headlineSmall?.copyWith(
          fontFamily: 'Outfit',
          fontSize: 22,
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
        backgroundColor: HisaabColors.surface,
        foregroundColor: HisaabColors.ink,
        surfaceTintColor: Colors.transparent,
        centerTitle: base.platform == TargetPlatform.iOS,
        toolbarHeight: base.platform == TargetPlatform.iOS ? 44 : 56,
        elevation: 0,
        scrolledUnderElevation: 0,

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
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: HisaabColors.fieldBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: HisaabColors.primary, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 52),
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
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
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
        indicatorColor: HisaabColors.lilac,
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
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: Colors.white,
        selectedColor: HisaabColors.lilac,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        side: const BorderSide(color: HisaabColors.line),
        labelStyle: text.labelLarge?.copyWith(
          fontSize: 13,
          color: HisaabColors.ink,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: HisaabColors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? HisaabColors.lilac
                : Colors.white,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? HisaabColors.primary
                : HisaabColors.muted,
          ),
          side: const WidgetStatePropertyAll(
            BorderSide(color: HisaabColors.line),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: HisaabColors.deep,
        contentTextStyle: text.bodyMedium?.copyWith(
          fontSize: 14,
          color: Colors.white,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
