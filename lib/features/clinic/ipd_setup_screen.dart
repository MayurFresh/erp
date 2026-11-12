import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import 'clinic_repository.dart';
import 'clinic_widgets.dart';
import 'ipd_models.dart';

/// `/clinic/ipd/setup`: wards, beds and the daily rate of each bed.
class IpdSetupScreen extends ConsumerWidget {
  const IpdSetupScreen({super.key});

  Future<void> _ward(BuildContext context, WidgetRef ref, [IpdWard? w]) async {
    final ok = await showFormDialog<bool>(
      context: context,
      builder: (_) => _WardDialog(ward: w),
    );
    if (ok == true) ref.bumpClinic(const [ClinicKind.ipd]);
  }

  Future<void> _bed(
    BuildContext context,
    WidgetRef ref,
    IpdWard w, [
    IpdBed? b,
  ]) async {
    final ok = await showFormDialog<bool>(
      context: context,
      builder: (_) => _BedDialog(ward: w, bed: b),
    );
    if (ok == true) ref.bumpClinic(const [ClinicKind.ipd]);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gutter = pageGutter(context);
    return CGate(
      anyOf: const [Perm.clinicIpdManage],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Wards and beds',
            actions: [
              OutlinedButton.icon(
                style: bigOutlinedButton,
                onPressed: () => context.go('/clinic/ipd'),
                icon: const Icon(Icons.arrow_back),
                label: const Text('Bed board'),
              ),
              FilledButton.icon(
                style: bigButton,
                onPressed: () => _ward(context, ref),
                icon: const Icon(Icons.add),
                label: const Text('Add ward'),
              ),
            ],
          ),
          Expanded(
            child: AsyncValueView<List<IpdWard>>(
              value: ref.watch(ipdWardsProvider),
              onRetry: () => ref.invalidate(ipdWardsProvider),
              data: (wards) => wards.isEmpty
                  ? const EmptyView(
                      icon: Icons.bed_outlined,
                      message: 'No wards yet. Add the first ward.',
                    )
                  : ListView(
                      padding: EdgeInsets.fromLTRB(gutter, 0, gutter, 24),
                      children: [
                        for (final w in wards)
                          Card(
                            key: ValueKey('ward-${w.id}'),
                            margin: const EdgeInsets.only(bottom: 10),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          '${w.name}  (${wardKindLabel(w.kind)})',
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleMedium,
                                        ),
                                      ),
                                      if (!w.isActive) const Pill('Off'),
                                      IconButton(
                                        tooltip: 'Edit ${w.name}',
                                        onPressed: () => _ward(context, ref, w),
                                        icon: const Icon(Icons.edit_outlined),
                                      ),
                                    ],
                                  ),
                                  for (final b in w.beds)
                                    ListTile(
                                      key: ValueKey('setup-bed-${b.id}'),
                                      contentPadding: EdgeInsets.zero,
                                      onTap: () => _bed(context, ref, w, b),
                                      title: Text('Bed ${b.bedNo}'),
                                      subtitle: Text(
                                        '${formatMoney(b.dailyRate)} a day  |  ${b.status.label}${b.isActive ? '' : '  |  Off'}',
                                      ),
                                      trailing: const Icon(
                                        Icons.edit_outlined,
                                        size: 18,
                                      ),
                                    ),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: TextButton.icon(
                                      onPressed: () => _bed(context, ref, w),
                                      icon: const Icon(Icons.add),
                                      label: const Text('Add bed'),
                                    ),
                                  ),
                                ],
                              ),
                            ),
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

class _WardDialog extends ConsumerStatefulWidget {
  const _WardDialog({this.ward});

  final IpdWard? ward;

  @override
  ConsumerState<_WardDialog> createState() => _WardDialogState();
}

