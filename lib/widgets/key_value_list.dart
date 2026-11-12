import 'package:flutter/material.dart';

import '../core/design_tokens.dart';

class KeyValue {
  const KeyValue(this.label, this.value, {this.widget});

  final String label;
  final String value;

  /// Replaces [value] when you need a chip or a link.
  final Widget? widget;
}

/// Label/value rows for detail pages. Side by side from 480 px, stacked below.
/// Empty values show an em dash.
class KeyValueList extends StatelessWidget {
  const KeyValueList({super.key, required this.items, this.labelWidth = 168});

  final List<KeyValue> items;
  final double labelWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final sideBySide = constraints.maxWidth >= 480;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, item) in items.indexed) ...[
              if (i > 0) Divider(height: 1, color: theme.dividerColor),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.sm + 2),
                child: sideBySide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: labelWidth,
                            child: Text(item.label, style: muted),
                          ),
                          Expanded(child: _value(theme, item)),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(item.label, style: muted),
                          const SizedBox(height: Space.xs),
                          _value(theme, item),
                        ],
                      ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _value(ThemeData theme, KeyValue item) =>
      item.widget ??
      Text(
        item.value.isEmpty ? '—' : item.value,
        style: theme.textTheme.bodyMedium,
      );
}
