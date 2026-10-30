import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_exception.dart';
import '../../core/json.dart';
import '../../core/money.dart';
import '../../widgets/busy.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../compliance/compliance_widgets.dart';
import '../compliance/tax_perms.dart';
import '../filings/filing_widgets.dart';
import 'gst_filing_models.dart';
import '../filings/filing_models.dart' show contractFy;
import 'gst_filing_repository.dart';
import 'ledger_payments.dart';
import 'setoff_view.dart';
import 'worksheet_view.dart';

/// `/gst-filing/:period`: the self-filing wizard for one GST period.
class GstFilingScreen extends ConsumerStatefulWidget {
  const GstFilingScreen({super.key, this.period});

  final String? period;

  @override
  ConsumerState<GstFilingScreen> createState() => _GstFilingScreenState();
}

class _GstFilingScreenState extends ConsumerState<GstFilingScreen> {
  String _split = 'cgst_first';

  String get _period => widget.period ?? previousMonth();

  @override
  Widget build(BuildContext context) {
    final manage = ref.watch(permissionsProvider).can(TaxPerm.gstManage);
    return DefaultTabController(
      length: 5,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'File GST',
            subtitle: 'Step by step, for the GST portal',
            actions: [
              OutlinedButton.icon(
                onPressed: () => context.go('/filings'),
                icon: const Icon(Icons.fact_check_outlined),
                label: const Text('Register'),
              ),
            ],
          ),
          FilterBar(
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                child: MonthPicker(
                  period: _period,
                  onChanged: (p) => context.go('/gst-filing/$p'),
                ),
              ),
            ],
          ),
          const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: '1 Checks'),
              Tab(text: '2 GSTR-1'),
              Tab(text: '3 Ledgers & set-off'),
              Tab(text: '4 GSTR-3B sheet'),
              Tab(text: '5 File 3B'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _ChecksTab(period: _period),
                _Gstr1Tab(period: _period, manage: manage),
                _SetoffTab(
                  period: _period,
                  split: _split,
                  manage: manage,
                  onSplit: (v) => setState(() => _split = v),
                ),
                _WorksheetTab(period: _period, split: _split),
                _File3bTab(period: _period, split: _split, manage: manage),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Widget _page(List<Widget> children) =>
    ListView(padding: const EdgeInsets.all(16), children: children);

class _ChecksTab extends ConsumerWidget {
  const _ChecksTab({required this.period});

  final String period;

  @override
  Widget build(BuildContext context, WidgetRef ref) => _page([
    for (final (code, title) in [
      ('gstr1', 'Before GSTR-1'),
      ('gstr3b', 'Before GSTR-3B'),
    ])
      SectionCard(
        title: title,
        child: AsyncValueView<PrefileResult>(
          value: ref.watch(prefileProvider((period, code))),
          onRetry: () => ref.invalidate(prefileProvider((period, code))),
          data: (r) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!r.canFile)
                const WarningsBanner([
                  'A check failed. Fix it, or record the return anyway later.',
                ], error: true),
              PrefileChecksList(checks: r.checks),
            ],
          ),
        ),
      ),
  ]);
}

class _Gstr1Tab extends ConsumerStatefulWidget {
  const _Gstr1Tab({required this.period, required this.manage});

  final String period;
  final bool manage;

  @override
  ConsumerState<_Gstr1Tab> createState() => _Gstr1TabState();
}

class _Gstr1TabState extends ConsumerState<_Gstr1Tab> {
  String? _sha;

  Future<void> _export() async {
    try {
      final text = await runBlocking(
        context,
        () => ref.read(gstFilingRepositoryProvider).gstr1Gstn(widget.period),
      );
      if (text == null || !mounted) return;
      setState(() => _sha = sha256.convert(utf8.encode(text)).toString());
      await shareText(context, text, 'GSTN JSON');
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => _page([
    SectionCard(
      title: 'GSTR-1 file',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Unofficial format. Check it with the GST offline tool before '
            'upload.',
          ),
          const SizedBox(height: 8),
          BusyButton(
            onPressed: _export,
            label: 'Export GSTN JSON',
            icon: Icons.ios_share,
          ),
          if (_sha != null) ...[
            const SizedBox(height: 12),
            const Text('SHA-256 of the exported text'),
            SelectableText(
              _sha!,
              key: const ValueKey('sha256'),
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ],
        ],
      ),
    ),
    SectionCard(
      title: 'On the GST portal',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (i, s) in const [
            'Log in at gst.gov.in and open Returns > Returns Dashboard.',
            'Choose the period and open GSTR-1, then Prepare Offline.',
            'Upload the JSON file and wait for the success message.',
            'Check the summary, generate it, then file with DSC or EVC.',
            'Keep the acknowledgement PDF and note the ARN.',
          ].indexed)
            Text('${i + 1}. $s'),
        ],
      ),
    ),
    if (widget.manage)
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.icon(
          onPressed: () => showMarkFiledDialog(
            context,
            ref,
            returnType: 'gstr1',
            period: widget.period,
            extra: {'exportSha256': ?_sha},
          ),
          icon: const Icon(Icons.check),
          label: const Text('Mark GSTR-1 filed'),
        ),
      ),
  ]);
}

class _SetoffTab extends ConsumerWidget {
  const _SetoffTab({
    required this.period,
    required this.split,
    required this.manage,
    required this.onSplit,
  });

