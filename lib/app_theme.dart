import 'package:flutter/material.dart';

/// Colours and theme for One For All Studio.
class AppColors {
  static const bg = Color(0xFF0E0F12);
  static const surface = Color(0xFF17191E);
  static const surfaceHi = Color(0xFF22252C);
  static const line = Color(0xFF2E323B);
  static const text = Color(0xFFF1F2F4);
  static const textDim = Color(0xFF9097A3);
  static const accent = Color(0xFFFFB347);
  static const accent2 = Color(0xFF3FD0C9);
  static const danger = Color(0xFFFF5D5D);
}

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.accent,
    brightness: Brightness.dark,
  ).copyWith(
    primary: AppColors.accent,
    secondary: AppColors.accent2,
    surface: AppColors.surface,
    onSurface: AppColors.text,
    error: AppColors.danger,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.bg,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.bg,
      foregroundColor: AppColors.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(
        color: AppColors.text,
        fontSize: 17,
        fontWeight: FontWeight.w600,
      ),
    ),
    sliderTheme: const SliderThemeData(
      trackHeight: 2,
      activeTrackColor: AppColors.accent,
      inactiveTrackColor: AppColors.line,
      thumbColor: AppColors.text,
      overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 7),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
    ),
    dialogTheme: const DialogThemeData(backgroundColor: AppColors.surface),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: AppColors.surfaceHi,
      contentTextStyle: TextStyle(color: AppColors.text),
      behavior: SnackBarBehavior.floating,
    ),
    dividerColor: AppColors.line,
    textTheme: const TextTheme(
      bodyMedium: TextStyle(color: AppColors.text, fontSize: 14),
      bodySmall: TextStyle(color: AppColors.textDim, fontSize: 12),
    ),
  );
}