class _WardDialogState extends ConsumerState<_WardDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.ward?.name);
  late String _kind = widget.ward?.kind ?? 'general';
  late bool _active = widget.ward?.isActive ?? true;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!validateAndReveal(_formKey)) return;
    setState(() => _saving = true);
    try {
      await ref.read(clinicRepositoryProvider).saveWard(widget.ward?.id, {
        'name': _name.text.trim(),
        'kind': _kind,
        'isActive': _active,
      });
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.ward == null ? 'Add ward' : 'Edit ward'),
    content: SizedBox(
      width: 420,
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _name,
              autofocus: widget.ward == null,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Ward name'),
              validator: (v) => requiredField(v, 'Name'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _kind,
              decoration: const InputDecoration(labelText: 'Type'),
              items: [
                for (final k in wardKinds)
                  DropdownMenuItem(value: k, child: Text(wardKindLabel(k))),
              ],
              onChanged: (v) => setState(() => _kind = v ?? 'general'),
            ),
            if (widget.ward != null)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('In use'),
                value: _active,
                onChanged: (v) => setState(() => _active = v),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
        child: const Text('Cancel'),
      ),
      BusyButton(busy: _saving, onPressed: _save, label: 'Save'),
    ],
  );
}

class _BedDialog extends ConsumerStatefulWidget {
  const _BedDialog({required this.ward, this.bed});

  final IpdWard ward;
  final IpdBed? bed;

  @override
  ConsumerState<_BedDialog> createState() => _BedDialogState();
}

class _BedDialogState extends ConsumerState<_BedDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _no = TextEditingController(text: widget.bed?.bedNo);
  late final _rate = TextEditingController(
    text: widget.bed == null ? null : formatPlain(widget.bed!.dailyRate),
  );
  late bool _active = widget.bed?.isActive ?? true;
  late String? _status = switch (widget.bed?.status) {
    BedStatus.available => 'available',
    BedStatus.cleaning => 'cleaning',
    BedStatus.maintenance => 'maintenance',
    _ => null,
  };
  bool _saving = false;

  bool get _occupied => widget.bed?.status == BedStatus.occupied;

  @override
  void dispose() {
    _no.dispose();
    _rate.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!validateAndReveal(_formKey)) return;
    setState(() => _saving = true);
    try {
      final editing = widget.bed != null;
      await ref.read(clinicRepositoryProvider).saveBed(widget.bed?.id, {
        if (!editing) 'wardId': widget.ward.id,
        'bedNo': _no.text.trim(),
        'dailyRate': parseNumber(_rate.text),
        'isActive': _active,
        if (editing && !_occupied && _status != null) 'status': _status,
      });
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.bed == null
          ? 'Add bed to ${widget.ward.name}'
          : 'Edit bed ${widget.bed!.bedNo}',
    ),
    content: SizedBox(
      width: 420,
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _no,
              autofocus: widget.bed == null,
              decoration: const InputDecoration(labelText: 'Bed number'),
              validator: (v) => requiredField(v, 'Bed number'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _rate,
              keyboardType: decimalKeyboard,
              inputFormatters: [decimalInput()],
              decoration: const InputDecoration(labelText: 'Daily rate'),
              validator: (v) =>
                  parseNumber(v ?? '') == null ? 'Enter the daily rate' : null,
            ),
            if (widget.bed != null && !_occupied) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _status,
                decoration: const InputDecoration(labelText: 'Status'),
                items: const [
                  DropdownMenuItem(value: 'available', child: Text('Free')),
                  DropdownMenuItem(value: 'cleaning', child: Text('Cleaning')),
                  DropdownMenuItem(
                    value: 'maintenance',
                    child: Text('Maintenance'),
                  ),
                ],
                onChanged: (v) => setState(() => _status = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('In use'),
                value: _active,
                onChanged: (v) => setState(() => _active = v),
              ),
            ],
            if (_occupied)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('A patient is in this bed. Only the rate changes.'),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
        child: const Text('Cancel'),
      ),
      BusyButton(busy: _saving, onPressed: _save, label: 'Save'),
    ],
  );
}
