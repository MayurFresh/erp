import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/providers.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/picker_field.dart';
import '../../widgets/search_picker.dart';
import '../../widgets/states.dart';
import '../documents/line_editor.dart';
import '../invoices/invoice_model.dart';
import '../invoices/invoices_repository.dart';
import 'credit_note_model.dart';
import 'credit_notes_repository.dart';

/// A sales return: pick an invoice, the quantities coming back and a
/// reason; totals come from `POST /credit-notes/preview`.
class CreditNoteCreateScreen extends ConsumerStatefulWidget {
  const CreditNoteCreateScreen({super.key, this.initialInvoiceId});

  final String? initialInvoiceId;

  @override
  ConsumerState<CreditNoteCreateScreen> createState() =>
      _CreditNoteCreateScreenState();
}

class _CreditNoteCreateScreenState extends ConsumerState<CreditNoteCreateScreen>
    with LivePreview<CreditNoteCreateScreen, CreditNoteDraft, CreditNote> {
  final _formKey = GlobalKey<FormState>();
  final _reason = TextEditingController();
  final Map<String, TextEditingController> _qty = {};
  Invoice? _invoice;
  Object? _invoiceError;
  bool _loadingInvoice = false;
  DateTime _date = DateUtils.dateOnly(DateTime.now());
  bool _restock = true;

  bool _saving = false;
  Object? _saveError;
  Map<String, String> _fieldErrors = const {};

  @override
  void initState() {
    super.initState();
    final id = widget.initialInvoiceId;
    if (id != null) _loadInvoice(id);
  }

  @override
  void dispose() {
    _reason.dispose();
    for (final c in _qty.values) {
      c.dispose();
    }
    super.dispose();
  }

  List<InvoiceLine> get _returnable => (_invoice?.lines ?? const [])
      .where((l) => l.id != null && l.returnableQty > 0)
      .toList();

  Future<void> _loadInvoice(String id) async {
    setState(() {
      _loadingInvoice = true;
      _invoiceError = null;
    });
    try {
      final invoice = await ref.read(invoicesRepositoryProvider).get(id);
      if (!mounted) return;
      setState(() {
        _invoice = invoice;
        _loadingInvoice = false;
        for (final c in _qty.values) {
          c.dispose();
        }
        _qty
          ..clear()
          ..addAll({
            for (final line in _returnable) line.id!: TextEditingController(),
          });
      });
      schedulePreview();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _invoiceError = e;
        _loadingInvoice = false;
      });
    }
  }

  Future<void> _pickInvoice() async {
    final repo = ref.read(invoicesRepositoryProvider);
    final picked = await showSearchPicker<Invoice>(
      context: context,
      title: 'Choose an invoice',
      hintText: 'Search number or party',
      emptyMessage: 'No posted invoices match.',
      search: (q) async =>
          (await repo.list(q: q, status: DocStatus.posted, limit: 50)).data,
      titleBuilder: (context, i) => Text(i.number ?? '—'),
      subtitleBuilder: (context, i) =>
          Text('${i.partyName} · ${formatDate(i.invoiceDate)}'),
      trailingBuilder: (context, i) => Text(formatMoney(i.total)),
    );
    if (picked?.id != null) _loadInvoice(picked!.id!);
  }

  Map<String, double> get _quantities => {
    for (final MapEntry(:key, value: c) in _qty.entries)
      if ((parseNumber(c.text) ?? 0) > 0) key: parseNumber(c.text)!,
  };

  bool get _quantitiesValid {
    for (final line in _returnable) {
      final q = parseNumber(_qty[line.id]?.text ?? '');
      if (q != null && (q < 0 || q > line.returnableQty)) return false;
    }
    return true;
  }

  CreditNoteDraft _draft(String reason) => CreditNoteDraft(
    invoiceId: _invoice!.id!,
    noteDate: apiDate(_date),
    reason: reason,
    restock: _restock,
    lines: _quantities,
  );

  @override
  CreditNoteDraft? buildDraft() {
    if (_invoice?.id == null || _quantities.isEmpty || !_quantitiesValid) {
      return null;
    }
    // The preview body must be complete; the reason does not change totals.
    return _draft(trimmedOrNull(_reason.text) ?? 'Preview');
  }

  @override
  Future<CreditNote> fetchPreview(CreditNoteDraft draft) =>
      ref.read(creditNotesRepositoryProvider).preview(draft);

  Future<void> _pickDate() async {
    final picked = await pickDocDate(context, _date);
    if (picked == null) return;
    setState(() => _date = picked);
    schedulePreview();
  }

  void _returnAll() {
    for (final line in _returnable) {
      _qty[line.id]!.text = formatPlain(line.returnableQty);
    }
    setState(() {});
    schedulePreview();
  }

  Future<void> _save() async {
    setState(() {
      _saveError = null;
      _fieldErrors = const {};
    });
    final valid = _formKey.currentState!.validate();
    if (_invoice == null) return;
    if (_quantities.isEmpty) {
      showInfoSnackBar(context, 'Enter the quantity returned on a line.');
      return;
    }
    if (!valid || !_quantitiesValid) return;
    cancelPreview();
    setState(() => _saving = true);
    try {
      final note = await ref
          .read(creditNotesRepositoryProvider)
          .create(_draft(_reason.text.trim()));
      ref.bump(const [
        DataKind.creditNotes,
        DataKind.invoices,
        DataKind.stock,
        DataKind.parties,
      ]);
      if (!mounted) return;
      showInfoSnackBar(context, 'Credit note ${note.number ?? ''} saved');
      context.go('/credit-notes/${note.id}');
    } catch (e) {
      if (!mounted) return;
      final (header, _) = splitFieldErrors(e);
      setState(() {
        _saveError = e;
        _fieldErrors = header;
      });
      showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final invoice = _invoice;
    final details = SectionCard(
      title: 'Details',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FormRow(
            children: [
              PickerField(
                label: 'Invoice',
                value: invoice == null
                    ? null
                    : '${invoice.number} · ${invoice.partyName}',
                onTap: _pickInvoice,
                enabled: widget.initialInvoiceId == null,
                errorText: _fieldErrors['invoiceId'],
                validator: () => invoice == null ? 'Choose an invoice' : null,
              ),
              PickerField(
                label: 'Note date',
                value: formatDate(_date),
                icon: Icons.calendar_today_outlined,
                errorText: _fieldErrors['noteDate'],
                onTap: _pickDate,
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _reason,
            decoration: InputDecoration(
              labelText: 'Reason',
              hintText: 'e.g. Damaged in transit',
              errorText: _fieldErrors['reason'],
            ),
            validator: (v) => requiredField(v, 'Reason'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Return goods to stock'),
            subtitle: Text(
              invoice == null
                  ? 'Adds the returned quantity back to the invoice location'
                  : 'Adds the returned quantity back to ${invoice.locationName}',
            ),
            value: _restock,
            onChanged: (v) {
              setState(() => _restock = v);
              schedulePreview();
            },
          ),
        ],
      ),
    );

    final lines = SectionCard(title: 'Items returned', child: _linesBody());

    return Form(
      key: _formKey,
      child: DocFormLayout(
        title: 'New credit note',
        main: [details, lines],
        summary: SectionCard(
          title: 'Summary',
          child: DocSummaryPanel(
            ready: buildDraft() != null,
            preview: preview,
            previewError: previewError,
            previewing: previewing,
            saveError: _saveError,
            saving: _saving,
            onSave: _save,
            saveLabel: 'Save credit note',
            subject: 'the credit note',
            hint: 'Choose an invoice and enter the quantities returned.',
          ),
        ),
      ),
    );
  }

  Widget _linesBody() {
    if (_loadingInvoice) return const LinearProgressIndicator();
    if (_invoiceError != null) {
      return ErrorView(
        error: _invoiceError!,
        onRetry: widget.initialInvoiceId == null
            ? null
            : () => _loadInvoice(widget.initialInvoiceId!),
      );
    }
    final invoice = _invoice;
    if (invoice == null) return const Text('Choose an invoice first.');
    if (invoice.isCancelled) {
      return const Text('This invoice is cancelled; nothing can be returned.');
    }
    final returnable = _returnable;
    if (returnable.isEmpty) {
      return const Text('Everything on this invoice has been returned.');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _returnAll,
            icon: const Icon(Icons.select_all),
            label: const Text('Return everything'),
          ),
        ),
        const SizedBox(height: 8),
        for (final line in returnable)
          _ReturnLine(
            key: ValueKey(line.id),
            line: line,
            controller: _qty[line.id]!,
            onChanged: schedulePreview,
          ),
      ],
    );
  }
}

