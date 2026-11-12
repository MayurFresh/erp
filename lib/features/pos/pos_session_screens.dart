import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:printing/printing.dart';

import '../../core/api_exception.dart';
import '../../core/app_colors.dart';
import '../../core/design_tokens.dart';
import '../../core/json.dart';
import '../../core/money.dart';
import '../../core/number_input.dart';
import '../../core/pdf_brand.dart';
import '../../core/pdf_fonts.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../company/company_model.dart';
import '../company/company_repository.dart';
import '../locations/location_model.dart';
import '../locations/locations_repository.dart';
import 'pos_models.dart';
import 'pos_receipt_pdf.dart';
import 'pos_repository.dart';

/// Shown instead of the counter while the user has no open session.
class OpenSessionView extends ConsumerStatefulWidget {
  const OpenSessionView({super.key});

  @override
  ConsumerState<OpenSessionView> createState() => _OpenSessionViewState();
}

class _OpenSessionViewState extends ConsumerState<OpenSessionView> {
  String? _locationId;
  final _float = TextEditingController(text: '0');
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _float.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    final id = _locationId;
    if (id == null || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(posRepositoryProvider)
          .openSession(id, parseIndianNumber(_float.text) ?? 0);
      ref.read(posRevisionProvider(PosKind.session).notifier).bump();
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = errorMessage(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final locations = ref.watch(locationsLookupProvider);
    return AsyncValueView<List<Location>>(
      value: locations,
      onRetry: () => ref.invalidate(locationsLookupProvider),
      data: (all) {
        final list = all.where((l) => l.isActive).toList();
        _locationId ??= list.length == 1 ? list.first.id : null;
        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Space.lg),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Open the register',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: Space.xs),
                  const Text(
                    'Count the cash in the drawer and enter it as the opening float.',
                  ),
                  const SizedBox(height: Space.lg),
                  DropdownButtonFormField<String>(
                    key: const Key('open-location'),
                    initialValue: _locationId,
                    decoration: const InputDecoration(
                      labelText: 'Counter or shop',
                    ),
                    items: [
                      for (final l in list)
                        DropdownMenuItem(value: l.id, child: Text(l.name)),
                    ],
                    onChanged: _saving
                        ? null
                        : (v) => setState(() => _locationId = v),
                  ),
                  const SizedBox(height: Space.md),
                  TextField(
                    key: const Key('open-float'),
                    controller: _float,
                    enabled: !_saving,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: const [NumberInputFormatter()],
                    decoration: const InputDecoration(
                      labelText: 'Opening cash',
                      prefixText: '₹ ',
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: Space.sm),
                      child: Text(
                        _error!,
                        style: TextStyle(color: context.colors.danger),
                      ),
                    ),
                  const SizedBox(height: Space.lg),
                  FilledButton(
                    key: const Key('open-session'),
                    onPressed: _locationId == null || _saving ? null : _open,
                    child: const Text('Open session'),
                  ),
                  TextButton(
                    onPressed: () => context.go('/pos/sessions'),
                    child: const Text('Past sessions'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Count the drawer and close. The expected figure is shown after closing.
class PosCloseScreen extends ConsumerStatefulWidget {
  const PosCloseScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<PosCloseScreen> createState() => _PosCloseScreenState();
}

class _PosCloseScreenState extends ConsumerState<PosCloseScreen> {
  final _ctl = {for (final m in posModes) m: TextEditingController()};
  final _notes = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    _notes.dispose();
    super.dispose();
  }

  Future<void> _close({bool confirmHeld = false}) async {
    final cash = parseIndianNumber(_ctl['cash']!.text);
    if (cash == null) {
      setState(() => _error = 'Enter the cash you counted.');
      return;
    }
    final counted = <String, double>{'cash': cash};
    for (final m in ['upi', 'card', 'other']) {
      final v = parseIndianNumber(_ctl[m]!.text);
      if (v != null) counted[m] = v;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(posRepositoryProvider)
          .closeSession(
            widget.sessionId,
            counted,
            notes: _notes.text.trim(),
            confirmHeld: confirmHeld,
          );
      ref.read(posRevisionProvider(PosKind.session).notifier).bump();
      ref.read(posRevisionProvider(PosKind.sales).notifier).bump();
      if (mounted) context.go('/pos/sessions/${widget.sessionId}');
    } catch (e) {
      if (e is ApiException && e.code == 'HELD_BILLS' && mounted) {
        setState(() => _saving = false);
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Bills are still on hold'),
            content: Text(
              '${e.message} Close the session anyway? The held bills stay '
              'available to other counters.',
            ),
            actions: [
              TextButton(
                key: const Key('held-keep-open'),
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Go back'),
              ),
              FilledButton(
                key: const Key('held-close-anyway'),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Close anyway'),
              ),
            ],
          ),
        );
        if (ok == true && mounted) await _close(confirmHeld: true);
        return;
      }
      if (mounted) {
        setState(() {
          _saving = false;
          _error = errorMessage(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Space.lg),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Close the register',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: Space.xs),
              const Text(
                'Enter what you counted. UPI, card and other are optional.',
              ),
              const SizedBox(height: Space.lg),
              for (final m in posModes) ...[
                TextField(
                  key: Key('count-$m'),
                  controller: _ctl[m],
                  enabled: !_saving,
                  autofocus: m == 'cash',
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: const [NumberInputFormatter()],
                  decoration: InputDecoration(
                    labelText: '${posModeLabel(m)} counted',
                    prefixText: '₹ ',
                  ),
                ),
                const SizedBox(height: Space.md),
              ],
              TextField(
                controller: _notes,
                enabled: !_saving,
                maxLength: 500,
                decoration: const InputDecoration(
                  labelText: 'Notes (optional)',
                ),
              ),
              if (_error != null)
                Text(_error!, style: TextStyle(color: context.colors.danger)),
              const SizedBox(height: Space.md),
              Row(
                children: [
                  OutlinedButton(
                    onPressed: _saving ? null : () => context.go('/pos'),
                    child: const Text('Back'),
                  ),
                  const Spacer(),
                  FilledButton(
                    key: const Key('close-session'),
                    onPressed: _saving ? null : _close,
                    child: const Text('Close session'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// X report while the session is open, Z report once closed.
class PosReportScreen extends ConsumerWidget {
  const PosReportScreen({super.key, required this.sessionId});

  final String sessionId;

  Future<void> _pdf(
    BuildContext context,
    WidgetRef ref,
    SessionReport r,
  ) async {
    try {
      Company? company;
      try {
        company = await ref.read(companyRepositoryProvider).get();
      } catch (_) {
        company = ref.read(sessionProvider).value?.company;
      }
      final co =
          company ?? const Company(id: '', name: 'Company', stateCode: '');
      final bytes = await buildSessionReportPdf(
        r,
        brand: await loadPdfBrand(ref.read(apiClientProvider), co),
        theme: await pdfTheme(),
      );
      await Printing.layoutPdf(
        onLayout: (_) async => bytes,
        name: '${r.kind.toLowerCase()}-report.pdf',
      );
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final report = ref.watch(posSessionReportProvider(sessionId));
    return AsyncValueView<SessionReport>(
      value: report,
      onRetry: () => ref.invalidate(posSessionReportProvider(sessionId)),
      data: (r) => ListView(
        padding: EdgeInsets.symmetric(
          horizontal: pageGutter(context),
          vertical: Space.md,
        ),
        children: [
          Wrap(
            spacing: Space.sm,
            runSpacing: Space.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                r.kind == 'Z' ? 'Z report (closed)' : 'X report (running)',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              OutlinedButton.icon(
                key: const Key('report-pdf'),
                onPressed: () => _pdf(context, ref, r),
                icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
                label: const Text('PDF'),
              ),
              if (r.session.isOpen)
                OutlinedButton(
                  onPressed: () => context.go('/pos'),
                  child: const Text('Back to counter'),
                ),
              if (r.session.isOpen)
                FilledButton(
                  onPressed: () => context.go('/pos/sessions/$sessionId/close'),
                  child: const Text('Close session'),
                ),
            ],
          ),
          const SizedBox(height: Space.xs),
          Text(
            '${r.session.locationName}  |  ${r.session.userName}  |  opened ${formatDateTime(r.session.openedAt)}'
            '${r.session.closedAt == null ? '' : '  |  closed ${formatDateTime(r.session.closedAt)}'}',
          ),
          const SizedBox(height: Space.md),
          _Section('Sales', [
            _Row('Bills', '${r.salesCount}'),
            _Row('Items sold', formatQty(r.itemsSold)),
            _Row('Discounts', formatMoney(r.discountTotal)),
            _Row('Tax collected', formatMoney(r.taxTotal)),
            _Row('Sales total', formatMoney(r.salesTotal), strong: true),
            _Row('Returns (${r.returnsCount})', formatMoney(r.returnsTotal)),
            if (r.creditGiven > 0)
              _Row('Given on credit', formatMoney(r.creditGiven)),
          ]),
          _Section('Money by mode', [
            for (final m in posModes)
              _Row(
                posModeLabel(m),
                'in ${formatAmount(r.payments[m])}  out ${formatAmount(r.refunds[m])}'
                '  expected ${formatAmount(r.expected[m])}'
                '${r.counted?[m] == null ? '' : '  counted ${formatAmount(r.counted![m])}'}'
                '${r.difference?[m] == null ? '' : '  difference ${formatAmount(r.difference![m])}'}',
                key: Key('mode-$m'),
              ),
          ]),
          _Section('Cash drawer', [
            _Row('Opening cash', formatMoney(r.session.openingFloat)),
            _Row('Cash in', formatMoney(r.cashIn)),
            _Row('Cash out', formatMoney(r.cashOut)),
            for (final m in r.cashMoves)
              _Row(
                '${m['kind'] == 'in' ? 'In' : 'Out'}: ${m['reason']}',
                formatMoney((m['amount'] as num?) ?? 0),
              ),
          ]),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.rows);

  final String title;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: Space.md),
    child: Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Space.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: Space.xs),
            ...rows,
          ],
        ),
      ),
    ),
  );
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value, {super.key, this.strong = false});

  final String label;
  final String value;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final style = strong ? const TextStyle(fontWeight: FontWeight.w700) : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        children: [
          Text(label, style: style),
          Text(value, style: style),
        ],
      ),
    );
  }
}

/// Past and open sessions: own for counter staff, all for managers.
class PosSessionsScreen extends ConsumerWidget {
  const PosSessionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canManage = ref.watch(permissionsProvider).can(Perm.posManage);
    return AsyncValueView<Paged<PosSession>>(
      value: ref.watch(posSessionsProvider),
      onRetry: () => ref.invalidate(posSessionsProvider),
      data: (page) {
        final list = page.data;
        return ListView(
          padding: EdgeInsets.symmetric(
            horizontal: pageGutter(context),
            vertical: Space.md,
          ),
          children: [
            PageHeader(
              title: canManage ? 'Register sessions' : 'My register sessions',
              actions: [
                FilledButton(
                  onPressed: () => context.go('/pos'),
                  child: const Text('Counter'),
                ),
              ],
            ),
            if (list.isEmpty)
              const Padding(
                padding: EdgeInsets.all(Space.lg),
                child: Text('No sessions yet.'),
              ),
            for (final s in list)
              Card(
                margin: const EdgeInsets.only(bottom: Space.sm),
                child: ListTile(
                  key: Key('session-${s.id}'),
                  title: Text('${s.locationName}  |  ${s.userName}'),
                  subtitle: Text(
                    '${s.isOpen ? 'Open since' : 'Closed'} ${formatDateTime(s.isOpen ? s.openedAt : s.closedAt)}',
                  ),
                  trailing: Text(s.isOpen ? 'Open' : 'Closed'),
                  onTap: () => context.go('/pos/sessions/${s.id}'),
                ),
              ),
          ],
        );
      },
    );
  }
}
