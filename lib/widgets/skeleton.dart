import 'package:flutter/material.dart';

import '../core/app_colors.dart';
import '../core/design_tokens.dart';

/// Pulsing placeholder block. Stops pulsing when the platform asks for
/// reduced motion.
class Skeleton extends StatefulWidget {
  const Skeleton({super.key, this.width, this.height = 14});

  final double? width;
  final double height;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat(reverse: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final base = context.colors.neutralContainer;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: base.withValues(alpha: 0.55 + 0.45 * _c.value),
          borderRadius: Radii.smallAll,
        ),
      ),
    );
  }
}

/// List-shaped skeleton: a title line and a shorter detail line per row.
class SkeletonList extends StatelessWidget {
  const SkeletonList({super.key, this.rows = 6, this.padding});

  final int rows;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Loading',
    child: ExcludeSemantics(
      child: Padding(
        padding: padding ?? const EdgeInsets.all(Space.lg),
        child: Column(
          children: [
            for (var i = 0; i < rows; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.md),
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const FractionallySizedBox(
                            widthFactor: 0.7,
                            child: Skeleton(height: 14),
                          ),
                          const SizedBox(height: Space.sm),
                          FractionallySizedBox(
                            widthFactor: 0.4 + (i % 3) * 0.1,
                            child: const Skeleton(height: 10),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: Space.lg),
                    const Skeleton(width: 72, height: 14),
                  ],
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
