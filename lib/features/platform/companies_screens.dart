import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/json.dart';
import '../../core/india_states.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/auth_models.dart';
import '../auth/session.dart';
import 'platform_models.dart';
import 'platform_repository.dart';

/// `/companies`: the companies the user belongs to, with switching.
class CompaniesScreen extends ConsumerWidget {
  const CompaniesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider).value ?? SessionState.signedOut;
    final canCreate = session.can(Perm.companiesCreate);
    return Column(
      children: [
        PageHeader(
          title: 'Companies',
          actions: [
            if (canCreate)
              FilledButton.icon(
                key: const Key('company.add'),
                onPressed: () => context.push('/companies/new'),
                icon: const Icon(Icons.add_business_outlined),
                label: const Text('New company'),
              ),
          ],
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final c in session.companies)
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: double.infinity,
                    ),
                    child: Card(
                      child: ListTile(
                        key: Key('company.${c.id}'),
                        leading: const Icon(Icons.business_outlined),
                        title: Text(c.name),
                        subtitle: Text(
                          [
                            if ((c.gstin ?? '').isNotEmpty) c.gstin!,
                            stateLabel(c.stateCode),
                            c.roles.map((r) => r.name).join(', '),
                          ].where((s) => s.isNotEmpty).join('  '),
                        ),
                        trailing: c.id == session.activeCompanyId
                            ? const Pill('Active')
                            : TextButton(
                                key: Key('company.switch.${c.id}'),
                                onPressed: () async {
                                  try {
                                    await ref
                                        .read(sessionProvider.notifier)
                                        .switchCompany(c.id);
                                    if (context.mounted) context.go('/');
                                  } catch (e) {
                                    if (context.mounted) {
                                      showErrorSnackBar(context, e);
                                    }
                                  }
                                },
                                child: const Text('Switch'),
                              ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// `/companies/new`: adds a company to the business.
class CompanyCreateScreen extends ConsumerStatefulWidget {
  const CompanyCreateScreen({super.key});

  @override
  ConsumerState<CompanyCreateScreen> createState() =>
      _CompanyCreateScreenState();
}

class _CompanyCreateScreenState extends ConsumerState<CompanyCreateScreen>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _legalName = TextEditingController();
  final _gstin = TextEditingController();
  final _pan = TextEditingController();
  String? _state;
  bool _copy = true;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_name, _legalName, _gstin, _pan]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => serverErrors = const {});
    if (!validateAndReveal(_formKey)) return;
    final session = ref.read(sessionProvider).value;
    setState(() => _saving = true);
    try {
      final created = await ref.read(platformRepositoryProvider).createCompany({
        'name': _name.text.trim(),
        'legalName': ?trimmedOrNull(_legalName.text),
        'stateCode': _state,
        'gstin': ?trimmedOrNull(_gstin.text.toUpperCase()),
        'pan': ?trimmedOrNull(_pan.text.toUpperCase()),
        if (_copy && session?.activeCompanyId != null)
          'copyAccountsFrom': session!.activeCompanyId,
      });
      // The new company comes with a role for the caller.
      await ref.read(sessionProvider.notifier).reloadMe();
      if (!mounted) return;
      showInfoSnackBar(context, 'Company "${created['name']}" created');
      context.go('/companies');
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Form(
    key: _formKey,
    child: FormPage(
      maxWidth: 640,
      children: [
        Text('New company', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 16),
        SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                key: const Key('newCompany.name'),
                controller: _name,
                decoration: InputDecoration(
                  labelText: 'Company name',
                  errorText: serverError('name'),
                ),
                validator: (v) => validateName(v, 'Company name'),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _legalName,
                decoration: const InputDecoration(
                  labelText: 'Legal name (optional)',
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                key: const Key('newCompany.state'),
                initialValue: _state,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: 'State',
                  errorText: serverError('stateCode'),
                ),
                items: [
                  for (final s in indiaStates)
                    DropdownMenuItem(
                      value: s.code,
                      child: Text(s.name, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) => setState(() => _state = v),
                validator: (v) => v == null ? 'Choose a state' : null,
              ),
              const SizedBox(height: 16),
              FormRow(
                children: [
                  TextFormField(
                    controller: _gstin,
                    textCapitalization: TextCapitalization.characters,
                    decoration: InputDecoration(
                      labelText: 'GSTIN (optional)',
                      errorText: serverError('gstin'),
                    ),
                  ),
                  TextFormField(
                    controller: _pan,
                    textCapitalization: TextCapitalization.characters,
                    decoration: InputDecoration(
                      labelText: 'PAN (optional)',
                      errorText: serverError('pan'),
                    ),
                    validator: validatePan,
                  ),
                ],
              ),
              SwitchListTile(
                key: const Key('newCompany.copy'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Copy chart of accounts'),
                subtitle: const Text(
                  'Copies the accounts you added to the current company.',
                ),
                value: _copy,
                onChanged: (v) => setState(() => _copy = v),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: BusyButton(
                  key: const Key('newCompany.save'),
                  busy: _saving,
                  onPressed: _save,
                  label: 'Create company',
                  icon: Icons.add_business_outlined,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

// Inter-company -----------------------------------------------------------

final intercompanyProvider =
    FutureProvider.autoDispose<Paged<IntercompanyEntry>>((ref) {
      ref.watch(activeCompanyIdProvider);
      return ref.watch(platformRepositoryProvider).intercompany();
    });

final intercompanyBalancesProvider =
    FutureProvider.autoDispose<IntercompanyBalances>((ref) {
      ref.watch(activeCompanyIdProvider);
      return ref.watch(platformRepositoryProvider).intercompanyBalances();
    });

/// `/intercompany`: entries where the active company is either side, plus
/// the balances report.
class IntercompanyScreen extends ConsumerWidget {
  const IntercompanyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(intercompanyProvider);
    final balances = ref.watch(intercompanyBalancesProvider);
    final session = ref.watch(sessionProvider).value ?? SessionState.signedOut;
    final active = session.activeCompanyId;
    final canPost = session.can(Perm.accountsJournal);
    return FormPage(
      maxWidth: 1000,
      children: [
        PageHeader(
          title: 'Inter-company',
          actions: [
            if (canPost)
              FilledButton.icon(
                key: const Key('ic.add'),
                onPressed: () => context.push('/intercompany/new'),
                icon: const Icon(Icons.add),
                label: const Text('New entry'),
              ),
          ],
        ),
        SectionCard(
          title: 'Balances with other companies',
          child: AsyncValueView<IntercompanyBalances>(
            value: balances,
            onRetry: () => ref.invalidate(intercompanyBalancesProvider),
            data: (b) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (b.rows.isEmpty) const Text('No balances.'),
                for (final r in b.rows)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(r.name),
                    subtitle: Text(
                      r.balance >= 0 ? 'They owe us' : 'We owe them',
                    ),
                    trailing: Text(formatMoney(r.balance.abs())),
                  ),
                const Divider(),
                Wrap(
                  spacing: 24,
                  runSpacing: 8,
                  children: [
                    LabeledValue(
                      'Inter-company account',
                      formatMoney(b.accountBalance),
                    ),
                    LabeledValue('Unexplained', formatMoney(b.unexplained)),
                    LabeledValue('As of', b.asOf),
                  ],
                ),
              ],
            ),
          ),
        ),
        SectionCard(
          title: 'Entries',
          child: AsyncValueView<Paged<IntercompanyEntry>>(
            value: entries,
            onRetry: () => ref.invalidate(intercompanyProvider),
            data: (page) => page.data.isEmpty
                ? const Text('No inter-company entries yet.')
                : Column(
                    children: [
                      for (final e in page.data)
                        ListTile(
                          key: Key('ic.${e.id}'),
                          contentPadding: EdgeInsets.zero,
                          title: Wrap(
                            spacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(e.number),
                              if (e.cancelled) const Pill('Cancelled'),
                            ],
                          ),
                          subtitle: Text(
                            '${e.date}  ${e.from.companyName} → '
                            '${e.to.companyName}\n${e.narration}'
                            '${e.cancelled ? '\nCancelled: ${e.cancelReason ?? ''}' : ''}',
                          ),
                          isThreeLine: true,
                          trailing: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                formatMoney(e.amount),
                                style: e.cancelled
                                    ? const TextStyle(
                                        decoration: TextDecoration.lineThrough,
                                      )
                                    : null,
                              ),
                              if (!e.cancelled && canPost)
                                SizedBox(
                                  height: 28,
                                  child: TextButton(
                                    key: Key('ic.cancel.${e.id}'),
                                    onPressed: () => _cancel(context, ref, e),
                                    child: const Text('Cancel'),
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
        ),
        if (active == null) const SizedBox.shrink(),
      ],
    );
  }

  Future<void> _cancel(
    BuildContext context,
    WidgetRef ref,
    IntercompanyEntry e,
  ) async {
    final reason = await showFormDialog<String>(
      context: context,
      builder: (_) => const _ReasonDialog(),
    );
    if (reason == null) return;
    try {
      await ref
          .read(platformRepositoryProvider)
          .cancelIntercompany(e.id, reason);
      ref.invalidate(intercompanyProvider);
      ref.invalidate(intercompanyBalancesProvider);
      if (context.mounted) showInfoSnackBar(context, '${e.number} cancelled');
    } catch (err) {
      if (context.mounted) showErrorSnackBar(context, err);
    }
  }
}

class _ReasonDialog extends StatefulWidget {
  const _ReasonDialog();

  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Cancel entry'),
    content: TextField(
      key: const Key('ic.reason'),
      controller: _reason,
      autofocus: true,
      decoration: const InputDecoration(labelText: 'Reason'),
      onChanged: (_) => setState(() {}),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Keep'),
      ),
      FilledButton(
        key: const Key('ic.confirmCancel'),
        onPressed: _reason.text.trim().length < 3
            ? null
            : () => Navigator.pop(context, _reason.text.trim()),
        child: const Text('Cancel entry'),
      ),
    ],
  );
}

final _accountsOfProvider = FutureProvider.autoDispose
    .family<List<({String id, String label})>, String>(
      (ref, companyId) =>
          ref.watch(platformRepositoryProvider).accountsOf(companyId),
    );

/// `/intercompany/new`: one entry that posts in both companies.
class IntercompanyCreateScreen extends ConsumerStatefulWidget {
  const IntercompanyCreateScreen({super.key});

  @override
  ConsumerState<IntercompanyCreateScreen> createState() =>
      _IntercompanyCreateScreenState();
}

class _IntercompanyCreateScreenState
    extends ConsumerState<IntercompanyCreateScreen>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _narration = TextEditingController();
  DateTime _date = DateTime.now();
  String? _fromCompany;
  String? _toCompany;
  String? _fromAccount;
  String? _toAccount;
  bool _saving = false;

  /// The giving company defaults to the active one (the session may still
  /// be loading when the screen opens).
  String? get _giving =>
      _fromCompany ?? ref.read(sessionProvider).value?.activeCompanyId;

  @override
  void dispose() {
    _amount.dispose();
    _narration.dispose();
    super.dispose();
  }

  String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  Future<void> _save() async {
    setState(() => serverErrors = const {});
    if (!validateAndReveal(_formKey)) return;
    setState(() => _saving = true);
    try {
      await ref.read(platformRepositoryProvider).createIntercompany({
        'date': _iso(_date),
        'amount': parseNumber(_amount.text),
        'narration': _narration.text.trim(),
        'from': {'companyId': _giving, 'accountId': _fromAccount},
        'to': {'companyId': _toCompany, 'accountId': _toAccount},
      });
      ref.invalidate(intercompanyProvider);
      ref.invalidate(intercompanyBalancesProvider);
      if (!mounted) return;
      showInfoSnackBar(context, 'Inter-company entry posted');
      context.go('/intercompany');
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _side(
    String label,
    String keyPrefix,
    String? company,
    String? account,
    List<Membership> companies,
    ValueChanged<String?> onCompany,
    ValueChanged<String?> onAccount,
  ) {
    final accounts = company == null
        ? null
        : ref.watch(_accountsOfProvider(company));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          key: Key('$keyPrefix.company'),
          initialValue: company,
          isExpanded: true,
          decoration: InputDecoration(labelText: '$label company'),
          items: [
            for (final c in companies)
              DropdownMenuItem(value: c.id, child: Text(c.name)),
          ],
          onChanged: onCompany,
          validator: (v) => v == null ? 'Choose a company' : null,
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          key: Key('$keyPrefix.account-$company'),
          initialValue:
              (accounts?.value ?? const []).any((a) => a.id == account)
              ? account
              : null,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: '$label account',
            helperText: accounts?.hasError == true
                ? 'No access to this company\'s accounts'
                : null,
          ),
          items: [
            for (final a
                in accounts?.value ?? const <({String id, String label})>[])
              DropdownMenuItem(
                value: a.id,
                child: Text(a.label, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: onAccount,
          validator: (v) => v == null ? 'Choose an account' : null,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final companies = ref.watch(sessionProvider).value?.companies ?? const [];
    return Form(
      key: _formKey,
      child: FormPage(
        maxWidth: 800,
        children: [
          Text(
            'New inter-company entry',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          const Text(
            'The giving company pays or charges. It posts to its own account '
            'and the Inter-company account; the receiving company posts the '
            'other half.',
          ),
          const SizedBox(height: 16),
          SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FormRow(
                  children: [
                    _side(
                      'Giving',
                      'ic.from',
                      _giving,
                      _fromAccount,
                      companies,
                      (v) => setState(() {
                        _fromCompany = v;
                        _fromAccount = null;
                      }),
                      (v) => setState(() => _fromAccount = v),
                    ),
                    _side(
                      'Receiving',
                      'ic.to',
                      _toCompany,
                      _toAccount,
                      companies,
                      (v) => setState(() {
                        _toCompany = v;
                        _toAccount = null;
                      }),
                      (v) => setState(() => _toAccount = v),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                FormRow(
                  children: [
                    TextFormField(
                      key: const Key('ic.amount'),
                      controller: _amount,
                      keyboardType: decimalKeyboard,
                      inputFormatters: [decimalInput()],
                      decoration: InputDecoration(
                        labelText: 'Amount',
                        prefixText: '$moneySymbol ',
                        errorText: serverError('amount'),
                      ),
                      validator: (v) => validateMoney(v, min: 0.01),
                    ),
                    InkWell(
                      onTap: () async {
                        final d = await showDatePicker(
                          context: context,
                          initialDate: _date,
                          firstDate: DateTime(2017),
                          lastDate: DateTime(2100),
                        );
                        if (d != null && mounted) setState(() => _date = d);
                      },
                      child: InputDecorator(
                        decoration: const InputDecoration(labelText: 'Date'),
                        child: Text(_iso(_date)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextFormField(
                  key: const Key('ic.narration'),
                  controller: _narration,
                  maxLength: 300,
                  decoration: InputDecoration(
                    labelText: 'Narration',
                    errorText: serverError('narration'),
                  ),
                  validator: (v) => (v ?? '').trim().length < 3
                      ? 'Enter at least 3 characters'
                      : null,
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: BusyButton(
                    key: const Key('ic.save'),
                    busy: _saving,
                    onPressed: _save,
                    label: 'Post entry',
                    icon: Icons.swap_horiz,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// Consolidated reports ----------------------------------------------------

/// `/consolidated`: pick 2–20 companies, then trial balance, P&L or balance
/// sheet with per-company columns.
class ConsolidatedScreen extends ConsumerStatefulWidget {
  const ConsolidatedScreen({super.key});

  @override
  ConsumerState<ConsolidatedScreen> createState() => _ConsolidatedScreenState();
}

class _ConsolidatedScreenState extends ConsumerState<ConsolidatedScreen> {
  final Set<String> _picked = {};
  String _kind = 'trial-balance';
  DateTime _from = DateTime(
    DateTime.now().month >= 4 ? DateTime.now().year : DateTime.now().year - 1,
    4,
    1,
  );
  DateTime _to = DateTime.now();
  ConsolidatedReport? _report;
  String? _reportKind;
  Object? _error;
  bool _loading = false;

  String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  Future<void> _run() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final report = await ref
          .read(platformRepositoryProvider)
          .consolidated(
            _kind,
            _picked.toList(),
            from: _iso(_from),
            to: _iso(_to),
          );
      if (mounted) {
        setState(() {
          _report = report;
          _reportKind = _kind;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pick(bool from) async {
    final d = await showDatePicker(
      context: context,
      initialDate: from ? _from : _to,
      firstDate: DateTime(2017),
      lastDate: DateTime(2100),
    );
    if (d != null && mounted) setState(() => from ? _from = d : _to = d);
  }

  @override
  Widget build(BuildContext context) {
    final companies = ref.watch(sessionProvider).value?.companies ?? const [];
    final valid = _picked.length >= 2 && _picked.length <= 20;
    return FormPage(
      maxWidth: 1200,
      children: [
        const PageHeader(title: 'Consolidated reports'),
        SectionCard(
          title: 'Companies (pick 2 to 20)',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in companies)
                    FilterChip(
                      key: Key('consol.company.${c.id}'),
                      label: Text(c.name),
                      selected: _picked.contains(c.id),
                      onSelected: (v) => setState(
                        () => v ? _picked.add(c.id) : _picked.remove(c.id),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SegmentedButton<String>(
                    key: const Key('consol.kind'),
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: 'trial-balance',
                        label: Text('Trial balance'),
                      ),
                      ButtonSegment(
                        value: 'profit-loss',
                        label: Text('Profit & loss'),
                      ),
                      ButtonSegment(
                        value: 'balance-sheet',
                        label: Text('Balance sheet'),
                      ),
                    ],
                    selected: {_kind},
                    onSelectionChanged: (s) => setState(() => _kind = s.first),
                  ),
                  if (_kind == 'profit-loss')
                    OutlinedButton(
                      onPressed: () => _pick(true),
                      child: Text('From ${_iso(_from)}'),
                    ),
                  OutlinedButton(
                    onPressed: () => _pick(false),
                    child: Text(
                      _kind == 'profit-loss'
                          ? 'To ${_iso(_to)}'
                          : 'As of ${_iso(_to)}',
                    ),
                  ),
                  BusyButton(
                    key: const Key('consol.run'),
                    busy: _loading,
                    onPressed: valid ? _run : null,
                    label: 'Show report',
                    icon: Icons.analytics_outlined,
                  ),
                ],
              ),
              if (!valid)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('Choose at least two companies.'),
                ),
            ],
          ),
        ),
        if (_error != null)
          ErrorView(error: _error!, onRetry: _run)
        else if (_report != null)
          _ReportView(report: _report!, kind: _reportKind!),
      ],
    );
  }
}

class _ReportView extends StatelessWidget {
  const _ReportView({required this.report, required this.kind});

  final ConsolidatedReport report;
  final String kind;

  @override
  Widget build(BuildContext context) {
    final tb = kind == 'trial-balance';
    final theme = Theme.of(context);
    final bold = theme.textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w600,
    );
    final columns = <DataColumn>[
      const DataColumn(label: Text('Code')),
      const DataColumn(label: Text('Account')),
      for (final c in report.companies)
        DataColumn(label: Text(c.name), numeric: true),
      if (tb) ...const [
        DataColumn(label: Text('Debit'), numeric: true),
        DataColumn(label: Text('Credit'), numeric: true),
      ] else
        const DataColumn(label: Text('Consolidated'), numeric: true),
    ];
    final extra = tb ? 2 : 1;
    DataRow row(ConsolidatedRow r) => DataRow(
      cells: [
        DataCell(Text(r.code)),
        DataCell(Text(r.name)),
        for (final c in report.companies)
          DataCell(Text(formatMoney(r.byCompany[c.id] ?? 0))),
        for (final v in r.values) DataCell(Text(formatMoney(v))),
      ],
    );
    DataRow header(String text) => DataRow(
      cells: [
        const DataCell(Text('')),
        DataCell(Text(text, style: bold)),
        for (var i = 0; i < report.companies.length + extra; i++)
          const DataCell(Text('')),
      ],
    );
    DataRow total(String label, double v) => DataRow(
      cells: [
        const DataCell(Text('')),
        DataCell(Text(label, style: bold)),
        for (var i = 0; i < report.companies.length; i++)
          const DataCell(Text('')),
        if (tb && extra == 2) ...[
          DataCell(
            Text(label.contains('debit') ? formatMoney(v) : '', style: bold),
          ),
          DataCell(
            Text(label.contains('credit') ? formatMoney(v) : '', style: bold),
          ),
        ] else
          DataCell(Text(formatMoney(v), style: bold)),
      ],
    );
    return SectionCard(
      title: switch (kind) {
        'trial-balance' => 'Consolidated trial balance',
        'profit-loss' => 'Consolidated profit & loss',
        _ => 'Consolidated balance sheet',
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final w in report.warnings)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber_outlined,
                    size: 18,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(w, key: const Key('consol.warning'))),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'Inter-company eliminated: ${formatMoney(report.eliminations)}',
              key: const Key('consol.elim'),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: columns,
              rows: [
                for (final s in report.sections) ...[
                  if (!tb) header(s.title),
                  for (final r in s.rows) row(r),
                  for (final (label, v) in s.totals) total(label, v),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// True when [error] is a 403 from a consolidated call.
bool isForbidden(Object error) => apiError(error)?.isForbidden ?? false;
