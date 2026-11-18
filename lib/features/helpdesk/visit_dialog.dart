import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/json.dart';
import '../../widgets/form_support.dart';
import '../construction/data/photo_source.dart';
import '../items/item_picker.dart';
import '../locations/locations_repository.dart';
import 'signature_pad.dart';

/// What the engineer entered when finishing a visit.
class VisitResult {
  const VisitResult({
    required this.notes,
    required this.parts,
    required this.locationId,
    required this.signatureName,
    required this.signaturePng,
    required this.photos,
  });

  final String? notes;
  final List<Json> parts;
  final String? locationId;
  final String? signatureName;
  final Uint8List? signaturePng;
  final List<PickedPhoto> photos;
}

class _Part {
  _Part({
    this.itemId,
    required this.name,
    required this.qty,
    this.stocked = false,
  });
  final String? itemId;
  final String name;
  double qty;
  final bool stocked;
}

/// Finish-visit form: work done, parts (stocked parts leave a chosen location), photos and a signature.
class VisitDialog extends ConsumerStatefulWidget {
  const VisitDialog({
    super.key,
    required this.dueDate,
    this.partsOnly = false,
    this.initialParts = const [],
    this.initialLocationId,
  });

  final String dueDate;

  /// Edit the parts of a finished visit: no notes, photos or signature.
  final bool partsOnly;
  final List<Json> initialParts;
  final String? initialLocationId;

  @override
  ConsumerState<VisitDialog> createState() => _VisitDialogState();
}

class _VisitDialogState extends ConsumerState<VisitDialog> {
  final _notes = TextEditingController();
  final _name = TextEditingController();
  final _pad = SignatureController();
  final _parts = <_Part>[];
  final _photos = <PickedPhoto>[];
  String? _locationId;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _locationId = widget.initialLocationId;
    for (final p in widget.initialParts) {
      final id = asStringOrNull(p['itemId']);
      _parts.add(
        _Part(
          itemId: id,
          name: asString(p['name']),
          qty: asDouble(p['qty']),
          stocked: id != null,
        ),
      );
    }
  }

  @override
  void dispose() {
    _notes.dispose();
    _name.dispose();
    _pad.dispose();
    super.dispose();
  }

  Future<void> _addPart() async {
    final item = await pickItem(context, ref);
    if (item == null) return;
    setState(
      () => _parts.add(
        _Part(
          itemId: item.id,
          name: item.name,
          qty: 1,
          stocked: item.trackStock,
        ),
      ),
    );
  }

  Future<void> _addPhoto() async {
    final source = ref.read(photoSourceProvider);
    if (source.unavailableMessage != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(source.unavailableMessage!)));
      return;
    }
    final p = await source.pick(camera: source.supportsCamera);
    if (p != null && mounted && _photos.length < 8) {
      setState(() => _photos.add(p));
    }
  }

  Future<void> _done() async {
    setState(() => _saving = true);
    final png = await _pad.toPng();
    if (!mounted) return;
    Navigator.of(context).pop(
      VisitResult(
        notes: trimmedOrNull(_notes.text),
        parts: [
          for (final p in _parts)
            {
              if (p.itemId != null) 'itemId': p.itemId,
              'name': p.name,
              'qty': p.qty,
            },
        ],
        locationId: _parts.any((p) => p.stocked) ? _locationId : null,
        signatureName: trimmedOrNull(_name.text),
        signaturePng: png,
        photos: List.of(_photos),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final needsLocation = _parts.any((p) => p.stocked);
    final locations =
        ref.watch(locationsLookupProvider).asData?.value ?? const [];
    return AlertDialog(
      scrollable: true,
      insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
      title: Text(
        widget.partsOnly
            ? 'Parts for visit due ${widget.dueDate}'
            : 'Visit due ${widget.dueDate}',
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!widget.partsOnly) ...[
              TextField(
                controller: _notes,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(labelText: 'Work done'),
              ),
              const SizedBox(height: 16),
            ],
            Text('Parts used', style: Theme.of(context).textTheme.titleSmall),
            for (var i = 0; i < _parts.length; i++)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _parts[i].name,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Fewer',
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    onPressed: _parts[i].qty > 1
                        ? () => setState(() => _parts[i].qty -= 1)
                        : null,
                    icon: const Icon(Icons.remove),
                  ),
                  Text(
                    _parts[i].qty.toStringAsFixed(
                      _parts[i].qty % 1 == 0 ? 0 : 1,
                    ),
                  ),
                  IconButton(
                    tooltip: 'More',
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    onPressed: () => setState(() => _parts[i].qty += 1),
                    icon: const Icon(Icons.add),
                  ),
                  IconButton(
                    tooltip: 'Remove part',
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    onPressed: () => setState(() => _parts.removeAt(i)),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _addPart,
                icon: const Icon(Icons.add),
                label: const Text('Add part'),
              ),
            ),
            if (needsLocation)
              DropdownButtonFormField<String>(
                initialValue: _locationId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Take stock from'),
                items: [
                  for (final l in locations)
                    DropdownMenuItem(
                      value: l.id,
                      child: Text(l.name, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) => setState(() => _locationId = v),
              ),
            if (!widget.partsOnly) ...[
              const SizedBox(height: 12),
              Text('Photos', style: Theme.of(context).textTheme.titleSmall),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (var i = 0; i < _photos.length; i++)
                    InputChip(
                      label: Text(
                        _photos[i].name,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onDeleted: () => setState(() => _photos.removeAt(i)),
                    ),
                  TextButton.icon(
                    onPressed: _addPhoto,
                    icon: const Icon(Icons.photo_camera_outlined),
                    label: const Text('Add photo'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Customer signature',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  TextButton(onPressed: _pad.clear, child: const Text('Clear')),
                ],
              ),
              SignaturePad(controller: _pad),
              const SizedBox(height: 12),
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Customer name (signed by)',
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _done,
          child: Text(widget.partsOnly ? 'Save parts' : 'Mark done'),
        ),
      ],
    );
  }
}
