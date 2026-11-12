import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/pdf_brand.dart';
import '../../core/pdf_fonts.dart';
import '../../core/pdf_kit.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../company/company_model.dart';
import '../company/company_repository.dart';
import '../documents/document_widgets.dart';
import '../parties/parties_repository.dart';
import '../parties/party_model.dart';

/// What a PDF builder needs: the company, its brand (logo and colour) and
/// the Unicode theme.
class PdfContext {
  PdfContext(this.company, this.brand, this.theme, this._ref);

  final Company company;
  final PdfBrand brand;
  final pw.ThemeData? theme;
  final WidgetRef _ref;

  /// The party, or null when the user may not view parties or it fails.
  Future<Party?> party(String id) async {
    if (!_ref.read(permissionsProvider).can(Perm.partiesView)) return null;
    try {
      return await _ref.read(partiesRepositoryProvider).get(id);
    } catch (_) {
      return null;
    }
  }
}

Future<PdfContext> loadPdfContext(WidgetRef ref) async {
  Company? company;
  try {
    company = await ref.read(companyRepositoryProvider).get();
  } catch (_) {
    company = ref.read(sessionProvider).value?.company;
  }
  final co = company ?? const Company(id: '', name: 'Company', stateCode: '');
  final brand = await loadPdfBrand(ref.read(apiClientProvider), co);
  return PdfContext(co, brand, await pdfTheme(), ref);
}

/// "Print" and "Download PDF" actions for a document screen.
List<DocAction> pdfDocActions(
  BuildContext context,
  WidgetRef ref, {
  required String fileName,
  required Future<Uint8List> Function(PdfContext pdf) build,
}) {
  Future<void> run(bool print) async {
    try {
      final bytes = await build(await loadPdfContext(ref));
      if (print) {
        await Printing.layoutPdf(
          onLayout: (_) async => bytes,
          name: fileName,
          format: PdfPageFormat.a4,
        );
      } else {
        await Printing.sharePdf(bytes: bytes, filename: fileName);
      }
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  return [
    DocAction(
      label: 'Print',
      icon: Icons.print_outlined,
      onPressed: () => run(true),
    ),
    DocAction(
      label: 'Download PDF',
      icon: Icons.picture_as_pdf_outlined,
      onPressed: () => run(false),
    ),
  ];
}
