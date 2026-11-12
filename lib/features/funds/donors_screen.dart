import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_exception.dart';
import '../../core/json.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/search_field.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../construction/common/c_widgets.dart'
    show CGate, bigButton, showSuccess;
import 'donations_home_screen.dart' show donationViewPerms;
import 'funds_models.dart';
import 'funds_repository.dart';
import 'funds_widgets.dart';

/// `/donations/donors`: find, add and edit donors; open a yearly statement.
class DonorsScreen extends ConsumerStatefulWidget {
  const DonorsScreen({super.key});

  @override
  ConsumerState<DonorsScreen> createState() => _DonorsScreenState();
}

class _DonorsScreenState extends ConsumerState<DonorsScreen> {
  String _q = '';

  Future<void> _edit([Donor? d]) async {
    final saved = await showFormDialog<Donor>(
      context: context,
      builder: (_) => DonorDialog(donor: d),
    );
    if (saved != null && mounted) {
      ref.bumpFunds();
      showSuccess(context, '${saved.name} saved');
    }
  }

  @override
  Widget build(BuildContext context) {
    final create = ref.watch(permissionsProvider).canAny(const [
      Perm.donationsCreate,
      Perm.donationsManage,
    ]);
    return CGate(
      anyOf: donationViewPerms,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Donors',
            actions: [
              if (create)
                FilledButton.icon(
                  key: const ValueKey('add-donor'),
                  style: bigButton,
                  onPressed: _edit,
                  icon: const Icon(Icons.add),
                  label: const Text('Add donor'),
                ),
            ],
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: pageGutter(context)),
            child: SearchField(
              hintText: 'Name, phone or PAN',
              onChanged: (v) => setState(() => _q = v),
            ),
          ),
          Expanded(
            child: AsyncValueView<List<Donor>>(
              value: ref.watch(donorsProvider(_q)),
              onRetry: () => ref.invalidate(donorsProvider(_q)),
              data: (list) => list.isEmpty
                  ? const EmptyNote('No donors found.')
                  : Gutter(
                      children: [
                        for (final d in list)
                          Card(
                            margin: EdgeInsets.zero,
                            child: ListTile(
                              key: ValueKey('donor-${d.id}'),
                              onTap: () => showDialog<void>(
                                context: context,
                                builder: (_) => StatementDialog(donor: d),
                              ),
                              title: Text(d.name),
                              subtitle: Text(
                                [
                                  if ((d.phone ?? '').isNotEmpty) d.phone!,
                                  if ((d.pan ?? '').isNotEmpty) d.pan!,
                                  if ((d.aadhaarMasked ?? '').isNotEmpty)
                                    d.aadhaarMasked!,
                                  if (!d.hasId) 'No PAN or Aadhaar',
                                ].join('  |  '),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Text(
                                        formatAmount(d.donated),
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleSmall,
                                      ),
                                      Text(
                                        '${d.donations} gift${d.donations == 1 ? '' : 's'}',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodySmall,
                                      ),
                                    ],
                                  ),
                                  if (create)
                                    IconButton(
                                      key: ValueKey('donor-edit-${d.id}'),
                                      tooltip: 'Edit donor',
                                      icon: const Icon(Icons.edit_outlined),
                                      onPressed: () => _edit(d),
                                    ),
                                ],
                              ),
                              onLongPress: create ? () => _edit(d) : null,
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

/// Add or edit a donor. Pops the saved [Donor]. A duplicate PAN stops the save; a duplicate name and phone asks first.
class DonorDialog extends ConsumerStatefulWidget {
  const DonorDialog({super.key, this.donor});

  final Donor? donor;

  @override
  ConsumerState<DonorDialog> createState() => _DonorDialogState();
}

class _DonorDialogState extends ConsumerState<DonorDialog>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.donor?.name);
  late final _phone = TextEditingController(text: widget.donor?.phone);
  late final _pan = TextEditingController(text: widget.donor?.pan);
  final _aadhaar = TextEditingController();
  late final _email = TextEditingController(text: widget.donor?.email);
  late final _address = TextEditingController(text: widget.donor?.address);
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_name, _phone, _pan, _aadhaar, _email, _address]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save({bool force = false}) async {
    setState(() => serverErrors = const {});
    if (!validateAndReveal(_formKey)) return;
    setState(() => _saving = true);
    final editing = widget.donor != null;
    try {
      String? clean(String t) => trimmedOrNull(t);
      final body = <String, Object?>{
        'name': _name.text.trim(),
        'phone': editing ? (clean(_phone.text) ?? '') : clean(_phone.text),
        'pan': editing
            ? (clean(_pan.text)?.toUpperCase() ?? '')
            : clean(_pan.text)?.toUpperCase(),
        if (!editing || _aadhaar.text.trim().isNotEmpty)
          'aadhaar': clean(_aadhaar.text),
        'email': editing ? (clean(_email.text) ?? '') : clean(_email.text),
        'address': editing
            ? (clean(_address.text) ?? '')
            : clean(_address.text),
        if (editing)
          'expectedUpdatedAt': widget.donor!.updatedAt
        else if (force)
          'force': true,
      };
      final saved = await ref
          .read(fundsRepositoryProvider)
          .saveDonor(widget.donor?.id, body);
      if (mounted) Navigator.of(context).pop(saved);
    } catch (e) {
      if (e is ApiException &&
          e.code == 'DUPLICATE_DONOR' &&
          !(e.details['matches'] is List &&
              (e.details['matches'] as List).any(
                (m) => asJson(m)['phone'] == null,
              ))) {
        if (mounted && await _confirmDuplicate(e) && mounted) {
          setState(() => _saving = false);
          return _save(force: true);
        }
      } else if (mounted) {
        showSubmitError(e);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _confirmDuplicate(ApiException e) async =>
      await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Possible duplicate'),
          content: Text('${e.message}\nSave anyway?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Go back'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Save anyway'),
            ),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.donor == null ? 'Add donor' : 'Edit donor'),
    content: SizedBox(
      width: 540,
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                key: const ValueKey('donor-name'),
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: 'Name',
                  errorText: serverError('name'),
                ),
                validator: (v) => requiredField(v, 'Name'),
              ),
              const SizedBox(height: 12),
              FormRow(
                minCellWidth: 180,
                children: [
                  TextFormField(
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    decoration: InputDecoration(
                      labelText: 'Phone',
                      errorText: serverError('phone'),
                    ),
                  ),
                  TextFormField(
                    controller: _pan,
                    textCapitalization: TextCapitalization.characters,
                    decoration: InputDecoration(
                      labelText: 'PAN',
                      errorText: serverError('pan'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              FormRow(
                minCellWidth: 180,
                children: [
                  TextFormField(
                    controller: _aadhaar,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: widget.donor?.aadhaarMasked == null
                          ? 'Aadhaar (if no PAN)'
                          : 'Aadhaar (${widget.donor!.aadhaarMasked})',
                      errorText: serverError('aadhaar'),
                    ),
                  ),
                  TextFormField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    decoration: InputDecoration(
                      labelText: 'Email',
                      errorText: serverError('email'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _address,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: 'Address',
                  errorText: serverError('address'),
                ),
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

/// A donor's gifts in one financial year.
class StatementDialog extends ConsumerStatefulWidget {
  const StatementDialog({super.key, required this.donor});

  final Donor donor;

  @override
  ConsumerState<StatementDialog> createState() => _StatementDialogState();
}

class _StatementDialogState extends ConsumerState<StatementDialog> {
  late String _fy = currentFy();
  Future<Json>? _future;

  @override
  Widget build(BuildContext context) {
    _future ??= ref
        .read(fundsRepositoryProvider)
        .statement(widget.donor.id, _fy);
    return AlertDialog(
      title: Text(widget.donor.name),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FySelector(
              value: _fy,
              onChanged: (v) => setState(() {
                _fy = v;
                _future = ref
                    .read(fundsRepositoryProvider)
                    .statement(widget.donor.id, v);
              }),
            ),
            const SizedBox(height: 10),
            Flexible(
              child: FutureBuilder<Json>(
                future: _future,
                builder: (context, snap) {
                  if (snap.hasError) return Text('${snap.error}');
                  final j = snap.data;
                  if (j == null) {
                    return const Padding(
                      padding: EdgeInsets.all(16),
                      child: LoadingView(),
                    );
                  }
                  final rows = asJsonList(j['data']);
                  return ListView(
                    shrinkWrap: true,
                    children: [
                      if (rows.isEmpty)
                        const Text('No donations in this year.'),
                      for (final r in rows)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            '${asString(r['receiptNo'])}  |  ${formatDate(r['date'])}',
                          ),
                          subtitle: Text(
                            donationModes[asString(r['mode'])] ??
                                asString(r['mode']),
                          ),
                          trailing: Text(formatAmount(asDouble(r['amount']))),
                        ),
                      const Divider(),
                      FigureRow([
                        Figure('Total', formatAmount(asDouble(j['total']))),
                        Figure(
                          'Eligible for 80G',
                          formatAmount(asDouble(j['eligibleFor80g'])),
                        ),
                      ]),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
