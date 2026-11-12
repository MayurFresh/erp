import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../../core/pdf_brand.dart';
import '../../core/pdf_fonts.dart';
import '../../core/providers.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../company/company_model.dart';
import '../company/company_repository.dart';
import 'rest_models.dart';
import 'rest_pdf.dart';
import 'rest_repository.dart';

/// Runs a write and shows the error as a snackbar when it fails.
Future<bool> restGuarded(
  BuildContext context,
  Future<void> Function() call,
) async {
  try {
    await call();
    return true;
  } catch (e) {
    if (context.mounted) showErrorSnackBar(context, e);
    return false;
  }
}

extension RestRefresh on WidgetRef {
  void bumpRest() => read(restRevisionProvider.notifier).bump();
}

/// The Indian food mark: a square outline with a dot (green veg, red
/// non-veg, amber egg).
class DietMark extends StatelessWidget {
  const DietMark(this.diet, {super.key, this.size = 16});

  final Diet diet;
  final double size;

  static const _veg = Color(0xFF1A7F4B);
  static const _nonVeg = Color(0xFFB42318);
  static const _egg = Color(0xFFB7791F);

  @override
  Widget build(BuildContext context) {
    final color = switch (diet) {
      Diet.veg => _veg,
      Diet.nonVeg => _nonVeg,
      Diet.egg => _egg,
    };
    return Semantics(
      label: diet.label,
      child: Container(
        width: size,
        height: size,
        padding: EdgeInsets.all(size * 0.2),
        decoration: BoxDecoration(
          border: Border.all(color: color, width: 1.5),
          borderRadius: BorderRadius.circular(2),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

/// "12 min" style age for tickets and tables.
String ageText(DateTime? since, {DateTime? now}) {
  if (since == null) return '';
  final mins = (now ?? DateTime.now()).difference(since).inMinutes;
  if (mins < 1) return 'now';
  if (mins < 60) return '$mins min';
  return '${mins ~/ 60} h ${mins % 60} min';
}

Future<Company> _company(WidgetRef ref) async {
  Company? company;
  try {
    company = await ref.read(companyRepositoryProvider).get();
  } catch (_) {
    company = ref.read(sessionProvider).value?.company;
  }
  return company ?? const Company(id: '', name: 'Company', stateCode: '');
}

/// Opens the print dialog for the bill of [order].
Future<void> printBill(
  BuildContext context,
  WidgetRef ref,
  RestOrder order,
) async {
  try {
    final co = await _company(ref);
    final bytes = await buildBillPdf(
      order,
      co,
      brand: await loadPdfBrand(ref.read(apiClientProvider), co),
      theme: await pdfTheme(),
    );
    await Printing.layoutPdf(
      onLayout: (_) async => Uint8List.fromList(bytes),
      name: billFileName(order),
      format: kRoll80,
    );
  } catch (e) {
    if (context.mounted) showErrorSnackBar(context, e);
  }
}

/// Opens the print dialog for each kitchen ticket in [kotIds].
Future<void> printKots(
  BuildContext context,
  WidgetRef ref,
  List<String> kotIds,
) async {
  try {
    final repo = ref.read(restaurantRepositoryProvider);
    final theme = await pdfTheme();
    for (final id in kotIds) {
      final kot = await repo.kot(id);
      final bytes = await buildKotPdf(kot, theme: theme);
      await Printing.layoutPdf(
        onLayout: (_) async => Uint8List.fromList(bytes),
        name: kotFileName(kot),
        format: kRoll80,
      );
    }
  } catch (e) {
    if (context.mounted) showErrorSnackBar(context, e);
  }
}

/// A coloured status pill used on tables, tickets and lines.
class StatusTag extends StatelessWidget {
  const StatusTag(this.label, {super.key, required this.bg, required this.fg});

  final String label;
  final Color bg, fg;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      label,
      style: Theme.of(
        context,
      ).textTheme.labelMedium?.copyWith(color: fg, fontWeight: FontWeight.w600),
    ),
  );
}
