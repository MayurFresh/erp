import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/json.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/states.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../auth/session.dart';
import '../construction/common/c_widgets.dart'
    show DateField, showSuccess, today;
import 'memberships_models.dart';
import 'memberships_repository.dart';
import 'pay_fields.dart';

/// Add or edit a plan. Pops the saved [MemPlan].
class PlanDialog extends ConsumerStatefulWidget {
  const PlanDialog({super.key, this.plan, required this.words});

  final MemPlan? plan;
  final MemWords words;

  @override
  ConsumerState<PlanDialog> createState() => _PlanDialogState();
}

class _PlanDialogState extends ConsumerState<PlanDialog>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.plan?.name);
  late final _price = TextEditingController(
    text: widget.plan == null ? null : formatPlain(widget.plan!.price),
  );
  late final _gst = TextEditingController(
    text: formatPlain(widget.plan?.gstRate ?? (widget.words.society ? 0 : 18)),
  );
  late final _join = TextEditingController(
    text: widget.plan == null ? '0' : formatPlain(widget.plan!.joiningFee),
  );
  late final _count = TextEditingController(
    text: '${widget.plan?.durationCount ?? 1}',
  );
  late final _freeze = TextEditingController(
    text: '${widget.plan?.freezeDays ?? 0}',
  );
  late String _unit = widget.plan?.durationUnit ?? 'months';
  late bool _monthly = widget.plan?.monthly ?? widget.words.society;
  late bool _perSqft = widget.plan?.perSqft ?? widget.words.society;
  late bool _active = widget.plan?.isActive ?? true;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_name, _price, _gst, _join, _count, _freeze]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => serverErrors = const {});
    if (!validateAndReveal(_formKey)) return;
    setState(() => _saving = true);
    try {
      final edit = widget.plan != null;
      final body = <String, Object?>{
        'name': _name.text.trim(),
        'price': parseNumber(_price.text),
        'joiningFee': parseNumber(_join.text) ?? 0,
        'freezeDays': int.tryParse(_freeze.text.trim()) ?? 0,
        'isActive': _active,
        if (!edit) ...{
          'billing': _monthly ? 'monthly' : 'upfront',
          'rateBasis': _perSqft ? 'per_sqft' : 'fixed',
          'durationUnit': _unit,
          'durationCount': int.tryParse(_count.text.trim()) ?? 1,
          'gstRate': parseNumber(_gst.text) ?? 0,
        },
        if (edit && widget.plan!.updatedAt != null)
          'expectedUpdatedAt': widget.plan!.updatedAt,
      };
      final saved = await ref
          .read(membershipsRepositoryProvider)
          .savePlan(widget.plan?.id, body);
      if (mounted) Navigator.of(context).pop(saved);
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final edit = widget.plan != null;
    final w = widget.words;
    return AlertDialog(
      title: Text(
        edit ? 'Edit ${w.plan.toLowerCase()}' : 'Add ${w.plan.toLowerCase()}',
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(
                    labelText: 'Name',
                    errorText: serverError('name'),
                  ),
                  validator: (v) => requiredField(v, 'Name'),
                ),
                const SizedBox(height: 12),
                if (!edit && !w.society) ...[
                  FormRow(
                    minCellWidth: 160,
                    children: [
                      TextFormField(
                        controller: _count,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Length'),
                        validator: (v) {
                          final n = int.tryParse((v ?? '').trim());
                          return n == null || n < 1 ? 'At least 1' : null;
                        },
                      ),
                      DropdownButtonFormField<String>(
                        initialValue: _unit,
                        decoration: const InputDecoration(labelText: 'Unit'),
                        items: const [
                          DropdownMenuItem(
                            value: 'months',
                            child: Text('Months'),
                          ),
                          DropdownMenuItem(value: 'days', child: Text('Days')),
                        ],
                        onChanged: (v) => setState(() => _unit = v ?? 'months'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
                FormRow(
                  minCellWidth: 160,
                  children: [
                    TextFormField(
                      controller: _price,
                      keyboardType: decimalKeyboard,
                      inputFormatters: [decimalInput()],
                      decoration: InputDecoration(
                        labelText: _perSqft
                            ? 'Rate per sq ft per month'
                            : 'Price',
                        errorText: serverError('price'),
                      ),
                      validator: (v) =>
                          requiredNumber(v, label: 'Price', min: 0),
                    ),
                    TextFormField(
                      controller: _gst,
                      enabled: !edit,
                      keyboardType: decimalKeyboard,
                      inputFormatters: [decimalInput()],
                      decoration: const InputDecoration(labelText: 'GST %'),
                      validator: (v) => requiredNumber(v, label: 'GST', min: 0),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                FormRow(
                  minCellWidth: 160,
                  children: [
                    TextFormField(
                      controller: _join,
                      keyboardType: decimalKeyboard,
                      inputFormatters: [decimalInput()],
                      decoration: const InputDecoration(
                        labelText: 'Joining fee',
                      ),
                      validator: (v) => optionalNumber(v, min: 0),
                    ),
                    if (!w.society)
                      TextFormField(
                        controller: _freeze,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Freeze days allowed',
                        ),
                      ),
                  ],
                ),
                if (!edit && w.society) ...[
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Rate per sq ft'),
                    subtitle: const Text('Billed as flat area times the rate.'),
                    value: _perSqft,
                    onChanged: (v) => setState(() {
                      _perSqft = v;
                      _monthly = true;
                    }),
                  ),
                ],
                if (edit)
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
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
          child: const Text('Cancel'),
        ),
        BusyButton(
          busy: _saving,
          onPressed: _saving ? null : _save,
          label: 'Save',
        ),
      ],
    );
  }
}

/// New member (or flat) with a plan, a first bill and an optional receipt.
class NewMemberDialog extends ConsumerStatefulWidget {
  const NewMemberDialog({super.key, required this.words, required this.plans});

  final MemWords words;
  final List<MemPlan> plans;

  @override
  ConsumerState<NewMemberDialog> createState() => _NewMemberDialogState();
}

class _NewMemberDialogState extends ConsumerState<NewMemberDialog>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _emName = TextEditingController();
  final _emPhone = TextEditingController();
  final _flat = TextEditingController();
  final _wing = TextEditingController();
  final _area = TextEditingController();
  final _pay = PayController();
  late MemPlan? _plan = widget.plans.where((p) => p.isActive).firstOrNull;
  DateTime _start = today();
  String _occupancy = 'owner';
  bool _bill = true;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_name, _phone, _emName, _emPhone, _flat, _wing, _area]) {
      c.dispose();
    }
    _pay.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => serverErrors = const {});
    if (!validateAndReveal(_formKey)) return;
    final plan = _plan;
    if (plan == null) {
      showErrorSnackBar(
        context,
        'Add a ${widget.words.plan.toLowerCase()} first.',
      );
      return;
    }
    final canBill = ref.read(permissionsProvider).can(Perm.invoicesCreate);
    final payment = _pay.body();
    setState(() => _saving = true);
    try {
      final out = await ref.read(membershipsRepositoryProvider).createMember({
        'name': _name.text.trim(),
        'phone': trimmedOrNull(_phone.text),
        'planId': plan.id,
        'startDate': apiDate(_start),
        'bill': _bill && canBill,
        if (widget.words.society) ...{
          'flatNo': trimmedOrNull(_flat.text),
          'wing': trimmedOrNull(_wing.text),
          'areaSqft': parseNumber(_area.text),
          'occupancy': _occupancy,
        } else ...{
          'emergencyName': trimmedOrNull(_emName.text),
          'emergencyPhone': trimmedOrNull(_emPhone.text),
        },
        if (payment != null && _bill && canBill) 'payment': payment,
      });
      if (mounted) Navigator.of(context).pop(out);
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.words;
    final perms = ref.watch(permissionsProvider);
    final canPay = perms.can(Perm.paymentsCreate) && _bill;
    final plans = widget.plans.where((p) => p.isActive).toList();
    return AlertDialog(
      title: Text(w.newMember),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(
                    labelText: w.society ? 'Name on the bill' : 'Name',
                    errorText: serverError('name'),
                  ),
                  validator: (v) => requiredField(v, 'Name'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(
                    labelText: 'Phone',
                    errorText: serverError('phone'),
                  ),
                ),
                const SizedBox(height: 12),
                if (w.society) ...[
                  FormRow(
                    minCellWidth: 120,
                    children: [
                      TextFormField(
                        controller: _wing,
                        decoration: const InputDecoration(labelText: 'Wing'),
                      ),
                      TextFormField(
                        controller: _flat,
                        decoration: const InputDecoration(
                          labelText: 'Flat number',
                        ),
                        validator: (v) => requiredField(v, 'Flat number'),
                      ),
                      TextFormField(
                        controller: _area,
                        keyboardType: decimalKeyboard,
                        inputFormatters: [decimalInput()],
                        decoration: InputDecoration(
                          labelText: 'Area (sq ft)',
                          errorText: serverError('areaSqft'),
                        ),
                        validator: (v) => (_plan?.perSqft ?? false)
                            ? requiredNumber(v, label: 'Area', min: 1)
                            : optionalNumber(v, min: 1),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'owner', label: Text('Owner')),
                      ButtonSegment(value: 'tenant', label: Text('Tenant')),
                    ],
                    selected: {_occupancy},
                    onSelectionChanged: (s) =>
                        setState(() => _occupancy = s.first),
                  ),
                  const SizedBox(height: 12),
                ] else ...[
                  FormRow(
                    children: [
                      TextFormField(
                        controller: _emName,
                        decoration: const InputDecoration(
                          labelText: 'Emergency contact',
                        ),
                      ),
                      TextFormField(
                        controller: _emPhone,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(
                          labelText: 'Emergency phone',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
                DropdownButtonFormField<String>(
                  initialValue: _plan?.id,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: w.plan),
                  items: [
                    for (final p in plans)
                      DropdownMenuItem(
                        value: p.id,
                        child: Text(
                          '${p.name}  |  ${formatMoney(p.price)}${p.perSqft ? ' per sq ft' : ''}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  validator: (v) =>
                      v == null ? 'Choose a ${w.plan.toLowerCase()}' : null,
                  onChanged: (v) => setState(
                    () => _plan = plans.firstWhere((p) => p.id == v),
                  ),
                ),
                const SizedBox(height: 12),
                DateField(
                  label: 'Start date',
                  value: _start,
                  onChanged: (d) => setState(() => _start = d),
                ),
                if (perms.can(Perm.invoicesCreate)) ...[
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Make the first bill'),
                    subtitle: Text(
                      (_plan?.joiningFee ?? 0) > 0
                          ? 'Includes the joining fee of ${formatMoney(_plan!.joiningFee)}.'
                          : 'Charges the first term.',
                    ),
                    value: _bill,
                    onChanged: (v) => setState(() => _bill = v),
                  ),
                ],
                if (canPay)
                  PayFields(
                    controller: _pay,
                    helper: 'Leave empty to bill only',
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
          child: const Text('Cancel'),
        ),
        BusyButton(
          busy: _saving,
          onPressed: _saving ? null : _save,
          label: 'Save',
        ),
      ],
    );
  }
}

/// Renew a member from the old end date (or today when lapsed).
class RenewDialog extends ConsumerStatefulWidget {
  const RenewDialog({
    super.key,
    required this.member,
    required this.plans,
    this.currentPlanId,
  });

  final MemberBrief member;
  final List<MemPlan> plans;
  final String? currentPlanId;

  @override
  ConsumerState<RenewDialog> createState() => _RenewDialogState();
}

class _RenewDialogState extends ConsumerState<RenewDialog> {
  final _pay = PayController();
  late String? _planId =
      widget.plans.any((p) => p.id == widget.currentPlanId && p.isActive)
      ? widget.currentPlanId
      : widget.plans.where((p) => p.isActive).firstOrNull?.id;
  bool _saving = false;

  @override
  void dispose() {
    _pay.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final perms = ref.read(permissionsProvider);
    final payment = perms.can(Perm.paymentsCreate) ? _pay.body() : null;
    setState(() => _saving = true);
    try {
      final out = await ref.read(membershipsRepositoryProvider).renew(
        widget.member.id,
        {
          'planId': _planId,
          'bill': perms.can(Perm.invoicesCreate),
          'payment': ?payment,
        },
      );
      if (mounted) Navigator.of(context).pop(out);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final plans = widget.plans.where((p) => p.isActive).toList();
    final perms = ref.watch(permissionsProvider);
    final m = widget.member;
    final lapsed = m.status == 'expired' || m.status == 'none';
    return AlertDialog(
      title: Text('Renew ${m.name}'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                lapsed || m.endDate == null
                    ? 'The new term starts today.'
                    : 'The new term starts the day after ${formatDate(m.endDate)}.',
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _planId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Plan'),
                items: [
                  for (final p in plans)
                    DropdownMenuItem(
                      value: p.id,
                      child: Text(
                        '${p.name}  |  ${formatMoney(p.price)}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (v) => setState(() => _planId = v),
              ),
              if (perms.can(Perm.invoicesCreate) &&
                  perms.can(Perm.paymentsCreate)) ...[
                const SizedBox(height: 12),
                PayFields(controller: _pay, helper: 'Leave empty to bill only'),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
          child: const Text('Cancel'),
        ),
        BusyButton(
          busy: _saving,
          onPressed: _saving || _planId == null ? null : _save,
          label: 'Renew',
        ),
      ],
    );
  }
}

/// Take a receipt against a member's open bills.
class CollectDialog extends ConsumerStatefulWidget {
  const CollectDialog({
    super.key,
    required this.memberId,
    required this.name,
    required this.due,
  });

  final String memberId;
  final String name;
  final double due;

  @override
  ConsumerState<CollectDialog> createState() => _CollectDialogState();
}

class _CollectDialogState extends ConsumerState<CollectDialog> {
  final _pay = PayController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _pay.amount.text = formatPlain(widget.due);
  }

  @override
  void dispose() {
    _pay.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final body = _pay.body();
    if (body == null || _pay.accountId == null) {
      showErrorSnackBar(context, 'Enter the amount and the account.');
      return;
    }
    if (_pay.value > widget.due + 0.004) {
      showErrorSnackBar(context, 'Dues are only ${formatMoney(widget.due)}.');
      return;
    }
    setState(() => _saving = true);
    try {
      await ref
          .read(membershipsRepositoryProvider)
          .collect(widget.memberId, body);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Collect from ${widget.name}'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Dues ${formatMoney(widget.due)}. Oldest bills are cleared first.',
            ),
            const SizedBox(height: 12),
            PayFields(controller: _pay),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
        child: const Text('Cancel'),
      ),
      BusyButton(
        busy: _saving,
        onPressed: _saving ? null : _save,
        label: 'Receive',
      ),
    ],
  );
}

/// Shows a snackbar for a finished enrolment.
void announceEnrolment(BuildContext context, Json out) {
  final inv = asJsonOrNull(out['invoice']);
  showSuccess(
    context,
    inv == null
        ? '${asString(out['memberNo'])} added'
        : '${asString(out['memberNo'])} added. Bill ${asString(inv['number'])} for ${formatMoney(asDouble(inv['total']))}',
  );
}

/// Edit a member's details and photo. Pops the new member JSON.
class EditMemberDialog extends ConsumerStatefulWidget {
  const EditMemberDialog({super.key, required this.file, required this.words});

  final MemberFile file;
  final MemWords words;

  @override
  ConsumerState<EditMemberDialog> createState() => _EditMemberDialogState();
}

class _EditMemberDialogState extends ConsumerState<EditMemberDialog>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.file.brief.name);
  late final _phone = TextEditingController(text: widget.file.brief.phone);
  late final _emName = TextEditingController(text: widget.file.emergencyName);
  late final _emPhone = TextEditingController(text: widget.file.emergencyPhone);
  late final _wing = TextEditingController(text: widget.file.brief.wing);
  late final _flat = TextEditingController(text: widget.file.brief.flatNo);
  late final _area = TextEditingController(
    text: widget.file.brief.areaSqft == null
        ? null
        : formatPlain(widget.file.brief.areaSqft),
  );
  late final _notes = TextEditingController(text: widget.file.notes);
  late String _occupancy = widget.file.occupancy ?? 'owner';
  late String? _photoId = widget.file.brief.photoFileId;
  Uint8List? _photo;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final id = _photoId;
    if (id != null) {
      ref
          .read(membershipsRepositoryProvider)
          .photoBytes(id)
          .then((b) {
            if (mounted) setState(() => _photo = b);
          })
          .catchError((_) {});
    }
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _phone,
      _emName,
      _emPhone,
      _wing,
      _flat,
      _area,
      _notes,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    try {
      final f = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp'],
      );
      if (f == null) return;
      final ext = f.name.split('.').last.toLowerCase();
      final mime = switch (ext) {
        'png' => 'image/png',
        'webp' => 'image/webp',
        _ => 'image/jpeg',
      };
      final bytes = await f.readAsBytes();
      final id = await ref
          .read(membershipsRepositoryProvider)
          .uploadPhoto(bytes, f.name, mime);
      if (mounted) {
        setState(() {
          _photoId = id;
          _photo = bytes;
        });
      }
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _save() async {
    setState(() => serverErrors = const {});
    if (!validateAndReveal(_formKey)) return;
    final b = widget.file.brief;
    setState(() => _saving = true);
    try {
      final out = await ref.read(membershipsRepositoryProvider).updateMember(
        b.id,
        {
          'name': _name.text.trim(),
          'phone': _phone.text.trim(),
          'notes': _notes.text.trim(),
          if (_photoId != null && _photoId != b.photoFileId)
            'photoFileId': _photoId,
          if (widget.words.society) ...{
            'flatNo': _flat.text.trim(),
            'wing': _wing.text.trim(),
            'areaSqft': parseNumber(_area.text) ?? '',
            'occupancy': _occupancy,
          } else ...{
            'emergencyName': _emName.text.trim(),
            'emergencyPhone': _emPhone.text.trim(),
          },
        },
      );
      if (mounted) Navigator.of(context).pop(out);
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.words;
    return AlertDialog(
      title: Text('Edit ${w.society ? 'flat' : 'member'}'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!w.society) ...[
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 28,
                        backgroundImage: _photo == null
                            ? null
                            : MemoryImage(_photo!),
                        child: _photo == null
                            ? const Icon(Icons.person_outline)
                            : null,
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: _saving ? null : _pickPhoto,
                        icon: const Icon(Icons.photo_camera_outlined),
                        label: Text(
                          _photoId == null ? 'Add photo' : 'Change photo',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
                TextFormField(
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(
                    labelText: w.society ? 'Name on the bill' : 'Name',
                    errorText: serverError('name'),
                  ),
                  validator: (v) => requiredField(v, 'Name'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(
                    labelText: 'Phone',
                    errorText: serverError('phone'),
                  ),
                ),
                const SizedBox(height: 12),
                if (w.society) ...[
                  FormRow(
                    minCellWidth: 120,
                    children: [
                      TextFormField(
                        controller: _wing,
                        decoration: const InputDecoration(labelText: 'Wing'),
                      ),
                      TextFormField(
                        controller: _flat,
                        decoration: const InputDecoration(
                          labelText: 'Flat number',
                        ),
                        validator: (v) => requiredField(v, 'Flat number'),
                      ),
                      TextFormField(
                        controller: _area,
                        keyboardType: decimalKeyboard,
                        inputFormatters: [decimalInput()],
                        decoration: InputDecoration(
                          labelText: 'Area (sq ft)',
                          errorText: serverError('areaSqft'),
                        ),
                        validator: (v) => optionalNumber(v, min: 1),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'owner', label: Text('Owner')),
                      ButtonSegment(value: 'tenant', label: Text('Tenant')),
                    ],
                    selected: {_occupancy},
                    onSelectionChanged: (s) =>
                        setState(() => _occupancy = s.first),
                  ),
                ] else
                  FormRow(
                    children: [
                      TextFormField(
                        controller: _emName,
                        decoration: const InputDecoration(
                          labelText: 'Emergency contact',
                        ),
                      ),
                      TextFormField(
                        controller: _emPhone,
                        keyboardType: TextInputType.phone,
                        decoration: InputDecoration(
                          labelText: 'Emergency phone',
                          errorText: serverError('emergencyPhone'),
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _notes,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: 'Notes'),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
          child: const Text('Cancel'),
        ),
        BusyButton(
          busy: _saving,
          onPressed: _save,
          label: 'Save',
          icon: Icons.check,
        ),
      ],
    );
  }
}
