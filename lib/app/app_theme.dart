import 'package:flutter/material.dart';

@immutable
class ShellyColors extends ThemeExtension<ShellyColors> {
  const ShellyColors({
    required this.page,
    required this.background,
    required this.surface,
    required this.surface2,
    required this.surface3,
    required this.elevated,
    required this.onSurface,
    required this.onSurface2,
    required this.onSurface3,
    required this.line,
    required this.line2,
    required this.primary,
    required this.onPrimary,
    required this.terminalOutput,
    required this.scrim,
  });

  final Color page;
  final Color background;
  final Color surface;
  final Color surface2;
  final Color surface3;
  final Color elevated;
  final Color onSurface;
  final Color onSurface2;
  final Color onSurface3;
  final Color line;
  final Color line2;
  final Color primary;
  final Color onPrimary;
  final Color terminalOutput;
  final Color scrim;

  static const light = ShellyColors(
    page: Color(0xFFE9E9E6),
    background: Color(0xFFF3F3F1),
    surface: Color(0xFFFBFBF9),
    surface2: Color(0xFFE8E8E5),
    surface3: Color(0xFFDCDCD8),
    elevated: Color(0xFFFDFDFC),
    onSurface: Color(0xFF1B1C1E),
    onSurface2: Color(0xFF5D6165),
    onSurface3: Color(0xFF989C9F),
    line: Color(0xFFE2E2DE),
    line2: Color(0xFFC8C8C3),
    primary: Color(0xFF1B1C1E),
    onPrimary: Color(0xFFF4F4F2),
    terminalOutput: Color(0xFF45484C),
    scrim: Color(0x6B0F0F0F),
  );

  static const dark = ShellyColors(
    page: Color(0xFF030303),
    background: Color(0xFF0B0B0B),
    surface: Color(0xFF161616),
    surface2: Color(0xFF212121),
    surface3: Color(0xFF2E2E2E),
    elevated: Color(0xFF1A1A1A),
    onSurface: Color(0xFFE7E7E5),
    onSurface2: Color(0xFFA0A2A4),
    onSurface3: Color(0xFF636568),
    line: Color(0xFF232323),
    line2: Color(0xFF3A3A3A),
    primary: Color(0xFFE7E7E5),
    onPrimary: Color(0xFF161616),
    terminalOutput: Color(0xFFADAFB1),
    scrim: Color(0x9E000000),
  );

  @override
  ShellyColors copyWith() => this;

  @override
  ShellyColors lerp(covariant ShellyColors? other, double t) {
    return other ?? this;
  }
}

extension ShellyThemeContext on BuildContext {
  ShellyColors get shelly => Theme.of(this).extension<ShellyColors>()!;
}

abstract final class ShellyTheme {
  static ThemeData light() => _theme(Brightness.light, ShellyColors.light);

  static ThemeData dark() => _theme(Brightness.dark, ShellyColors.dark);

  static ThemeData _theme(Brightness brightness, ShellyColors colors) {
    final colorScheme =
        ColorScheme.fromSeed(
          seedColor: colors.primary,
          brightness: brightness,
          surface: colors.background,
        ).copyWith(
          primary: colors.primary,
          onPrimary: colors.onPrimary,
          surface: colors.background,
          onSurface: colors.onSurface,
          outline: colors.line2,
          outlineVariant: colors.line,
          scrim: colors.scrim,
        );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colors.background,
      splashFactory: InkRipple.splashFactory,
      extensions: [colors],
      textTheme: ThemeData(brightness: brightness).textTheme.apply(
        bodyColor: colors.onSurface,
        displayColor: colors.onSurface,
      ),
      iconTheme: IconThemeData(color: colors.onSurface, size: 21),
      dividerColor: colors.line,
      dialogTheme: DialogThemeData(
        backgroundColor: colors.elevated,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colors.elevated,
        modalBackgroundColor: colors.elevated,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: colors.primary,
        contentTextStyle: TextStyle(color: colors.onPrimary),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }
}
