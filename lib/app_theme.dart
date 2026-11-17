import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Darkroom-HUD palette: a deep cool void, warm paper text, one amber
/// "safelight" accent for actions, and a cyan "signal" used only for light
/// edges and secondary state.
class AppColors {
  static const bg = Color(0xFF08090C);
  static const surface = Color(0xFF111319);
  static const surfaceHi = Color(0xFF1A1D25);
  static const line = Color(0xFF272B35);
  static const text = Color(0xFFF2F0EA);
  static const textDim = Color(0xFF9A9BA3); // 7:1 on bg
  static const accent = Color(0xFFFFB02E);
  static const accent2 = Color(0xFF4FD8E0);
  static const danger = Color(0xFFFF5C57);
  static const onAccent = Color(0xFF1A1200);
}

/// Radii used across the app, so surfaces feel related.
class AppRadius {
  static const double chip = 14;
  static const double control = 14;
  static const double card = 20;
  static const double sheet = 26;
  static const double dock = 24;
}

/// Shared geometry the slider theme and tap-to-reset both depend on.
class SliderGeom {
  static const double thumb = 9;
  static const double overlay = 18; // also the track inset on each side
  static const double rowHeight = 48; // a full touch target
}

/// The signature surface: an opaque panel lit along its top edge, amber
/// fading into cyan. No live blur, so it costs nothing while you drag.
BoxDecoration litPanel({double radius = AppRadius.dock, bool glow = false}) => BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: AppColors.line),
      boxShadow: [
        const BoxShadow(color: Color(0x99000000), blurRadius: 24, offset: Offset(0, 10)),
        if (glow) BoxShadow(color: AppColors.accent.withValues(alpha: 0.10), blurRadius: 30, spreadRadius: -6),
      ],
    );

/// A 1px light edge drawn over a panel's top border.
class LightEdge extends StatelessWidget {
  final double inset;
  const LightEdge({super.key, this.inset = 22});

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.symmetric(horizontal: inset),
        child: Container(
          height: 1,
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [
              AppColors.accent.withValues(alpha: 0),
              AppColors.accent.withValues(alpha: 0.55),
              AppColors.accent2.withValues(alpha: 0.45),
              AppColors.accent2.withValues(alpha: 0),
            ]),
          ),
        ),
      );
}

TextStyle display(double size, {FontWeight weight = FontWeight.w700, Color color = AppColors.text, double? spacing}) =>
    GoogleFonts.bricolageGrotesque(fontSize: size, fontWeight: weight, color: color, letterSpacing: spacing ?? -size * 0.02);

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.accent,
    brightness: Brightness.dark,
  ).copyWith(
    primary: AppColors.accent,
    onPrimary: AppColors.onAccent,
    secondary: AppColors.accent2,
    surface: AppColors.surface,
    onSurface: AppColors.text,
    error: AppColors.danger,
    outline: AppColors.line,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, brightness: Brightness.dark);
  final body = GoogleFonts.instrumentSansTextTheme(base.textTheme).apply(
    bodyColor: AppColors.text,
    displayColor: AppColors.text,
  );
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.control));
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.bg,
    textTheme: body.copyWith(
      titleLarge: display(22),
      titleMedium: display(17, weight: FontWeight.w600),
      titleSmall: display(14, weight: FontWeight.w600),
      bodyMedium: body.bodyMedium!.copyWith(fontSize: 14, color: AppColors.text),
      bodySmall: body.bodySmall!.copyWith(fontSize: 12, color: AppColors.textDim),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.bg,
      foregroundColor: AppColors.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: display(20),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: AppColors.onAccent,
        disabledBackgroundColor: AppColors.surfaceHi,
        disabledForegroundColor: AppColors.textDim,
        minimumSize: const Size(64, 44),
        shape: shape,
        textStyle: GoogleFonts.instrumentSans(fontWeight: FontWeight.w700, fontSize: 14),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.text,
        side: const BorderSide(color: AppColors.line),
        minimumSize: const Size(64, 44),
        shape: shape,
        textStyle: GoogleFonts.instrumentSans(fontWeight: FontWeight.w600, fontSize: 14),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.accent,
        textStyle: GoogleFonts.instrumentSans(fontWeight: FontWeight.w600),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: AppColors.text),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      height: 68,
      indicatorColor: AppColors.accent.withValues(alpha: 0.16),
      indicatorShape: const StadiumBorder(),
      labelTextStyle: WidgetStateProperty.resolveWith((s) => GoogleFonts.instrumentSans(
            fontSize: 11.5,
            fontWeight: s.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
            color: s.contains(WidgetState.selected) ? AppColors.accent : AppColors.textDim,
          )),
      iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
            size: 23,
            color: s.contains(WidgetState.selected) ? AppColors.accent : AppColors.textDim,
          )),
    ),
    sliderTheme: const SliderThemeData(
      trackHeight: 3,
      activeTrackColor: AppColors.accent,
      inactiveTrackColor: AppColors.line,
      thumbColor: AppColors.text,
      overlayColor: Color(0x22FFB02E),
      overlayShape: RoundSliderOverlayShape(overlayRadius: SliderGeom.overlay),
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: SliderGeom.thumb, elevation: 0, pressedElevation: 0),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: AppColors.surfaceHi, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppColors.line)),
      textStyle: const TextStyle(color: AppColors.text, fontSize: 12.5),
    ),
    cardTheme: CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        side: const BorderSide(color: AppColors.line),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: AppColors.line,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet))),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.card)),
      titleTextStyle: display(18, weight: FontWeight.w600),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.surfaceHi,
      contentTextStyle: const TextStyle(color: AppColors.text),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.control)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: AppColors.surfaceHi,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.control),
        side: const BorderSide(color: AppColors.line),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surfaceHi,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.control), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.control),
        borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppColors.onAccent : AppColors.textDim),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppColors.accent : AppColors.surfaceHi),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: AppColors.accent, linearTrackColor: AppColors.line),
    dividerColor: AppColors.line,
    dividerTheme: const DividerThemeData(color: AppColors.line, space: 1, thickness: 1),
  );
}
