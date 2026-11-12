import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_colors.dart';
import '../../core/design_tokens.dart';
import '../../widgets/layout.dart';
import '../manufacturing/mfg_widgets.dart' show MfgLocationField, mfgGuarded;
import '../auth/session.dart';
import 'wh_repository.dart';

export '../manufacturing/mfg_widgets.dart'
    show MfgInputError, mfgGuarded, mfgNumberField, mfgToast;

extension WhRefresh on WidgetRef {
  void bumpWh() => read(whRevisionProvider.notifier).bump();

  bool whCan(String permission) =>
      watch(sessionProvider).value?.permissions.can(permission) ?? false;
}

Future<bool> whGuarded(BuildContext context, Future<void> Function() call) =>
    mfgGuarded(context, call);

/// Location chooser shared by the warehouse screens.
class WhLocationBar extends ConsumerWidget {
  const WhLocationBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = ref.watch(whLocationIdProvider);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: MfgLocationField(
        key: ValueKey('loc-$id'),
        value: id,
        onChanged: (v) => ref.read(whLocationChoiceProvider.notifier).set(v),
      ),
    );
  }
}

/// A column of a [WhTable].
class WhCol<T> {
  const WhCol(this.title, this.cell, {this.flex = 1, this.end = false});

  final String title;
  final String Function(T row) cell;
  final int flex;
  final bool end;
}

/// Cards on phones, a table on wide screens.
class WhTable<T> extends StatelessWidget {
  const WhTable({
    super.key,
    required this.rows,
    required this.columns,
    required this.card,
    this.onTap,
    this.breakpoint = 720,
  });

  final List<T> rows;
  final List<WhCol<T>> columns;
  final Widget Function(BuildContext context, T row) card;
  final void Function(T row)? onTap;
  final double breakpoint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gutter = pageGutter(context);
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth < breakpoint) {
          return ListView.separated(
            padding: EdgeInsets.fromLTRB(gutter, 0, gutter, Space.xxl),
            itemCount: rows.length,
            separatorBuilder: (_, _) => const SizedBox(height: Space.sm),
            itemBuilder: (context, i) => Material(
              color: theme.colorScheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: Radii.mediumAll,
                side: BorderSide(color: context.colors.hairline),
              ),
              child: InkWell(
                borderRadius: Radii.mediumAll,
                onTap: onTap == null ? null : () => onTap!(rows[i]),
                child: Padding(
                  padding: const EdgeInsets.all(Space.md),
                  child: card(context, rows[i]),
                ),
              ),
            ),
          );
        }
        Widget cellText(String text, WhCol<T> col, {bool head = false}) =>
            Expanded(
              flex: col.flex,
              child: Text(
                text,
                textAlign: col.end ? TextAlign.end : TextAlign.start,
                overflow: TextOverflow.ellipsis,
                style: head
                    ? theme.textTheme.labelMedium
                    : theme.textTheme.bodyMedium,
              ),
            );
        return ListView(
          padding: EdgeInsets.fromLTRB(gutter, 0, gutter, Space.xxl),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                vertical: Space.sm,
                horizontal: Space.md,
              ),
              child: Row(
                children: [
                  for (final col in columns)
                    cellText(col.title, col, head: true),
                ],
              ),
            ),
            const Divider(height: 1),
            for (final r in rows) ...[
              InkWell(
                onTap: onTap == null ? null : () => onTap!(r),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: Space.sm + 2,
                    horizontal: Space.md,
                  ),
                  child: Row(
                    children: [
                      for (final col in columns) cellText(col.cell(r), col),
                    ],
                  ),
                ),
              ),
              const Divider(height: 1),
            ],
          ],
        );
      },
    );
  }
}

/// Two-line card body: bold title, then grey lines.
Widget whCardBody(
  BuildContext context,
  String title,
  List<String> lines, {
  Widget? trailing,
}) {
  final theme = Theme.of(context);
  return Row(
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleSmall),
            for (final l in lines.where((l) => l.isNotEmpty))
              Text(l, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
      if (trailing != null) ...[const SizedBox(width: Space.sm), trailing],
    ],
  );
}

/// Parses `yyyy-mm-dd`; blank is allowed.
String? whDateError(String? v) {
  final t = v?.trim() ?? '';
  if (t.isEmpty) return null;
  return RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(t) &&
          DateTime.tryParse(t) != null
      ? null
      : 'Use YYYY-MM-DD';
}
