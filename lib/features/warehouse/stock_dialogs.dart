import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_tokens.dart';
import '../../core/json.dart';
import '../../core/money.dart';
import '../../widgets/form_support.dart';
import '../items/item_picker.dart';
import '../manufacturing/bom_screen.dart' show PickerFieldBox;
import 'wh_models.dart';
import 'wh_repository.dart';
import 'wh_widgets.dart';

List<String> _serials(String text) =>
    text.split(RegExp(r'[\s,;]+')).where((s) => s.isNotEmpty).toList();

/// Shared shell: a form, a busy flag, one save.
abstract class _WhFormState<T extends ConsumerStatefulWidget>
    extends ConsumerState<T> {
  final key = GlobalKey<FormState>();
  bool busy = false;

  String get title;
  String get action;
  List<Widget> fields();
  Future<void> submit(WhRepository repo);

  Future<void> save() async {
    if (!key.currentState!.validate()) return;
    setState(() => busy = true);
    final ok = await whGuarded(
      context,
      () => submit(ref.read(whRepositoryProvider)),
    );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(title),
    content: SizedBox(
      width: 440,
      child: Form(
        key: key,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: fields()),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).maybePop(),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: busy ? null : save, child: Text(action)),
    ],
  );
}

const _gap = SizedBox(height: Space.md);

mixin _ItemField<T extends ConsumerStatefulWidget> on _WhFormState<T> {
  String? itemId;
  String? itemName;

  Widget itemField() => PickerFieldBox(
    label: 'Item',
    value: itemName,
    onTap: () async {
      final item = await pickItem(context, ref, stockOnly: true);
      if (item != null) {
        setState(() {
          itemId = item.id;
          itemName = item.name;
        });
      }
    },
  );

  void needItem() {
    if (itemId == null) throw const MfgInputError('Choose an item.');
  }
}

/// Place unassigned stock (or move stock between bins) into a bin.
class PutawayDialog extends ConsumerStatefulWidget {
  const PutawayDialog({
    super.key,
    required this.locationId,
    required this.bins,
    this.row,
  });

  final String locationId;
  final List<WhBin> bins;

  /// A stock row to move; null puts away unassigned stock of a chosen item.
  final WhStockRow? row;

  @override
  ConsumerState<PutawayDialog> createState() => _PutawayDialogState();
}

class _PutawayDialogState extends _WhFormState<PutawayDialog> with _ItemField {
  final _qty = TextEditingController();
  final _serial = TextEditingController();
  String? _from;
  String? _to;

  @override
  void initState() {
    super.initState();
    final r = widget.row;
    if (r != null) {
      itemId = r.itemId;
      itemName = r.itemName;
      _from = r.binId;
      _qty.text = formatQty(r.qty);
    }
  }

  @override
  String get title => widget.row == null ? 'Put away stock' : 'Move stock';
  @override
  String get action => 'Put away';

  @override
  List<Widget> fields() {
    final active = widget.bins.where((b) => b.isActive).toList();
    return [
      if (widget.row == null)
        itemField()
      else
        Align(
          alignment: Alignment.centerLeft,
          child: Text(widget.row!.itemName),
        ),
      if (widget.row?.batchNo != null)
        Align(
          alignment: Alignment.centerLeft,
          child: Text('Batch ${widget.row!.batchNo}'),
        ),
      _gap,
      DropdownButtonFormField<String?>(
        key: ValueKey('from-$_from'),
        initialValue: _from,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'From'),
        items: [
          const DropdownMenuItem(value: null, child: Text('Unassigned stock')),
          for (final b in active)
            DropdownMenuItem(
              value: b.id,
              child: Text(b.label, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: widget.row == null ? (v) => setState(() => _from = v) : null,
      ),
      _gap,
      DropdownButtonFormField<String>(
        initialValue: _to,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'To bin'),
        items: [
          for (final b in active)
            DropdownMenuItem(
              value: b.id,
              child: Text(
                '${b.label}${b.isQuarantine ? ' (quarantine)' : ''}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: (v) => setState(() => _to = v),
        validator: (v) => v == null ? 'Choose a bin' : null,
      ),
      _gap,
      mfgNumberField(controller: _qty, label: 'Quantity'),
      _gap,
      TextFormField(
        controller: _serial,
        maxLines: 2,
        decoration: const InputDecoration(
          labelText: 'Serial numbers (serial items only)',
        ),
      ),
    ];
  }

  @override
  Future<void> submit(WhRepository repo) {
    needItem();
    final serials = _serials(_serial.text);
    final Json body = {
      'locationId': widget.locationId,
      'itemId': itemId,
      'fromBinId': ?_from,
      'toBinId': _to,
      'batchId': ?widget.row?.batchId,
      'qty': parseNumber(_qty.text.trim()),
      if (serials.isNotEmpty) 'serialNos': serials,
    };
    return repo.putaway(body);
  }
}

/// Receive stock into a bin, with its batch or serial numbers.
class ReceiveDialog extends ConsumerStatefulWidget {
  const ReceiveDialog({
    super.key,
    required this.locationId,
    required this.bins,
  });

  final String locationId;
  final List<WhBin> bins;

  @override
  ConsumerState<ReceiveDialog> createState() => _ReceiveDialogState();
}

class _ReceiveDialogState extends _WhFormState<ReceiveDialog> with _ItemField {
  final _qty = TextEditingController();
  final _batch = TextEditingController();
  final _mfg = TextEditingController();
  final _exp = TextEditingController();
  final _serial = TextEditingController();
  String? _bin;

  @override
  String get title => 'Receive into bin';
  @override
  String get action => 'Receive';

  @override
  List<Widget> fields() => [
    itemField(),
    _gap,
    DropdownButtonFormField<String?>(
      initialValue: _bin,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Bin'),
      items: [
        const DropdownMenuItem(value: null, child: Text('No bin')),
        for (final b in widget.bins.where((b) => b.isActive))
          DropdownMenuItem(
            value: b.id,
            child: Text(b.label, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (v) => setState(() => _bin = v),
    ),
    _gap,
    mfgNumberField(controller: _qty, label: 'Quantity'),
    _gap,
    TextFormField(
      controller: _batch,
      decoration: const InputDecoration(labelText: 'Batch number (optional)'),
    ),
    _gap,
    TextFormField(
      controller: _mfg,
      decoration: const InputDecoration(
        labelText: 'Made on',
        hintText: 'YYYY-MM-DD',
      ),
      validator: whDateError,
    ),
    _gap,
    TextFormField(
      controller: _exp,
      decoration: const InputDecoration(
        labelText: 'Expires on',
        hintText: 'YYYY-MM-DD',
      ),
      validator: whDateError,
    ),
    _gap,
    TextFormField(
      controller: _serial,
      maxLines: 2,
      decoration: const InputDecoration(
        labelText: 'Serial numbers (serial items only)',
      ),
    ),
  ];

  @override
  Future<void> submit(WhRepository repo) {
    needItem();
    final serials = _serials(_serial.text);
    final batchNo = _batch.text.trim();
    return repo.receive({
      'locationId': widget.locationId,
      'itemId': itemId,
      'binId': ?_bin,
      'qty': parseNumber(_qty.text.trim()),
      if (batchNo.isNotEmpty)
        'batch': {
          'batchNo': batchNo,
          if (_mfg.text.trim().isNotEmpty) 'mfgDate': _mfg.text.trim(),
          if (_exp.text.trim().isNotEmpty) 'expiryDate': _exp.text.trim(),
        },
      if (serials.isNotEmpty) 'serialNos': serials,
    });
  }
}
