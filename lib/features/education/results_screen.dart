import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:printing/printing.dart';

import '../../core/pdf_brand.dart';
import '../../core/pdf_fonts.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../company/company_model.dart';
import '../company/company_repository.dart';
import 'education_widgets.dart';
import 'exam_data.dart';
import 'report_card_pdf.dart';

/// `/education/exams/:termId/:classId/results`: totals, grade and rank, and
/// report card PDFs for one student or the whole class.
class ResultsScreen extends ConsumerWidget {
  const ResultsScreen({super.key, required this.termId, required this.classId});
  final String termId;
  final String classId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = (termId: termId, classId: classId);
    return CGate(
      anyOf: const [
        Perm.educationExams,
        Perm.educationExamsManage,
        Perm.educationManage,
      ],
      child: AsyncValueView<ClassResults>(
        value: ref.watch(examResultsProvider(key)),
        onRetry: () => ref.invalidate(examResultsProvider(key)),
        data: (r) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageHeader(
              title: 'Results, ${r.label}',
              subtitle: r.locked
                  ? 'Published'
                  : 'Draft. Ranks change until the exam is published.',
              actions: [
                TextButton(
                  onPressed: () =>
                      context.go('/education/exams/$termId/$classId/marks'),
                  child: const Text('Marks'),
                ),
                FilledButton.icon(
                  key: const ValueKey('class-cards'),
                  onPressed: r.students.isEmpty
                      ? null
                      : () => _print(context, ref, null),
                  icon: const Icon(Icons.print_outlined),
                  label: const Text('Report cards, whole class'),
                ),
              ],
            ),
            Expanded(
              child: r.students.isEmpty
                  ? const EmptyView(
                      icon: Icons.groups_outlined,
                      message: 'No students in this class.',
                    )
                  : ListView(
                      padding: EdgeInsets.fromLTRB(
                        pageGutter(context),
                        0,
                        pageGutter(context),
                        24,
                      ),
                      children: [
                        for (final s in r.students) _row(context, ref, s),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, WidgetRef ref, StudentResult s) => Card(
    margin: const EdgeInsets.only(bottom: 6),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            child: Text(
              s.rank == null ? '-' : '#${s.rank}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.name),
                Text(
                  s.percentage == null
                      ? 'No marks yet'
                      : '${fmtMarks(s.total)} of ${fmtMarks(s.maxTotal)}, '
                            '${s.percentage!.toStringAsFixed(1)}%'
                            '${s.grade == null ? '' : ', grade ${s.grade}'}'
                            '${s.complete ? '' : ', marks missing'}',
                ),
                if (s.result != null)
                  Text(s.result == 'pass' ? 'Pass' : 'Needs improvement'),
              ],
            ),
          ),
          IconButton(
            key: ValueKey('card-${s.studentId}'),
            tooltip: 'Report card',
            onPressed: () => _print(context, ref, s),
            icon: const Icon(Icons.picture_as_pdf_outlined),
          ),
        ],
      ),
    ),
  );

  Future<void> _print(
    BuildContext context,
    WidgetRef ref,
    StudentResult? only,
  ) async {
    try {
      var cards = await ref.read(examRepositoryProvider).cards(termId, classId);
      if (only != null) {
        cards = [
          for (final c in cards)
            if (c.result.studentId == only.studentId) c,
        ];
      }
      Company? company;
      try {
        company = await ref.read(companyRepositoryProvider).get();
      } catch (_) {
        company = ref.read(sessionProvider).value?.company;
      }
      final brand = company == null
          ? null
          : await loadPdfBrand(ref.read(apiClientProvider), company);
      final bytes = await buildReportCardsPdf(
        cards,
        brand: brand,
        theme: await pdfTheme(),
      );
      await Printing.layoutPdf(
        onLayout: (_) async => Uint8List.fromList(bytes),
        name: reportCardFileName(
          cards.isEmpty ? 'exam' : cards.first.termName,
          only?.name,
        ),
        format: PdfPageFormat.a4,
      );
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }
}