  final String period;
  final String split;
  final bool manage;
  final ValueChanged<String> onSplit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = (period, split);
    return _page([
      SectionCard(child: LedgerSnapshotSection(canManage: manage)),
      SectionCard(
        child: AsyncValueView<Setoff>(
          value: ref.watch(setoffProvider(key)),
          onRetry: () => ref.invalidate(setoffProvider(key)),
          data: (s) => SetoffView(
            setoff: s,
            split: split,
            onSplit: onSplit,
            onRecordPayment: manage
                ? () => showGstPaymentDialog(
                    context,
                    ref,
                    period: period,
                    prefill: s.pmt06,
                    interest: s.pmt06Interest,
                    lateFee: s.pmt06LateFee,
                  )
                : null,
          ),
        ),
      ),
      SectionCard(
        child: GstPaymentsSection(
          fy: contractFy(_dateOf(period)),
          canManage: manage,
        ),
      ),
    ]);
  }
}

DateTime _dateOf(String period) {
  final p = period.split('-');
  return DateTime(
    int.tryParse(p.first) ?? DateTime.now().year,
    p.length > 1 ? int.tryParse(p[1]) ?? 1 : 1,
  );
}

class _WorksheetTab extends ConsumerWidget {
  const _WorksheetTab({required this.period, required this.split});

  final String period;
  final String split;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sheet = ref.watch(gstr3bSheetProvider(period));
    final setoff = ref.watch(setoffProvider((period, split))).value;
    return AsyncValueView<Gstr3bSheet>(
      value: sheet,
      onRetry: () => ref.invalidate(gstr3bSheetProvider(period)),
      data: (s) => _page([
        Row(
          children: [
            const Expanded(child: Text('Tables 3.1 to 6.1 of GSTR-3B')),
            UnverifiedBadge(s.unverified),
          ],
        ),
        WarningsBanner(s.warnings),
        WorksheetView(sheet: s, setoff: setoff),
      ]),
    );
  }
}

class _File3bTab extends ConsumerWidget {
  const _File3bTab({
    required this.period,
    required this.split,
    required this.manage,
  });

  final String period;
  final String split;
  final bool manage;

  /// `CASH_SHORTFALL`: show what is missing and offer the PMT-06 form.
  Future<bool> _shortfall(
    BuildContext context,
    WidgetRef ref,
    ApiException e,
  ) async {
    if (e.code != 'CASH_SHORTFALL') return false;
    final sf = asJsonOrNull(e.details['shortfall']) ?? const {};
    final heads = Heads.fromJson(sf);
    final interest = asDouble(sf['interest']);
    final lateFee = asDouble(sf['lateFee']);
    final total = heads.total + interest + lateFee;
    final pay = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Cash ledger is short'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Shortfall ${formatMoney(total)}'),
              for (final h in gstHeads)
                if (heads[h] > 0)
                  Text('${headLabel(h)}: ${formatMoney(heads[h])}'),
              if (interest > 0) Text('Interest: ${formatMoney(interest)}'),
              if (lateFee > 0) Text('Late fee: ${formatMoney(lateFee)}'),
              const SizedBox(height: 8),
              const Text(
                'Record the PMT-06 payment, then mark the return filed again.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Record payment'),
          ),
        ],
      ),
    );
    if (pay == true && context.mounted) {
      await showGstPaymentDialog(
        context,
        ref,
        period: period,
        prefill: heads,
        interest: interest,
        lateFee: lateFee,
      );
    }
    return true;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sheet = ref.watch(gstr3bSheetProvider(period));
    final setoff = ref.watch(setoffProvider((period, split)));
    return _page([
      AsyncValueView<Gstr3bSheet>(
        value: sheet,
        onRetry: () => ref.invalidate(gstr3bSheetProvider(period)),
        data: (s) {
          final f = s.filing;
          if (f != null && !f.cancelled) {
            return SectionCard(
              title: 'GSTR-3B filed',
              child: Text(
                'Filed on ${formatDate(f.filedOn)}'
                '${f.arn == null ? '' : ' · ${f.arn}'}. Cancel it in the '
                'filing register to record it again.',
              ),
            );
          }
          return SectionCard(
            title: 'Mark GSTR-3B filed',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Do this after you file on the portal. Progen records the '
                  'filing and posts the GST set-off in your books.',
                ),
                const SizedBox(height: 8),
                if (setoff.hasValue)
                  Text(
                    'Cash needed ${formatMoney(setoff.requireValue.cashTotal)}'
                    ' · IGST split ${split == 'cgst_first' ? 'CGST' : 'SGST'}'
                    ' first',
                  ),
                if (setoff.hasValue && setoff.requireValue.shortfallTotal > 0)
                  WarningsBanner([
                    'Cash shortfall '
                        '${formatMoney(setoff.requireValue.shortfallTotal)}. '
                        'Record a PMT-06 payment first.',
                  ], error: true),
                const SizedBox(height: 8),
                if (manage)
                  FilledButton.icon(
                    onPressed: () => showMarkFiledDialog(
                      context,
                      ref,
                      returnType: 'gstr3b',
                      period: period,
                      extra: {'postSetoff': true, 'igstSplit': split},
                      onError: (ctx, e) => _shortfall(ctx, ref, e),
                    ),
                    icon: const Icon(Icons.check),
                    label: const Text('Mark GSTR-3B filed'),
                  )
                else
                  const Text('You need GST manage access to record a filing.'),
              ],
            ),
          );
        },
      ),
    ]);
  }
}
