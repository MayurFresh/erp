import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_tokens.dart';
import '../../core/json.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../construction/common/c_widgets.dart' show DateField;
import '../construction/data/photo_source.dart';
import 'claims_models.dart';
import 'claims_repository.dart';
import 'claims_widgets.dart';

class _LineDraft {
  _LineDraft({
    this.categoryId,
    DateTime? date,
    String description = '',
    String amount = '',
    String gst = '',
    String gstin = '',
    this.receiptFileId,
  }) : date = date ?? DateTime.now(),
       description = TextEditingController(text: description),
       amount = TextEditingController(text: amount),
       gst = TextEditingController(text: gst),
       gstin = TextEditingController(text: gstin);

  String? categoryId;
  DateTime date;
  String? receiptFileId;
  String? receiptName;
  final TextEditingController description;
  final TextEditingController amount;
  final TextEditingController gst;
  final TextEditingController gstin;

  void dispose() {
    description.dispose();
    amount.dispose();
    gst.dispose();
    gstin.dispose();
  }
}

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// `/my-claims/new` and `/claims/:id/edit`: a claim with one or more bill lines.
class ClaimFormScreen extends ConsumerStatefulWidget {
  const ClaimFormScreen({super.key, this.claimId});

  final String? claimId;

  @override
  ConsumerState<ClaimFormScreen> createState() => _ClaimFormState();
}

class _ClaimFormState extends ConsumerState<ClaimFormScreen> {
  final _purpose = TextEditingController();
  final _lines = <_LineDraft>[];
  bool _busy = false;
  bool _loaded = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.claimId == null) {
      _lines.add(_LineDraft());
      _loaded = true;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    final c = await ref.read(claimsRepositoryProvider).claim(widget.claimId!);
    if (!mounted) return;
    setState(() {
      _purpose.text = c.purpose;
      for (final l in c.lines) {
        _lines.add(_LineDraft(
          categoryId: l.categoryId,
          date: DateTime.tryParse(l.expenseDate),
          description: l.description,
          amount: l.amount.toString(),
          gst: l.gstAmount > 0 ? l.gstAmount.toString() : '',
          gstin: l.vendorGstin ?? '',
          receiptFileId: l.receiptFileId,
        )..receiptName = l.receiptFileId == null ? null : 'Receipt attached');
      }
      _loaded = true;
    });
  }

  @override
  void dispose() {
    _purpose.dispose();
    for (final l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  Future<void> _photo(_LineDraft l, bool camera) async {
    final source = ref.read(photoSourceProvider);
    if (source.unavailableMessage != null) {
      showInfoSnackBar(context, source.unavailableMessage!);
      return;
    }
    final photo = await source.pick(camera: camera);
    if (photo == null || !mounted) return;
    await guarded(context, () async {
      final id = await ref.read(claimsRepositoryProvider).uploadReceipt(photo);
      setState(() {
        l.receiptFileId = id;
        l.receiptName = photo.name;
      });
    });
  }

  Json? _body(bool submit) {
    if (_purpose.text.trim().length < 2) {
      setState(() => _error = 'Say what the claim is for.');
      return null;
    }
    final lines = <Json>[];
    for (final (i, l) in _lines.indexed) {
      final amount = double.tryParse(l.amount.text.trim());
      if (l.categoryId == null || amount == null || amount <= 0 || l.description.text.trim().isEmpty) {
        setState(() => _error = 'Line ${i + 1}: choose a category and fill in the description and amount.');
        return null;
      }
      lines.add(ClaimLine(
        categoryId: l.categoryId!,
        categoryName: '',
        expenseDate: _iso(l.date),
        description: l.description.text.trim(),
        amount: amount,
        vendorGstin: l.gstin.text.trim().toUpperCase(),
        gstAmount: double.tryParse(l.gst.text.trim()) ?? 0,
        receiptFileId: l.receiptFileId,
      ).toBody());
    }
    setState(() => _error = null);
    return {'purpose': _purpose.text.trim(), 'lines': lines, 'submit': submit};
  }

  Future<void> _save(bool submit) async {
    final body = _body(submit);
    if (body == null) return;
    setState(() => _busy = true);
    final ok = await guarded(context, () async {
      final c = await ref.read(claimsRepositoryProvider).saveClaim(widget.claimId, body);
      ref.read(claimsRevisionProvider.notifier).bump();
      if (mounted) context.go('/claims/${c.id}');
    });
    if (mounted && !ok) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const LoadingView();
    final cats = ref.watch(claimCategoriesProvider);
    final theme = Theme.of(context);
    final categories = (cats.value ?? const <ClaimCategory>[]).where((c) => c.isActive).toList();
    return FormPage(
      bottomBar: FormActionBar(
        children: [
          TextButton(onPressed: _busy ? null : () => context.go('/my-claims'), child: const Text('Cancel')),
          OutlinedButton(onPressed: _busy ? null : () => _save(false), child: const Text('Save draft')),
          FilledButton(onPressed: _busy ? null : () => _save(true), child: const Text('Submit claim')),
        ],
      ),
      children: [
        PageHeader(title: widget.claimId == null ? 'New claim' : 'Edit claim'),
        TextField(
          controller: _purpose,
          decoration: const InputDecoration(labelText: 'What is this claim for'),
        ),
        const SizedBox(height: Space.md),
        for (final (i, l) in _lines.indexed)
          Card(
            margin: const EdgeInsets.only(bottom: Space.md),
            child: Padding(
              padding: const EdgeInsets.all(Space.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text('Bill ${i + 1}', style: theme.textTheme.titleSmall)),
                      if (_lines.length > 1)
                        IconButton(
                          tooltip: 'Remove bill',
                          onPressed: () => setState(() => _lines.removeAt(i).dispose()),
                          icon: const Icon(Icons.close),
                        ),
                    ],
                  ),
                  FormRow(
                    children: [
                      DropdownButtonFormField<String>(
                        initialValue: l.categoryId,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'Category'),
                        items: [for (final c in categories) DropdownMenuItem(value: c.id, child: Text(c.name))],
                        onChanged: (v) => setState(() => l.categoryId = v),
                      ),
                      DateField(
                        label: 'Bill date',
                        value: l.date,
                        lastDate: DateTime.now(),
                        onChanged: (d) => setState(() => l.date = d),
                      ),
                      TextField(controller: l.description, decoration: const InputDecoration(labelText: 'Description')),
                      TextField(
                        controller: l.amount,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: 'Bill total, with GST'),
                      ),
                      TextField(
                        controller: l.gst,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: 'GST in the bill, if any'),
                      ),
                      TextField(
                        controller: l.gstin,
                        textCapitalization: TextCapitalization.characters,
                        decoration: const InputDecoration(labelText: 'Vendor GSTIN, if any'),
                      ),
                    ],
                  ),
                  const SizedBox(height: Space.sm),
                  Wrap(
                    spacing: Space.sm,
                    runSpacing: Space.sm,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () => _photo(l, true),
                        icon: const Icon(Icons.photo_camera_outlined),
                        label: const Text('Take photo of bill'),
                      ),
                      TextButton(onPressed: () => _photo(l, false), child: const Text('Choose a file')),
                      if (l.receiptName != null) Text(l.receiptName!, style: theme.textTheme.bodySmall),
                    ],
                  ),
                ],
              ),
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => setState(() => _lines.add(_LineDraft())),
            icon: const Icon(Icons.add),
            label: const Text('Add another bill'),
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: Space.sm),
            child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ),
      ],
    );
  }
}
