import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Spotify's palette, dark or light. The app is rebuilt from the top when
/// [brightness] changes (see MusifyApp), so widgets can read these
/// directly.
class AppColors {
  static Brightness brightness = Brightness.dark;

  static bool get dark => brightness == Brightness.dark;

  static Color get background =>
      dark ? const Color(0xFF121212) : const Color(0xFFFFFFFF);
  static Color get surface =>
      dark ? const Color(0xFF1F1F1F) : const Color(0xFFF2F2F2);
  static Color get elevated =>
      dark ? const Color(0xFF282828) : const Color(0xFFFFFFFF);
  static Color get chip =>
      dark ? const Color(0xFF2A2A2A) : const Color(0xFFE9E9E9);

  /// Spotify green; a shade darker on white, to read well.
  static Color get green =>
      dark ? const Color(0xFF1ED760) : const Color(0xFF1AAE4F);
  static Color get text => dark ? Colors.white : const Color(0xFF121212);
  static Color get subtle =>
      dark ? const Color(0xFFB3B3B3) : const Color(0xFF6A6A6A);
  static Color get muted =>
      dark ? const Color(0xFF7F7F7F) : const Color(0xFF9E9E9E);

  /// On something coloured [text] (a white button in the dark theme).
  static Color get onText => dark ? Colors.black : Colors.white;

  /// Around the desktop layout's panels.
  static Color get frame => dark ? Colors.black : const Color(0xFFE6E6E6);

  /// Lines and the empty part of tracks: [text], faintly.
  static Color get faint => text.withValues(alpha: 0.12);
  static Color get track => text.withValues(alpha: 0.24);

  /// How far a YouTube video has loaded, on a seek bar.
  static Color get loaded => text.withValues(alpha: 0.45);

  /// A colour from a cover, made into a background the text reads on:
  /// darkened in the dark theme, lightened in the light one.
  static Color backdrop(Color color, double amount) =>
      Color.lerp(color, dark ? Colors.black : Colors.white, amount)!;

  /// [color] as the top of a header gradient: as is in the dark theme,
  /// lightened in the light one so dark text reads on it.
  static Color tint(Color color) => dark ? color : backdrop(color, 0.6);
}

ThemeData buildTheme(Brightness brightness) {
  AppColors.brightness = brightness;
  final dark = brightness == Brightness.dark;
  final scheme = (dark ? const ColorScheme.dark() : const ColorScheme.light())
      .copyWith(
        primary: AppColors.green,
        onPrimary: Colors.black,
        secondary: AppColors.green,
        surface: AppColors.background,
        onSurface: AppColors.text,
        onSurfaceVariant: AppColors.subtle,
        surfaceContainerHighest: AppColors.elevated,
      );
  return ThemeData(
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: 'Figtree',
    scaffoldBackgroundColor: AppColors.background,
    splashFactory: NoSplash.splashFactory,
    highlightColor: AppColors.text.withValues(alpha: 0.06),
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.background,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      foregroundColor: AppColors.text,
      systemOverlayStyle: dark
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
      titleTextStyle: TextStyle(
        fontFamily: 'Figtree',
        color: AppColors.text,
        fontSize: 22,
        fontWeight: FontWeight.w700,
      ),
    ),
    listTileTheme: ListTileThemeData(
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
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.elevated,
      contentTextStyle: TextStyle(fontFamily: 'Figtree', color: AppColors.text),
      behavior: SnackBarBehavior.floating,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: AppColors.elevated,
      surfaceTintColor: Colors.transparent,
    ),
    dialogTheme: DialogThemeData(backgroundColor: AppColors.elevated),
    popupMenuTheme: PopupMenuThemeData(
      color: AppColors.elevated,
      surfaceTintColor: Colors.transparent,
    ),
    dividerTheme: DividerThemeData(color: AppColors.faint),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.text,
        foregroundColor: AppColors.onText,
        textStyle: const TextStyle(
          fontFamily: 'Figtree',
          fontWeight: FontWeight.w700,
          fontSize: 15,
        ),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: AppColors.green),
  );
}
