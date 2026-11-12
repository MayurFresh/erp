import 'package:flutter/material.dart';

import '../core/app_colors.dart';
import '../core/design_tokens.dart';
import 'status_chip.dart';

class TimelineEvent {
  const TimelineEvent({
    required this.title,
    this.detail,
    this.when,
    this.tone = StatusTone.neutral,
  });

  final String title;
  final String? detail;

  /// Already formatted, e.g. `21 Oct 2026, 04:10 PM`.
  final String? when;
  final StatusTone tone;
}

/// Vertical list of events joined by a hairline, newest first.
class ActivityTimeline extends StatelessWidget {
  const ActivityTimeline({super.key, required this.events});

  final List<TimelineEvent> events;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, e) in events.indexed)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 20,
                  child: Column(
                    children: [
                      const SizedBox(height: 6),
                      Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          color: e.tone == StatusTone.neutral
                              ? theme.colorScheme.surface
                              : colors.toneAccent(e.tone),
                          border: Border.all(
                            color: colors.toneAccent(e.tone),
                            width: 1.5,
                          ),
                          shape: BoxShape.circle,
                        ),
                      ),
                      if (i < events.length - 1)
                        Expanded(
                          child: Container(width: 1, color: colors.hairline),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: Space.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(e.title, style: theme.textTheme.bodyMedium),
                        if (e.detail != null)
                          Text(e.detail!, style: theme.textTheme.bodySmall),
                        if (e.when != null)
                          Text(e.when!, style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
