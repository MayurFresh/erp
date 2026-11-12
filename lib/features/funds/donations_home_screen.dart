import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/picker_field.dart';
import '../../widgets/search_picker.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../construction/common/c_widgets.dart'
    show CGate, DateField, showSuccess;
import 'donors_screen.dart';
import 'funds_models.dart';
import 'funds_pdf.dart';
import 'funds_repository.dart';
import 'funds_widgets.dart';

const donationViewPerms = [
  Perm.donationsView,
  Perm.donationsCreate,
  Perm.donationsManage,
];

/// Opens the print dialog for the receipt of donation [id].
Future<void> printReceipt(WidgetRef ref, String id) async {
  final data = await ref.read(fundsRepositoryProvider).receipt(id);
  final (brand, theme) = await loadBrandAndTheme(ref);
  final bytes = await buildReceiptPdf(data, brand: brand, theme: theme);
  await printBytes(bytes, receiptFileName(data));
}

/// `/donations`: today and this year, with a donation entry made for speed.
class DonationsHomeScreen extends ConsumerWidget {
  const DonationsHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final create = ref.watch(permissionsProvider).canAny(const [
      Perm.donationsCreate,
      Perm.donationsManage,
    ]);
    return CGate(
      anyOf: donationViewPerms,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(title: 'Donations'),
          Expanded(
            child: AsyncValueView<DonationHome>(
              value: ref.watch(donationHomeProvider),
              onRetry: () => ref.invalidate(donationHomeProvider),
              data: (h) => Gutter(
                children: [
                  SectionCard(
                    child: FigureRow([
                      Figure('Today (${h.todayCount})', formatAmount(h.today)),
                      Figure(
                        'This year (${h.yearCount})',
                        formatAmount(h.year),
                      ),
                      Figure('Eligible for 80G', formatAmount(h.eligible80g)),
                      Figure('Corpus', formatAmount(h.corpus)),
                    ]),
                  ),
                  if (!h.reg80gSet)
                    const SoftNote(
                      'The 80G registration number is not set. Receipts will not show it. Set it under Form 10BD.',
                    ),
                  if (create) DonationEntryCard(reg80gSet: h.reg80gSet),
                  SectionCard(
                    title: 'Recent receipts',
                    trailing: TextButton(
                      onPressed: () => context.go('/donations/receipts'),
                      child: const Text('All receipts'),
                    ),
                    child: h.recent.isEmpty
                        ? const Text('No donations yet.')
                        : Column(
                            children: [
                              for (final d in h.recent)
                                ListTile(
                                  key: ValueKey('recent-${d.id}'),
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(d.donorName),
                                  subtitle: Text(
                                    '${d.receiptNo}  |  ${formatDate(d.date)}  |  ${donationModes[d.mode] ?? d.mode}',
                                  ),
                                  trailing: Text(
                                    formatAmount(d.amount),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleSmall,
                                  ),
                                ),
                            ],
                          ),
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: () => context.go('/donations/donors'),
                        child: const Text('Donors'),
                      ),
                      OutlinedButton(
                        onPressed: () => context.go('/donations/10bd'),
                        child: const Text('Form 10BD'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class DonationEntryCard extends ConsumerStatefulWidget {
  const DonationEntryCard({super.key, required this.reg80gSet});

  final bool reg80gSet;

  @override
  ConsumerState<DonationEntryCard> createState() => _DonationEntryCardState();
}

class _DonationEntryCardState extends ConsumerState<DonationEntryCard>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  Donor? _donor;
  String _mode = 'upi';
  bool _tax80g = false;
  bool _corpus = false;
  String? _fund;
  DateTime _date = DateUtils.dateOnly(DateTime.now());
  final _amount = TextEditingController();
  final _reference = TextEditingController();
  final _purpose = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _tax80g = widget.reg80gSet;
  }

  @override
  void dispose() {
    for (final c in [_amount, _reference, _purpose]) {
      c.dispose();
    }
    super.dispose();
  }

  double get _value => parseNumber(_amount.text) ?? 0;
  bool get _cashOver => _mode == 'cash' && _value > 2000;

  Future<void> _pickDonor() async {
    final picked = await showSearchPicker<Donor>(
      context: context,
      title: 'Find donor',
      hintText: 'Name or phone',
      emptyMessage: 'No donor found. Use New donor.',
      search: (q) => ref.read(fundsRepositoryProvider).donors(q),
      titleBuilder: (_, d) => Text(d.name),
      subtitleBuilder: (_, d) => Text(d.line),
    );
    if (picked != null) setState(() => _donor = picked);
  }

  Future<void> _newDonor() async {
    final d = await showFormDialog<Donor>(
      context: context,
      builder: (_) => const DonorDialog(),
    );
    if (d != null && mounted) {
      ref.bumpFunds();
      setState(() => _donor = d);
    }
  }

  Future<void> _save(bool print) async {
    setState(() => serverErrors = const {});
    if (!validateAndReveal(_formKey)) return;
    setState(() => _saving = true);
    try {
      final made = await ref.read(fundsRepositoryProvider).createDonation({
        'donorId': _donor!.id,
        'amount': _value,
        'mode': _mode,
        'date': apiDate(_date),
        if (_mode != 'cash') 'reference': trimmedOrNull(_reference.text),
        'fundId': _fund,
        'purpose': trimmedOrNull(_purpose.text),
        'isCorpus': _corpus,
        'tax80g': _tax80g,
      });
      ref.bumpFunds();
      if (!mounted) return;
      showSuccess(context, 'Receipt ${made.receiptNo} saved');
      showWarnings(context, made.warnings);
      setState(() {
        _donor = null;
        _amount.clear();
        _reference.clear();
        _purpose.clear();
        _corpus = false;
        _date = DateUtils.dateOnly(DateTime.now());
      });
      if (print) await printReceipt(ref, made.id);
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final funds = (ref.watch(fundsListProvider).value ?? const <FundRow>[])
        .where((f) => f.status == 'active')
        .toList();
    return SectionCard(
      title: 'New donation',
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: PickerField(
                    key: const ValueKey('donor-field'),
                    label: 'Donor',
                    value: _donor == null
                        ? null
                        : '${_donor!.name}${_donor!.phone == null ? '' : '  ${_donor!.phone}'}',
                    errorText: serverError('donorId'),
                    validator: () => _donor == null ? 'Choose a donor' : null,
                    onTap: _pickDonor,
                  ),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: OutlinedButton.icon(
                    key: const ValueKey('new-donor'),
                    onPressed: _newDonor,
                    icon: const Icon(Icons.person_add_alt_1_outlined),
                    label: const Text('New'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            FormRow(
              minCellWidth: 180,
              children: [
                TextFormField(
                  key: const ValueKey('amount'),
                  controller: _amount,
                  keyboardType: decimalKeyboard,
                  inputFormatters: [decimalInput()],
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: 'Amount',
                    prefixText: '$moneySymbol ',
                    errorText: serverError('amount'),
                  ),
                  validator: (v) => (parseNumber(v ?? '') ?? 0) <= 0
                      ? 'Enter an amount'
                      : null,
                ),
                DateField(
                  label: 'Date',
                  value: _date,
                  onChanged: (d) => setState(() => _date = d),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final e in donationModes.entries)
                  ChoiceChip(
                    key: ValueKey('mode-${e.key}'),
                    label: Text(e.value),
                    selected: _mode == e.key,
                    onSelected: (_) => setState(() => _mode = e.key),
                  ),
              ],
            ),
            if (_mode != 'cash') ...[
              const SizedBox(height: 10),
              TextFormField(
                controller: _reference,
                decoration: const InputDecoration(
                  labelText: 'Reference (UTR, cheque number)',
                ),
              ),
            ],
            const SizedBox(height: 10),
            FormRow(
              minCellWidth: 200,
              children: [
                DropdownButtonFormField<String?>(
                  key: const ValueKey('donation-fund'),
                  initialValue: _fund,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Fund (optional)',
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('General'),
                    ),
                    for (final f in funds)
                      DropdownMenuItem<String?>(
                        value: f.id,
                        child: Text(f.name, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) => setState(() => _fund = v),
                ),
                TextFormField(
                  controller: _purpose,
                  decoration: const InputDecoration(
                    labelText: 'Purpose (optional)',
                  ),
                ),
              ],
            ),
            SwitchListTile(
              key: const ValueKey('tax80g'),
              contentPadding: EdgeInsets.zero,
              title: const Text('80G receipt'),
              value: _tax80g,
              onChanged: (v) => setState(() => _tax80g = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Corpus donation'),
              value: _corpus,
              onChanged: (v) => setState(() => _corpus = v),
            ),
            if (_tax80g && _cashOver)
              const SoftNote(
                'Cash above Rs 2,000 cannot get an 80G deduction. It will be recorded, and the receipt will say so.',
              ),
            if (_tax80g && _donor != null && !_donor!.hasId)
              const SoftNote(
                'This donor has no PAN or Aadhaar. Add one before giving an 80G receipt.',
                danger: true,
              ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                BusyButton(
                  key: const ValueKey('save-print'),
                  busy: _saving,
                  onPressed: _saving ? null : () => _save(true),
                  icon: Icons.print_outlined,
                  label: 'Save and print receipt',
                ),
                OutlinedButton(
                  key: const ValueKey('save-only'),
                  onPressed: _saving ? null : () => _save(false),
                  child: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
