import 'package:flutter/widgets.dart';

/// Spacing scale. Use these, not literals.
abstract final class Space {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;
}

/// Corner radii. Deliberately small: the UI is flat and tool-like.
abstract final class Radii {
  static const double small = 3;
  static const double medium = 5;
  static const double large = 7;

  static const BorderRadius smallAll = BorderRadius.all(Radius.circular(small));
  static const BorderRadius mediumAll = BorderRadius.all(
    Radius.circular(medium),
  );
  static const BorderRadius largeAll = BorderRadius.all(Radius.circular(large));
}

/// Page padding and content widths.
abstract final class Layout {
  /// Screen width from which tables and forms use the denser desktop rhythm.
  static const double wide = 900;
  static const double pageGutterWide = 16;
  static const double pageGutterNarrow = 12;
  static const double contentMaxWidth = 1600;

  /// Forms and detail pages are never narrower than this on wide screens,
  /// whatever width a screen asks for.
  static const double formMinMaxWidth = 1200;

  /// Minimum touch target on phones.
  static const double touchTarget = 48;
}
