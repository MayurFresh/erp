import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/app_colors.dart';
import '../../core/money.dart';
import '../../core/pdf_brand.dart';
import '../../core/pdf_fonts.dart';
import '../../core/pdf_kit.dart' show PdfBrand;
import '../../core/providers.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../company/company_model.dart';
import '../company/company_repository.dart';
import '../compliance/compliance_widgets.dart' show recentFys;
import 'funds_models.dart';

/// Budget bar: spent in the solid colour, committed lighter, over-budget in red.
class BudgetBar extends StatelessWidget {
  const BudgetBar({super.key, required this.head, this.compact = false});

  final HeadRow head;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final scheme = Theme.of(context).colorScheme;
    final budget = head.budget;
    final over = head.actual + head.committed > budget + 0.004;
    double share(double v) =>
        budget <= 0 ? (v > 0 ? 1 : 0) : (v / budget).clamp(0, 1).toDouble();
    final spent = share(head.actual);
    final withCommitted = share(head.actual + head.committed);
    final base = over ? c.danger : scheme.primary;
    return Semantics(
      label:
          '${head.name}: ${head.percentUsed.toStringAsFixed(0)} percent spent',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  head.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${formatPercent(head.percentCommitted)} used',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: over ? c.danger : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: SizedBox(
              height: compact ? 6 : 8,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ColoredBox(color: scheme.surfaceContainerHighest),
                  ),
                  FractionallySizedBox(
                    widthFactor: withCommitted,
                    child: ColoredBox(color: base.withValues(alpha: 0.35)),
                  ),
                  FractionallySizedBox(
                    widthFactor: spent,
                    child: ColoredBox(color: base),
                  ),
                ],
              ),
            ),
          ),
          if (!compact) ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: 14,
              runSpacing: 2,
              children: [
                Text(
                  'Budget ${formatAmount(head.budget)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  'Spent ${formatAmount(head.actual)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (head.committed > 0)
                  Text(
                    'Committed ${formatAmount(head.committed)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                Text(
                  'Available ${formatAmount(head.available)}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: head.available < 0 ? c.danger : null,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// A figure with a small label above it.
class Figure extends StatelessWidget {
  const Figure(this.label, this.value, {super.key, this.warn = false});

  final String label;
  final String value;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: t.labelMedium),
        const SizedBox(height: 2),
        Text(
          value,
          style: t.titleMedium?.copyWith(
            color: warn ? context.colors.danger : null,
          ),
        ),
      ],
    );
  }
}

/// A row of figures that wraps on narrow screens.
class FigureRow extends StatelessWidget {
  const FigureRow(this.figures, {super.key});

  final List<Figure> figures;

  @override
  Widget build(BuildContext context) =>
      Wrap(spacing: 28, runSpacing: 10, children: figures);
}

class FySelector extends StatelessWidget {
  const FySelector({
    super.key,
    required this.value,
    required this.onChanged,
    this.extra = const [],
  });

  final String value;
  final ValueChanged<String> onChanged;
  final List<String> extra;

  @override
  Widget build(BuildContext context) {
    final years = {...recentFys(), ...extra, value}.toList()
      ..sort((a, b) => b.compareTo(a));
    return SizedBox(
      width: 150,
      child: DropdownButtonFormField<String>(
        key: ValueKey('fy-$value'),
        initialValue: value,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Financial year'),
        items: [
          for (final y in years) DropdownMenuItem(value: y, child: Text(y)),
        ],
        onChanged: (v) => v == null ? null : onChanged(v),
      ),
    );
  }
}

String currentFy([DateTime? now]) => recentFys(now).first;

/// Page body with the usual gutter.
class Gutter extends StatelessWidget {
  const Gutter({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ListView(
    padding: EdgeInsets.fromLTRB(
      pageGutter(context),
      0,
      pageGutter(context),
      24,
    ),
    children: [
      for (final c in children)
        Padding(padding: const EdgeInsets.only(bottom: 10), child: c),
    ],
  );
}

class SoftNote extends StatelessWidget {
  const SoftNote(this.text, {super.key, this.danger = false});

  final String text;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: danger ? c.dangerContainer : c.warningContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: danger ? c.onDangerContainer : c.onWarningContainer,
        ),
      ),
    );
  }
}

/// Shows each warning from a save as one message; returns after the first is shown.
void showWarnings(BuildContext context, List<String> warnings) {
  if (warnings.isEmpty) return;
  showInfoSnackBar(context, warnings.join('\n'));
}

/// Builds the print dialog for a finished PDF, with the company's brand and fonts loaded by the caller.
Future<(PdfBrand?, pw.ThemeData?)> loadBrandAndTheme(WidgetRef ref) async {
  Company? company;
  try {
    company = await ref.read(companyRepositoryProvider).get();
  } catch (_) {
    company = ref.read(sessionProvider).value?.company;
  }
  final brand = company == null
      ? null
      : await loadPdfBrand(ref.read(apiClientProvider), company);
  return (brand, await pdfTheme());
}

Future<void> printBytes(
  Uint8List bytes,
  String name, {
  PdfPageFormat format = PdfPageFormat.a4,
}) => Printing.layoutPdf(
  onLayout: (_) async => bytes,
  name: name,
  format: format,
);

String sentence(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1).replaceAll('_', ' ');

class EmptyNote extends StatelessWidget {
  const EmptyNote(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) =>
      EmptyView(icon: Icons.inbox_outlined, message: message);
}
