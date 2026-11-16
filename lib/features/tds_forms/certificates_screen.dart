import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../../core/json.dart';
import '../../core/money.dart';
import '../../widgets/busy.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../compliance/compliance_widgets.dart' show recentFys;
import '../compliance/tax_perms.dart';
import 'cert_pdf.dart';
import 'tds_forms_repository.dart';
import 'tds_forms_widgets.dart';

/// `/tds-certificates`: Form 16 / 130 (salary) and Form 16A / 131 (others),
/// generated in bulk and downloaded as PDF.
class CertificatesScreen extends ConsumerStatefulWidget {
  const CertificatesScreen({super.key});

  @override
  ConsumerState<CertificatesScreen> createState() => _CertificatesScreenState();
}

class _CertificatesScreenState extends ConsumerState<CertificatesScreen> {
  String _kind = 'salary';
  late String _fy = recentFys().first;
  int _quarter = 1;

  CertQuery get _q => (_kind, _fy, _kind == 'salary' ? 0 : _quarter);

  Future<void> _generate() async {
    try {
      final res = await runBlocking(
        context,
        () => ref.read(tdsFormsRepositoryProvider).generate(_q.$1, _q.$2, _q.$3),
      );
      ref.invalidate(certificatesProvider(_q));
      if (mounted) {
        showInfoSnackBar(
          context,
          '${asInt(res?['count'])} certificates generated.',
        );
      }
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _pdf(List<Json> certs, String name) async {
    try {
      final bytes = await buildCertificatesPdf([
        for (final c in certs) asJson(c['snapshot']),
      ]);
      await Printing.sharePdf(bytes: bytes, filename: name);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final manage = ref.watch(permissionsProvider).can(TaxPerm.tdsManage);
    final certs = ref.watch(certificatesProvider(_q));
    final salary = _kind == 'salary';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeader(
          title: 'TDS certificates',
          subtitle: 'Form 16 and 16A (130 and 131 from April 2026)',
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'salary', label: Text('Salary')),
              ButtonSegment(value: 'non_salary', label: Text('Other payments')),
            ],
            selected: {_kind},
            onSelectionChanged: (s) => setState(() => _kind = s.first),
          ),
        ),
        PeriodBar(
          fy: _fy,
          onFy: (v) => setState(() => _fy = v),
          quarter: salary ? null : _quarter,
          onQuarter: (v) => setState(() => _quarter = v),
          trailing: [
            if (manage)
              FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: _generate,
                icon: const Icon(Icons.playlist_add_check_outlined),
                label: const Text('Generate for everyone'),
              ),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: certs.asData?.value.isNotEmpty == true
                  ? () => _pdf(
                      certs.asData!.value,
                      certFileName(_kind, _fy, salary ? null : 'Q$_quarter'),
                    )
                  : null,
              icon: const Icon(Icons.picture_as_pdf_outlined),
              label: const Text('Download all as PDF'),
            ),
          ],
        ),
        Expanded(
          child: AsyncValueView(
            value: certs,
            onRetry: () => ref.invalidate(certificatesProvider(_q)),
            data: (rows) => rows.isEmpty
                ? const EmptyView(
                    icon: Icons.description_outlined,
                    message:
                        'No certificates yet. Generate them after the TDS is '
                        'recorded and deposited.',
                  )
                : ListView(
                    children: [
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Text(
                          'These are working copies. The valid certificate is '
                          'the one downloaded from TRACES after the statement '
                          'is filed.',
                        ),
                      ),
                      for (final c in rows) _row(c),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  Widget _row(Json c) {
    final s = asJson(c['snapshot']);
    final who = asJson(s['employee'] ?? s['deductee']);
    final tds = s['totalDeducted'] ?? asJson(s['partA'])['totalDeducted'];
    final warnings = (s['warnings'] as List?)?.length ?? 0;
    return ListTile(
      minVerticalPadding: 8,
      title: Text(asString(who['name'])),
      subtitle: Text(
        '${asString(c['number'])}  |  PAN ${asString(who['pan'])}\n'
        'Tax ${formatMoney(asDouble(tds))}'
        '${warnings > 0 ? '  |  $warnings to check' : ''}',
      ),
      isThreeLine: true,
      trailing: IconButton(
        tooltip: 'Download PDF',
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        icon: const Icon(Icons.picture_as_pdf_outlined),
        onPressed: () => _pdf([
          c,
        ], certFileName(_kind, _fy, asString(who['name']))),
      ),
    );
  }
}