class _ReturnLine extends StatelessWidget {
  const _ReturnLine({
    super.key,
    required this.line,
    required this.controller,
    required this.onChanged,
  });

  final InvoiceLine line;
  final TextEditingController controller;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          line.description,
          style: theme.textTheme.titleSmall,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          'Sold ${formatQty(line.qty)} ${line.unit} × ${formatMoney(line.rate)}'
          '${line.returnedQty > 0 ? ' · returned ${formatQty(line.returnedQty)}' : ''}'
          ' · GST ${formatPercent(line.gstRate)}',
          style: small,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
    final field = TextFormField(
      controller: controller,
      decoration: InputDecoration(
        labelText: 'Return qty',
        helperText: 'Max ${formatQty(line.returnableQty)}',
        isDense: true,
        suffixText: line.unit,
        errorMaxLines: 2,
      ),
      keyboardType: decimalKeyboard,
      inputFormatters: [decimalInput(decimals: 3)],
      onChanged: (_) => onChanged(),
      validator: (v) {
        final q = parseNumber(v ?? '');
        if (q == null) return null;
        if (q < 0) return 'Cannot be negative';
        return q > line.returnableQty
            ? 'Max ${formatQty(line.returnableQty)}'
            : null;
      },
    );
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: LayoutBuilder(
          builder: (context, constraints) => constraints.maxWidth >= 560
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: info),
                    const SizedBox(width: 16),
                    SizedBox(width: 160, child: field),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [info, const SizedBox(height: 8), field],
                ),
        ),
      ),
    );
  }
}
