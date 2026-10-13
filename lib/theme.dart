import 'package:flutter/material.dart';

/// Spotify's dark palette.
class AppColors {
  static const background = Color(0xFF121212);
  static const surface = Color(0xFF1F1F1F);
  static const elevated = Color(0xFF282828);
  static const chip = Color(0xFF2A2A2A);
  static const green = Color(0xFF1ED760);
  static const text = Colors.white;
  static const subtle = Color(0xFFB3B3B3);
  static const muted = Color(0xFF7F7F7F);
}

ThemeData buildTheme() {
  const scheme = ColorScheme.dark(
    primary: AppColors.green,
    onPrimary: Colors.black,
    secondary: AppColors.green,
    surface: AppColors.background,
    onSurface: AppColors.text,
    onSurfaceVariant: AppColors.subtle,
    surfaceContainerHighest: AppColors.elevated,
  );
  return ThemeData(
    colorScheme: scheme,
    fontFamily: 'Figtree',
    scaffoldBackgroundColor: AppColors.background,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.white10,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.background,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      foregroundColor: AppColors.text,
      titleTextStyle: TextStyle(
        fontFamily: 'Figtree',
        color: AppColors.text,
        fontSize: 22,
        fontWeight: FontWeight.w700,
      ),
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: AppColors.subtle,
      titleTextStyle: TextStyle(
        fontFamily: 'Figtree',
        color: AppColors.text,
        fontSize: 16,
      ),
      subtitleTextStyle: TextStyle(
        fontFamily: 'Figtree',
        color: AppColors.subtle,
        fontSize: 13,
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: AppColors.elevated,
      contentTextStyle: TextStyle(fontFamily: 'Figtree', color: AppColors.text),
      behavior: SnackBarBehavior.floating,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.elevated,
      surfaceTintColor: Colors.transparent,
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: AppColors.elevated,
      surfaceTintColor: Colors.transparent,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.text,
        foregroundColor: Colors.black,
        textStyle: const TextStyle(
            fontFamily: 'Figtree', fontWeight: FontWeight.w700, fontSize: 15),
      ),
    ),
    progressIndicatorTheme:
        const ProgressIndicatorThemeData(color: AppColors.green),
  );
}
