import 'package:flutter/material.dart';

import '../core/app_colors.dart';
import '../core/design_tokens.dart';

/// A small rounded square holding an icon on a tinted background; used on
/// section headers, list rows and empty states.
class IconBadge extends StatelessWidget {
  const IconBadge(
    this.icon, {
    super.key,
    this.tone = Accent.teal,
    this.size = 28,
  });

  final IconData icon;
  final Accent tone;
  final double size;

  @override
  Widget build(BuildContext context) {
    final pair = context.colors.accent(tone);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: pair.bg, borderRadius: Radii.mediumAll),
      child: Icon(icon, size: size * 0.57, color: pair.fg),
    );
  }
}
