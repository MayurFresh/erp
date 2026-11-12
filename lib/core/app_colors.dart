import 'package:flutter/material.dart';

/// Accent hues for icon badges and chips.
enum Accent { teal, amber, indigo, rose, sky }

/// Foreground (icon/text) over its tinted background.
@immutable
class AccentPair {
  const AccentPair(this.fg, this.bg);
  final Color fg, bg;
}

/// Semantic colours that Material's [ColorScheme] has no slot for.
/// Read with `context.colors`; screens should never hard-code colours.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.success,
    required this.onSuccess,
    required this.successContainer,
    required this.onSuccessContainer,
    required this.warning,
    required this.onWarning,
    required this.warningContainer,
    required this.onWarningContainer,
    required this.danger,
    required this.onDanger,
    required this.dangerContainer,
    required this.onDangerContainer,
    required this.info,
    required this.onInfo,
    required this.infoContainer,
    required this.onInfoContainer,
    required this.neutralContainer,
    required this.onNeutralContainer,
    required this.hairline,
    required this.sidebar,
    required this.onSidebar,
    required this.sidebarSelected,
    required this.onSidebarMuted,
    required this.accents,
  });

  final Color success, onSuccess, successContainer, onSuccessContainer;
  final Color warning, onWarning, warningContainer, onWarningContainer;
  final Color danger, onDanger, dangerContainer, onDangerContainer;
  final Color info, onInfo, infoContainer, onInfoContainer;
  final Color neutralContainer, onNeutralContainer;

  /// 1 px dividers and card borders.
  final Color hairline;

  /// Navigation sidebar surface.
  final Color sidebar, onSidebar, sidebarSelected;

  /// Section headings and idle icons on the sidebar.
  final Color onSidebarMuted;

  /// Semantic accent palette, indexed by [Accent].
  final List<AccentPair> accents;

  /// Foreground and tinted background for [tone], for icon badges and chips.
  AccentPair accent(Accent tone) => accents[tone.index];

  static const light = AppColors(
    success: Color(0xFF1A6E3F),
    onSuccess: Color(0xFFFFFFFF),
    successContainer: Color(0xFFDCF0E3),
    onSuccessContainer: Color(0xFF0E4527),
    warning: Color(0xFF8A5200),
    onWarning: Color(0xFFFFFFFF),
    warningContainer: Color(0xFFFAEBCB),
    onWarningContainer: Color(0xFF4F2E00),
    danger: Color(0xFFB3261E),
    onDanger: Color(0xFFFFFFFF),
    dangerContainer: Color(0xFFFBE3E0),
    onDangerContainer: Color(0xFF74140E),
    info: Color(0xFF1D5A9E),
    onInfo: Color(0xFFFFFFFF),
    infoContainer: Color(0xFFDDE9F7),
    onInfoContainer: Color(0xFF113A69),
    neutralContainer: Color(0xFFE6EAEC),
    onNeutralContainer: Color(0xFF3F4A50),
    hairline: Color(0xFFE1E4E8),
    sidebar: Color(0xFF0A3F39),
    onSidebar: Color(0xFFFFFFFF),
    sidebarSelected: Color(0xFF14574F),
    onSidebarMuted: Color(0xFF8FBDB5),
    accents: [
      AccentPair(Color(0xFF0B6157), Color(0xFFD7ECE7)),
      AccentPair(Color(0xFF9A5B00), Color(0xFFFBEBCB)),
      AccentPair(Color(0xFF3F4BB8), Color(0xFFE2E5F8)),
      AccentPair(Color(0xFFB4234A), Color(0xFFFBE1E8)),
      AccentPair(Color(0xFF0B76A6), Color(0xFFDCEFF8)),
    ],
  );

  static const dark = AppColors(
    success: Color(0xFF6FCB92),
    onSuccess: Color(0xFF05260F),
    successContainer: Color(0xFF163A25),
    onSuccessContainer: Color(0xFFBDEBCD),
    warning: Color(0xFFE5B04F),
    onWarning: Color(0xFF301D00),
    warningContainer: Color(0xFF45300A),
    onWarningContainer: Color(0xFFF6D9A0),
    danger: Color(0xFFFF8F85),
    onDanger: Color(0xFF4A0905),
    dangerContainer: Color(0xFF541A15),
    onDangerContainer: Color(0xFFFFC9C3),
    info: Color(0xFF7DB4F0),
    onInfo: Color(0xFF042748),
    infoContainer: Color(0xFF173B63),
    onInfoContainer: Color(0xFFC6DDF8),
    neutralContainer: Color(0xFF2E2E2B),
    onNeutralContainer: Color(0xFFC4C0B7),
    hairline: Color(0xFF2C2F2E),
    sidebar: Color(0xFF0B2A26),
    onSidebar: Color(0xFFFFFFFF),
    sidebarSelected: Color(0xFF14463F),
    onSidebarMuted: Color(0xFF7FAAA2),
    accents: [
      AccentPair(Color(0xFF5FC4B1), Color(0xFF0F3A34)),
      AccentPair(Color(0xFFE5B04F), Color(0xFF45300A)),
      AccentPair(Color(0xFF9EA8F2), Color(0xFF242A5C)),
      AccentPair(Color(0xFFF08AA6), Color(0xFF55192C)),
      AccentPair(Color(0xFF7CC4EA), Color(0xFF123B52)),
    ],
  );

  @override
  AppColors copyWith() => this;

  @override
  AppColors lerp(AppColors? other, double t) =>
      t < 0.5 ? this : (other ?? this);
}

extension AppColorsContext on BuildContext {
  AppColors get colors {
    final theme = Theme.of(this);
    return theme.extension<AppColors>() ??
        (theme.brightness == Brightness.dark
            ? AppColors.dark
            : AppColors.light);
  }
}

/// Typography helpers that need the theme.
extension AppTextContext on BuildContext {
  /// Tabular figures for amounts and quantities.
  TextStyle get amountStyle =>
      (Theme.of(this).textTheme.bodyMedium ?? const TextStyle()).copyWith(
        fontFeatures: const [FontFeature.tabularFigures()],
        fontWeight: FontWeight.w500,
      );
}
