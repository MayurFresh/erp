import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';

import '../../../core/design_tokens.dart';
import '../../../core/providers.dart';
import '../../../widgets/layout.dart';
import '../../../widgets/states.dart';
import '../../auth/session.dart';
import '../../construction/models/project_models.dart';
import '../../insights/analytics_repository.dart';
import '../../insights/analytics_widgets.dart';
import '../../insights/insights_rules.dart';
import '../pdf_actions.dart';
import '../report_models.dart' show StockValuationRow;
import '../report_period.dart';
import '../reports_repository.dart';
import 'client_report_model.dart';
import 'client_report_pdf.dart';

/// `/reports/client-report`: choose a period and what to include, then
/// preview, download or share a branded PDF report or slides.
class ClientReportScreen extends ConsumerStatefulWidget {
  const ClientReportScreen({super.key});

  @override
  ConsumerState<ClientReportScreen> createState() => _ClientReportState();
}

class _ClientReportState extends ConsumerState<ClientReportScreen> {
  RangePreset? _preset = RangePreset.fyToDate;
  DateRange _range = RangePreset.fyToDate.resolve();
  Set<ReportSection>? _chosen;
  bool _slides = false;
  final _recipient = TextEditingController();
  final _by = TextEditingController();
  final _notes = TextEditingController();
  Future<Uint8List>? _pdf;
  bool _building = false;
  String? _error;

