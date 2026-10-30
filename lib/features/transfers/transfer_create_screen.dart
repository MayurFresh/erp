import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/providers.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/picker_field.dart';
import '../../widgets/states.dart';
import '../documents/document_widgets.dart';
import '../documents/line_editor.dart';
import '../items/item_model.dart';
import '../items/item_picker.dart';
import '../locations/location_filter.dart';
import 'transfer_model.dart';
import 'transfers_repository.dart';
import '../../widgets/busy.dart';

class _TransferLineDraft {
  _TransferLineDraft(this.item);

  final Item item;
  final TextEditingController qty = TextEditingController(text: '1');
  final Key key = UniqueKey();
}

/// Sends stock from one location to another (`POST /transfers`).
class TransferCreateScreen extends ConsumerStatefulWidget {
  const TransferCreateScreen({super.key});

  @override
  ConsumerState<TransferCreateScreen> createState() =>
      _TransferCreateScreenState();
}

class _TransferCreateScreenState extends ConsumerState<TransferCreateScreen>
    with ServerFieldErrors, DirtyTracking<TransferCreateScreen> {
  final _formKey = GlobalKey<FormState>();
  final _notes = TextEditingController();
  final List<_TransferLineDraft> _lines = [];
  String? _fromId;
  String? _toId;
  DateTime _date = DateUtils.dateOnly(DateTime.now());
  bool _saving = false;
  Object? _error;

  @override
  void dispose() {
    _notes.dispose();
    for (final line in _lines) {
      line.qty.dispose();
    }
    super.dispose();
  }

  Future<void> _addLine() async {
    final item = await pickItem(context, ref, stockOnly: true);
    if (item == null) return;
    if (_lines.any((l) => l.item.id == item.id)) {
      if (mounted) showInfoSnackBar(context, '${item.name} is already added.');
      return;
    }
    setState(() => _lines.add(_TransferLineDraft(item)));
  }

  void _removeLine(_TransferLineDraft line) {
    setState(() => _lines.remove(line));
    line.qty.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await pickDocDate(context, _date);
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _save() async {
    setState(() {
      serverErrors = const {};
      _error = null;
    });
    final valid = _formKey.currentState!.validate();
    if (_lines.isEmpty) {
      markSaved();
      showInfoSnackBar(context, 'Add at least one item.');
      return;
    }
    if (!valid) return;
    setState(() => _saving = true);
    try {
      final transfer = await ref
          .read(transfersRepositoryProvider)
          .create(
            TransferDraft(
              fromLocationId: _fromId!,
              toLocationId: _toId!,
              transferDate: apiDate(_date),
              notes: trimmedOrNull(_notes.text),
              lines: {
                for (final line in _lines)
                  line.item.id: parseNumber(line.qty.text)!,
              },
            ),
          );
      ref.bump(const [DataKind.transfers, DataKind.stock]);
      if (!mounted) return;
      showInfoSnackBar(context, 'Transfer ${transfer.number} created');
      context.go('/transfers/${transfer.id}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
      showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => track(_buildBody(context));

  Widget _buildBody(BuildContext context) {
    final theme = Theme.of(context);
    return Form(
      key: _formKey,
      onChanged: markDirty,
      child: FormPage(
        maxWidth: 900,
        children: [
          Text('New transfer', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Route',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FormRow(
                  children: [
                    LocationField(
                      label: 'From',
                      value: _fromId,
                      errorText: serverError('fromLocationId'),
                      onChanged: (v) {
                        clearServerError('fromLocationId');
                        setState(() => _fromId = v);
                      },
                    ),
                    _ToField(
                      value: _toId,
                      fromId: _fromId,
                      errorText: serverError('toLocationId'),
                      onChanged: (v) {
                        clearServerError('toLocationId');
                        setState(() => _toId = v);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                FormRow(
                  children: [
                    PickerField(
                      label: 'Transfer date',
                      value: formatDate(_date),
                      icon: Icons.calendar_today_outlined,
                      errorText: serverError('transferDate'),
                      onTap: _pickDate,
                    ),
                    TextFormField(
                      controller: _notes,
                      decoration: const InputDecoration(
                        labelText: 'Notes (optional)',
                        hintText: 'Vehicle no., driver, …',
                      ),
                      forceErrorText: serverError('notes'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          SectionCard(
            title: 'Items',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_lines.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: Text('No items yet. Add the first one.'),
                  ),
                for (final (index, line) in _lines.indexed)
                  _TransferLineRow(
                    key: line.key,
                    line: line,
                    error:
                        serverError('lines.$index.qty') ??
                        serverError('lines[$index].qty'),
                    onRemove: () => _removeLine(line),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: _saving ? null : _addLine,
                    icon: const Icon(Icons.add),
                    label: const Text('Add item'),
                  ),
                ),
              ],
            ),
          ),
          if (_error != null) ...[
            ApiErrorBox(error: _error!, subject: 'the transfer'),
            const SizedBox(height: 16),
          ],
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: _saving ? null : () => leave('/transfers'),
                child: const Text('Cancel'),
              ),
              BusyButton(
                busy: _saving,
                onPressed: _save,
                icon: Icons.local_shipping_outlined,
                label: 'Send transfer',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Destination: any location except the source.
class _ToField extends StatelessWidget {
  const _ToField({
    required this.value,
    required this.fromId,
    required this.onChanged,
    this.errorText,
  });

  final String? value;
  final String? fromId;
  final ValueChanged<String?> onChanged;
  final String? errorText;

  @override
  Widget build(BuildContext context) => FormField<String>(
    validator: (_) =>
        value != null && value == fromId ? 'Choose a different location' : null,
    builder: (field) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LocationField(
          label: 'To',
          value: value,
          errorText: errorText ?? field.errorText,
          onChanged: onChanged,
        ),
      ],
    ),
  );
}

class _TransferLineRow extends StatelessWidget {
  const _TransferLineRow({
    super.key,
    required this.line,
    required this.onRemove,
    this.error,
  });

  final _TransferLineDraft line;
  final VoidCallback onRemove;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = line.item;
    final qty = TextFormField(
      controller: line.qty,
      decoration: InputDecoration(
        labelText: 'Qty',
        suffixText: item.unit,
        isDense: true,
        errorText: error,
        errorMaxLines: 2,
      ),
      keyboardType: decimalKeyboard,
      inputFormatters: [decimalInput(decimals: 3)],
      validator: (v) {
        final q = parseNumber(v ?? '');
        return q == null || q <= 0 ? 'Enter qty' : null;
      },
    );
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          item.name,
          style: theme.textTheme.titleSmall,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          [if (item.sku != null) item.sku!, item.unit].join(' · '),
          style: theme.textTheme.bodySmall,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
    final remove = IconButton(
      tooltip: 'Remove line',
      icon: const Icon(Icons.delete_outline),
      onPressed: onRemove,
    );
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: LayoutBuilder(
          builder: (context, constraints) => constraints.maxWidth >= 480
              ? Row(
                  children: [
                    Expanded(child: title),
                    const SizedBox(width: 12),
                    SizedBox(width: 150, child: qty),
                    remove,
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(child: title),
                        remove,
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: qty,
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
