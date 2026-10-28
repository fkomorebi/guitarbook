import 'package:flutter/material.dart';

/// Shared musical state colors; always paired with a label or icon.
abstract final class PracticeColors {
  static Color recording(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFFFFB59A)
      : const Color(0xFFA34225);

  static Color inTune(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFFA4D69A)
      : const Color(0xFF326B31);
}

ThemeData buildAppTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: const Color(0xFF24695C),
        brightness: brightness,
      ).copyWith(
        primary: Color(dark ? 0xFF95D5BE : 0xFF24695C),
        onPrimary: Color(dark ? 0xFF00382B : 0xFFFFFFFF),
        primaryContainer: Color(dark ? 0xFF263F35 : 0xFFDCEAE0),
        onPrimaryContainer: Color(dark ? 0xFFD1EBDD : 0xFF183D32),
        surface: Color(dark ? 0xFF131B18 : 0xFFF7F5EF),
        onSurface: Color(dark ? 0xFFE4EBE3 : 0xFF202B28),
        surfaceContainerLow: Color(dark ? 0xFF1C2621 : 0xFFFFFCF6),
      );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme);
  const radius = BorderRadius.all(Radius.circular(20));
  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w700,
      ),
    ),
    cardTheme: CardThemeData(
      color: scheme.surfaceContainerLow,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .6)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerLow,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 24),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 500),
    ),
  );
}