  @override
  void dispose() {
    _recipient.dispose();
    _by.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(DateTime.now().year + 1, 12, 31),
      initialDateRange: DateTimeRange(start: _range.from, end: _range.to),
    );
    if (picked == null) return;
    setState(() {
      _preset = null;
      _range = DateRange(picked.start, picked.end);
      _pdf = null;
    });
  }

  Future<Uint8List> _build(Set<ReportSection> sections) async {
    final perms = ref.read(permissionsProvider);
    final a = await ref.read(analyticsProvider(_range).future);
    final pdf = await loadPdfContext(ref);
    var rows = <StockValuationRow>[];
    double? stockTotal;
    if (sections.contains(ReportSection.stock)) {
      try {
        final v = await ref.read(reportsRepositoryProvider).stockValuation();
        rows = v.rows;
        stockTotal = v.totalValue;
      } catch (_) {}
    }
    var projects = <Project>[];
    if (sections.contains(ReportSection.projects)) {
      try {
        projects =
            (await ref
                    .read(apiClientProvider)
                    .getPage(
                      '/projects',
                      Project.fromJson,
                      query: {'limit': 100},
                    ))
                .data;
      } catch (_) {}
    }
    final allowed = availableSections(
      a,
      canSeeProjects: perms.can('projects.view'),
    );
    final input = ClientReportInput(
      brand: pdf.brand,
      theme: pdf.theme,
      analytics: a,
      sections: sections.intersection(allowed),
      takeaways: buildTakeaways(a, limit: 6),
      periodLabel: _range.label.replaceAll('–', 'to'),
      generatedOn: DateFormat('d MMM y').format(DateTime.now()),
      recipient: _recipient.text,
      preparedBy: _by.text,
      notes: _notes.text,
      stockRows: rows,
      stockTotal: stockTotal,
      projects: projects,
    );
    return buildClientReportPdf(input, slides: _slides);
  }

  Future<void> _generate(Set<ReportSection> sections) async {
    setState(() {
      _building = true;
      _error = null;
    });
    try {
      final bytes = await _build(sections);
      if (!mounted) return;
      setState(() => _pdf = Future.value(bytes));
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not build the report: $e');
    } finally {
      if (mounted) setState(() => _building = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    final value = ref.watch(analyticsProvider(_range));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(title: 'Client report', subtitle: _range.label),
        Expanded(
          child: AsyncValueView(
            value: value,
            onRetry: () => ref.invalidate(analyticsProvider(_range)),
            data: (a) {
              final avail = availableSections(
                a,
                canSeeProjects: perms.can('projects.view'),
              );
              final chosen = (_chosen ?? avail).intersection(avail);
              return ListView(
                padding: const EdgeInsets.fromLTRB(
                  Space.lg,
                  0,
                  Space.lg,
                  Space.xl,
                ),
                children: [
                  _options(avail, chosen),
                  const SizedBox(height: Space.lg),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Space.md),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  if (_pdf != null)
                    FutureBuilder<Uint8List>(
                      future: _pdf,
                      builder: (context, snap) {
                        if (!snap.hasData) return const SizedBox();
                        return _preview(snap.data!);
                      },
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _preview(Uint8List bytes) {
    final name = 'business-report-${_range.apiFrom}-to-${_range.apiTo}.pdf';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: Space.sm,
          children: [
            FilledButton.icon(
              onPressed: () => Printing.sharePdf(bytes: bytes, filename: name),
              icon: const Icon(Icons.download_outlined),
              label: const Text('Download or share PDF'),
            ),
            OutlinedButton.icon(
              onPressed: () => Printing.layoutPdf(onLayout: (_) => bytes),
              icon: const Icon(Icons.print_outlined),
              label: const Text('Print'),
            ),
          ],
        ),
        const SizedBox(height: Space.md),
        SizedBox(
          height: 640,
          child: PdfPreview(
            build: (_) => bytes,
            canChangeOrientation: false,
            canChangePageFormat: false,
            canDebug: false,
            useActions: false,
            pdfFileName: name,
          ),
        ),
      ],
    );
  }

  Widget _options(Set<ReportSection> avail, Set<ReportSection> chosen) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Period', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: Space.sm),
            Wrap(
              spacing: Space.sm,
              runSpacing: Space.sm,
              children: [
                for (final p in kAnalyticsPresets)
                  ChoiceChip(
                    label: Text(p.label),
                    selected: p == _preset,
                    onSelected: (_) => setState(() {
                      _preset = p;
                      _range = p.resolve();
                      _pdf = null;
                    }),
                  ),
                ActionChip(
                  avatar: const Icon(Icons.edit_calendar_outlined, size: 18),
                  label: Text(_preset == null ? _range.label : 'Custom'),
                  onPressed: _pick,
                ),
              ],
            ),
            const SizedBox(height: Space.lg),
            const Text(
              'Include',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            Wrap(
              spacing: Space.sm,
              children: [
                for (final s in ReportSection.values)
                  if (avail.contains(s))
                    FilterChip(
                      label: Text(s.label),
                      selected: chosen.contains(s),
                      onSelected: (on) => setState(() {
                        final next = {...chosen};
                        on ? next.add(s) : next.remove(s);
                        _chosen = next;
                        _pdf = null;
                      }),
                    ),
              ],
            ),
            const SizedBox(height: Space.lg),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: false,
                  icon: Icon(Icons.description_outlined),
                  label: Text('Report (A4)'),
                ),
                ButtonSegment(
                  value: true,
                  icon: Icon(Icons.slideshow_outlined),
                  label: Text('Slides'),
                ),
              ],
              selected: {_slides},
              onSelectionChanged: (v) => setState(() {
                _slides = v.first;
                _pdf = null;
              }),
            ),
            const SizedBox(height: Space.lg),
            Wrap(
              spacing: Space.md,
              runSpacing: Space.md,
              children: [
                SizedBox(
                  width: 260,
                  child: TextField(
                    controller: _recipient,
                    decoration: const InputDecoration(
                      labelText: 'Prepared for (client name)',
                    ),
                  ),
                ),
                SizedBox(
                  width: 260,
                  child: TextField(
                    controller: _by,
                    decoration: const InputDecoration(labelText: 'Prepared by'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Space.md),
            TextField(
              controller: _notes,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'Notes to include (optional)',
              ),
            ),
            const SizedBox(height: Space.lg),
            FilledButton.icon(
              onPressed: _building || chosen.isEmpty
                  ? null
                  : () => _generate(chosen),
              icon: _building
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.description_outlined),
              label: Text(_building ? 'Building...' : 'Build report'),
            ),
          ],
        ),
      ),
    );
  }
}
