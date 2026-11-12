import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'design_tokens.dart';

export 'app_colors.dart';
export 'design_tokens.dart';

/// Family name registered in pubspec.yaml (IBM Plex Sans, SIL OFL 1.1).
const String kFontFamily = 'IBMPlexSans';

abstract final class AppTheme {
  static ThemeData get light => _build(Brightness.light);
  static ThemeData get dark => _build(Brightness.dark);

  /// Denser controls for laptop-sized layouts. Wrap page content in
  /// `Theme(data: AppTheme.dense(theme), ...)`.
  static ThemeData dense(ThemeData base) {
    final dark = base.brightness == Brightness.dark;
    final scheme = base.colorScheme;
    final text = _text(
      scheme.onSurface,
      scheme.onSurfaceVariant,
      compact: true,
    );
    const compactButton = Size(64, 36);
    return base.copyWith(
      visualDensity: VisualDensity.compact,
      textTheme: text,
      primaryTextTheme: text,
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Space.md,
          vertical: 11,
        ),
        labelStyle: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        floatingLabelStyle: text.bodySmall?.copyWith(
          color: dark ? scheme.primary : scheme.onSurfaceVariant,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: base.filledButtonTheme.style?.copyWith(
          minimumSize: const WidgetStatePropertyAll(compactButton),
          textStyle: WidgetStatePropertyAll(text.labelLarge),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: base.elevatedButtonTheme.style?.copyWith(
          minimumSize: const WidgetStatePropertyAll(compactButton),
          textStyle: WidgetStatePropertyAll(text.labelLarge),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: base.outlinedButtonTheme.style?.copyWith(
          minimumSize: const WidgetStatePropertyAll(compactButton),
          textStyle: WidgetStatePropertyAll(text.labelLarge),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: base.textButtonTheme.style?.copyWith(
          minimumSize: const WidgetStatePropertyAll(Size(40, 34)),
          textStyle: WidgetStatePropertyAll(text.labelLarge),
        ),
      ),
      dataTableTheme: base.dataTableTheme.copyWith(
        dataRowMinHeight: 38,
        dataRowMaxHeight: 42,
        headingRowHeight: 36,
        horizontalMargin: Space.md,
        columnSpacing: Space.lg + 4,
        dataTextStyle: text.bodyMedium,
        headingTextStyle: text.labelMedium?.copyWith(
          fontWeight: FontWeight.w600,
          color: scheme.onSurfaceVariant,
          letterSpacing: 0.4,
        ),
      ),
    );
  }

  static const _lightScheme = ColorScheme(
    brightness: Brightness.light,
    primary: Color(0xFF0B6157),
    onPrimary: Color(0xFFFFFFFF),
    primaryContainer: Color(0xFFD7ECE7),
    onPrimaryContainer: Color(0xFF063B35),
    secondary: Color(0xFF475057),
    onSecondary: Color(0xFFFFFFFF),
    secondaryContainer: Color(0xFFE6EAEC),
    onSecondaryContainer: Color(0xFF21292D),
    tertiary: Color(0xFF1D5A9E),
    onTertiary: Color(0xFFFFFFFF),
    tertiaryContainer: Color(0xFFDDE9F7),
    onTertiaryContainer: Color(0xFF113A69),
    error: Color(0xFFB3261E),
    onError: Color(0xFFFFFFFF),
    errorContainer: Color(0xFFFBE3E0),
    onErrorContainer: Color(0xFF74140E),
    surface: Color(0xFFFFFFFF),
    onSurface: Color(0xFF1A2124),
    onSurfaceVariant: Color(0xFF55616A),
    outline: Color(0xFF8A949B),
    outlineVariant: Color(0xFFE1E4E8),
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
    inverseSurface: Color(0xFF2B2A27),
    onInverseSurface: Color(0xFFF6F5F2),
    inversePrimary: Color(0xFF5FC4B1),
    surfaceTint: Colors.transparent,
    surfaceDim: Color(0xFFE6E9EC),
    surfaceBright: Color(0xFFFFFFFF),
    surfaceContainerLowest: Color(0xFFFFFFFF),
    surfaceContainerLow: Color(0xFFFFFFFF),
    surfaceContainer: Color(0xFFF3F5F7),
    surfaceContainerHigh: Color(0xFFECEFF2),
    surfaceContainerHighest: Color(0xFFE4E8EB),
  );

  static const _darkScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: Color(0xFF5FC4B1),
    onPrimary: Color(0xFF04211C),
    primaryContainer: Color(0xFF0F3A34),
    onPrimaryContainer: Color(0xFFBFEAE1),
    secondary: Color(0xFFC4C0B7),
    onSecondary: Color(0xFF2B2A27),
    secondaryContainer: Color(0xFF2E2E2B),
    onSecondaryContainer: Color(0xFFE2DFD8),
    tertiary: Color(0xFF7DB4F0),
    onTertiary: Color(0xFF042748),
    tertiaryContainer: Color(0xFF173B63),
    onTertiaryContainer: Color(0xFFC6DDF8),
    error: Color(0xFFFF8F85),
    onError: Color(0xFF4A0905),
    errorContainer: Color(0xFF541A15),
    onErrorContainer: Color(0xFFFFC9C3),
    surface: Color(0xFF1A1A18),
    onSurface: Color(0xFFECEAE4),
    onSurfaceVariant: Color(0xFFA9A59C),
    outline: Color(0xFF77746C),
    outlineVariant: Color(0xFF302F2C),
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
    inverseSurface: Color(0xFFECEAE4),
    onInverseSurface: Color(0xFF2B2A27),
    inversePrimary: Color(0xFF0B6157),
    surfaceTint: Colors.transparent,
    surfaceDim: Color(0xFF121211),
    surfaceBright: Color(0xFF2A2A27),
    surfaceContainerLowest: Color(0xFF121211),
    surfaceContainerLow: Color(0xFF1A1A18),
    surfaceContainer: Color(0xFF1F1F1D),
    surfaceContainerHigh: Color(0xFF242422),
    surfaceContainerHighest: Color(0xFF2E2E2B),
  );

  static const _tabular = [FontFeature.tabularFigures()];

  static TextTheme _text(Color color, Color muted, {bool compact = false}) {
    TextStyle s(double size, FontWeight w, {double h = 1.4, double ls = 0}) =>
        TextStyle(
          fontFamily: kFontFamily,
          fontSize: size,
          fontWeight: w,
          height: h,
          letterSpacing: ls,
          color: color,
          fontFeatures: _tabular,
        );
    // Desktop ("compact") bodies are 13 px; phones keep 14 for legibility.
    final c = compact ? -1.0 : 0.0;
    return TextTheme(
      displayLarge: s(36, FontWeight.w600, h: 1.15, ls: -0.5),
      displayMedium: s(30, FontWeight.w600, h: 1.2, ls: -0.3),
      displaySmall: s(26, FontWeight.w600, h: 1.2, ls: -0.2),
      headlineLarge: s(24, FontWeight.w700, h: 1.25, ls: -0.2),
      headlineMedium: s(20, FontWeight.w700, h: 1.3, ls: -0.1),
      headlineSmall: s(19 + c, FontWeight.w700, h: 1.25, ls: -0.1),
      titleLarge: s(17 + c, FontWeight.w600, h: 1.3),
      // Also the dropdown value's style, which sits beside regular text fields.
      titleMedium: s(14 + (compact ? 0 : 1), FontWeight.w500, h: 1.3),
      titleSmall: s(13 + (compact ? 0 : 1), FontWeight.w600, h: 1.3),
      // 24 px is the height of a dense dropdown's line, which cannot be set.
      // Text fields use this style, so the two line up in a form row.
      bodyLarge: s(
        14 + (compact ? 0 : 1),
        FontWeight.w400,
        h: 24 / (14 + (compact ? 0 : 1)),
      ),
      bodyMedium: s(13 + (compact ? 0 : 1), FontWeight.w400, h: 1.4),
      bodySmall: s(
        11.5 + (compact ? 0 : 0.5),
        FontWeight.w400,
        h: 1.35,
      ).copyWith(color: muted),
      labelLarge: s(13 + (compact ? 0 : 1), FontWeight.w500, h: 1.3, ls: 0.1),
      labelMedium: s(
        11.5 + (compact ? 0 : 0.5),
        FontWeight.w500,
        h: 1.3,
        ls: 0.2,
      ),
      labelSmall: s(10.5, FontWeight.w500, h: 1.3, ls: 0.3),
    );
  }

  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = dark ? _darkScheme : _lightScheme;
    final colors = dark ? AppColors.dark : AppColors.light;
    final bg = dark ? const Color(0xFF111413) : const Color(0xFFEFF2F4);
    final text = _text(scheme.onSurface, scheme.onSurfaceVariant);
    final hairline = BorderSide(color: colors.hairline);
    final rMedium = RoundedRectangleBorder(borderRadius: Radii.mediumAll);
    const buttonPadding = EdgeInsets.symmetric(horizontal: Space.lg);
    const minSize = Size(64, Layout.touchTarget);

    OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
      borderRadius: Radii.mediumAll,
      borderSide: BorderSide(color: c, width: w),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: kFontFamily,
      textTheme: text,
      primaryTextTheme: text,
      scaffoldBackgroundColor: bg,
      canvasColor: scheme.surface,
      dividerColor: colors.hairline,
      visualDensity: VisualDensity.standard,
      splashFactory: InkRipple.splashFactory,
      extensions: [colors],
      dividerTheme: DividerThemeData(
        color: colors.hairline,
        thickness: 1,
        space: 1,
      ),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: colors.sidebar,
        foregroundColor: colors.onSidebar,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: text.titleMedium?.copyWith(color: colors.onSidebar),
        toolbarHeight: 52,
      ),
      cardTheme: CardThemeData(
        elevation: dark ? 0 : 0.6,
        shadowColor: const Color(0x33101E24),
        margin: EdgeInsets.zero,
        color: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: Radii.largeAll,
          side: hairline,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: minSize,
          padding: buttonPadding,
          shape: rMedium,
          textStyle: text.labelLarge,
          elevation: 0,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          minimumSize: minSize,
          padding: buttonPadding,
          shape: rMedium,
          textStyle: text.labelLarge,
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: minSize,
          padding: buttonPadding,
          shape: rMedium,
          textStyle: text.labelLarge,
          side: BorderSide(color: scheme.outline.withValues(alpha: 0.55)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 40),
          padding: const EdgeInsets.symmetric(horizontal: Space.md),
          shape: rMedium,
          textStyle: text.labelLarge,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          shape: rMedium,
          minimumSize: const Size(40, 40),
        ),
      ),
      iconTheme: IconThemeData(color: scheme.onSurfaceVariant, size: 20),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.onSurfaceVariant,
        shape: rMedium,
        minVerticalPadding: Space.sm,
      ),
      inputDecorationTheme: InputDecorationThemeData(
        filled: true,
        fillColor: scheme.surface,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Space.md,
          vertical: Space.md,
        ),
        border: border(scheme.outline.withValues(alpha: 0.6)),
        enabledBorder: border(scheme.outline.withValues(alpha: 0.6)),
        focusedBorder: border(scheme.primary, 2),
        errorBorder: border(scheme.error),
        focusedErrorBorder: border(scheme.error, 2),
        disabledBorder: border(colors.hairline),
        labelStyle: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        floatingLabelStyle: text.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        helperStyle: text.bodySmall,
        errorStyle: text.bodySmall?.copyWith(color: scheme.error),
        prefixIconColor: scheme.onSurfaceVariant,
        suffixIconColor: scheme.onSurfaceVariant,
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: Radii.smallAll,
          side: hairline,
        ),
        backgroundColor: scheme.surface,
        selectedColor: scheme.primaryContainer,
        labelStyle: text.labelMedium,
        side: hairline,
        padding: const EdgeInsets.symmetric(horizontal: Space.xs),
        showCheckmark: false,
      ),
      dataTableTheme: DataTableThemeData(
        headingTextStyle: text.labelMedium?.copyWith(
          fontWeight: FontWeight.w600,
          color: scheme.onSurfaceVariant,
          letterSpacing: 0.3,
        ),
        dataTextStyle: text.bodyMedium,
        headingRowColor: WidgetStatePropertyAll(scheme.surfaceContainer),
        dividerThickness: 1,
        horizontalMargin: Space.lg,
        columnSpacing: Space.xl,
        headingRowHeight: 40,
        dataRowMinHeight: 44,
        dataRowMaxHeight: 52,
      ),
      navigationDrawerTheme: NavigationDrawerThemeData(
        tileHeight: 38,
        indicatorSize: const Size(336, 38),
        indicatorShape: rMedium,
        backgroundColor: colors.sidebar,
        surfaceTintColor: Colors.transparent,
        indicatorColor: colors.sidebarSelected,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => text.labelLarge?.copyWith(
            color: states.contains(WidgetState.selected)
                ? colors.onSidebar
                : colors.onSidebar.withValues(alpha: 0.82),
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w400,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 20,
            color: states.contains(WidgetState.selected)
                ? colors.onSidebar
                : colors.onSidebarMuted,
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: Radii.largeAll,
          side: hairline,
        ),
        titleTextStyle: text.titleLarge,
        contentTextStyle: text.bodyMedium,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(Radii.large),
          ),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 4,
        shape: RoundedRectangleBorder(
          borderRadius: Radii.mediumAll,
          side: hairline,
        ),
        textStyle: text.bodyMedium,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: text.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
        actionTextColor: scheme.inversePrimary,
        shape: rMedium,
        elevation: 2,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: Radii.smallAll,
        ),
        textStyle: text.bodySmall?.copyWith(color: scheme.onInverseSurface),
        padding: const EdgeInsets.symmetric(
          horizontal: Space.sm,
          vertical: Space.xs,
        ),
        waitDuration: const Duration(milliseconds: 500),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: scheme.primary,
        unselectedLabelColor: scheme.onSurfaceVariant,
        labelStyle: text.labelLarge,
        unselectedLabelStyle: text.labelLarge,
        indicatorColor: scheme.primary,
        dividerColor: colors.hairline,
        indicatorSize: TabBarIndicatorSize.label,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(shape: rMedium),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: colors.hairline,
      ),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: Radii.smallAll),
      ),
    );
  }
}
