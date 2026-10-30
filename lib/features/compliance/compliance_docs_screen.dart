import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../widgets/filter_dropdown.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_controller.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../locations/locations_repository.dart';
import 'compliance_models.dart';
import 'compliance_repository.dart';
import 'compliance_widgets.dart';
import 'tax_perms.dart';

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

String _daysText(ComplianceDoc d) {
  final n = d.daysLeft;
  if (n == null) return 'No expiry';
  if (n < 0) return 'Expired ${-n} ${n == -1 ? 'day' : 'days'} ago';
  return '$n ${n == 1 ? 'day' : 'days'} left';
}

/// `/compliance-docs`: licences and registrations with expiry reminders.
class ComplianceDocsScreen extends ConsumerStatefulWidget {
  const ComplianceDocsScreen({super.key});

  @override
  ConsumerState<ComplianceDocsScreen> createState() =>
      _ComplianceDocsScreenState();
}

class _ComplianceDocsScreenState extends ConsumerState<ComplianceDocsScreen> {
  late final PagedController<ComplianceDoc> _c;
  String? _status;
  String? _category;

  @override
  void initState() {
    super.initState();
    _c = PagedController<ComplianceDoc>(
      (offset, limit) => ref
          .read(complianceRepositoryProvider)
          .docs(
            status: _status,
            category: _category,
            offset: offset,
            limit: limit,
          ),
    )..refresh();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(complianceRevisionProvider, (_, _) => _c.refresh());
    final manage = ref.watch(permissionsProvider).can(TaxPerm.complianceManage);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Licences & registrations',
          subtitle:
              'Expiry reminders for documents the business must keep valid',
          actions: [
            if (manage)
              FilledButton.icon(
                onPressed: () => context.go('/compliance-docs/new'),
                icon: const Icon(Icons.add),
                label: const Text('Add document'),
              ),
          ],
        ),
        FilterBar(
          children: [
            FilterDropdown<String>(
              label: 'Status',
              value: _status,
              options: const {
                'valid': 'Valid',
                'expiring': 'Expiring',
                'expired': 'Expired',
                'no_expiry': 'No expiry',
              },
              anyLabel: 'Any status',
              width: 170,
              onChanged: (v) {
                _status = v;
                _c.refresh();
              },
            ),
            FilterDropdown<String>(
              label: 'Category',
              value: _category,
              options: {for (final c in complianceCategories) c: _cap(c)},
              anyLabel: 'All categories',
              width: 190,
              onChanged: (v) {
                _category = v;
                _c.refresh();
              },
            ),
          ],
        ),
        Expanded(
          child: ListenableBuilder(
            listenable: _c,
            builder: (context, _) {
              if (_c.items.isEmpty) {
                if (_c.loading || !_c.loaded) return const LoadingView();
                if (_c.error != null) {
                  return ErrorView(error: _c.error!, onRetry: _c.refresh);
                }
                return const EmptyView(
                  message: 'No documents yet.',
                  icon: Icons.badge_outlined,
                );
              }
              return RefreshIndicator(
                onRefresh: _c.refresh,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                  children: [
                    for (final d in _c.items)
                      Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          onTap: () => context.go('/compliance-docs/${d.id}'),
                          title: Wrap(
                            spacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(d.name),
                              StatusPill(
                                d.status == 'no_expiry' ? 'info' : d.status,
                                label: _daysText(d),
                              ),
                            ],
                          ),
                          subtitle: Text(
                            [
                              _cap(d.category),
                              if (d.docNo.isNotEmpty) d.docNo,
                              if (d.locationName != null) d.locationName!,
                              if (d.expiryDate != null)
                                'expires ${formatDate(d.expiryDate)}',
                            ].join(' · '),
                          ),
                        ),
                      ),
                    if (_c.hasMore)
                      Center(
                        child: TextButton(
                          onPressed: _c.loadMore,
                          child: const Text('Load more'),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// `/compliance-docs/new` and `/compliance-docs/:id`.
class ComplianceDocFormScreen extends ConsumerWidget {
  const ComplianceDocFormScreen({super.key, this.id});

  final String? id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (id == null) return const _DocForm();
    return AsyncValueView<ComplianceDoc>(
      value: ref.watch(complianceDocProvider(id!)),
      onRetry: () => ref.invalidate(complianceDocProvider(id!)),
      data: (d) => _DocForm(doc: d),
    );
  }
}

class _DocForm extends ConsumerStatefulWidget {
  const _DocForm({this.doc});

  final ComplianceDoc? doc;

  @override
  ConsumerState<_DocForm> createState() => _DocFormState();
}

class _DocFormState extends ConsumerState<_DocForm> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.doc?.name);
  late final _docNo = TextEditingController(text: widget.doc?.docNo);
  late final _issuedBy = TextEditingController(text: widget.doc?.issuedBy);
  late final _notes = TextEditingController(text: widget.doc?.notes);
  late final _remind = TextEditingController(
    text: '${widget.doc?.remindDays ?? 30}',
  );
  late String _category = widget.doc?.category ?? 'licence';
  late DateTime? _issued = DateTime.tryParse(widget.doc?.issueDate ?? '');
  late DateTime? _expiry = DateTime.tryParse(widget.doc?.expiryDate ?? '');
  late String? _locationId = widget.doc?.locationId;
  late bool _active = widget.doc?.isActive ?? true;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_name, _docNo, _issuedBy, _notes, _remind]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final body = <String, dynamic>{
        'name': _name.text.trim(),
        'category': _category,
        'docNo': _docNo.text.trim(),
        'issuedBy': _issuedBy.text.trim(),
        'issueDate': _issued == null ? null : apiDate(_issued!),
        'expiryDate': _expiry == null ? null : apiDate(_expiry!),
        'remindDays': int.tryParse(_remind.text.trim()) ?? 30,
        'locationId': _locationId,
        'notes': _notes.text.trim(),
        if (widget.doc != null) 'isActive': _active,
      };
      await ref
          .read(complianceRepositoryProvider)
          .saveDoc(widget.doc?.id, body);
      ref.read(complianceRevisionProvider.notifier).bump();
      if (mounted) context.go('/compliance-docs');
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showErrorSnackBar(context, e);
      }
    }
  }

  Widget _date(String label, DateTime? value, ValueChanged<DateTime?> set) =>
      Row(
        children: [
          Expanded(
            child: DayButton(
              label: label,
              value: value,
              onChanged: (d) => setState(() => set(d)),
            ),
          ),
          if (value != null)
            IconButton(
              tooltip: 'Clear $label',
              icon: const Icon(Icons.clear),
              onPressed: () => setState(() => set(null)),
            ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final manage = ref.watch(permissionsProvider).can(TaxPerm.complianceManage);
    final locations = ref.watch(locationsLookupProvider).value ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: widget.doc == null ? 'Add document' : widget.doc!.name,
          actions: [
            OutlinedButton(
              onPressed: () => context.go('/compliance-docs'),
              child: const Text('Back'),
            ),
            if (manage)
              BusyButton(
                busy: _busy,
                onPressed: _save,
                label: 'Save',
                icon: Icons.save_outlined,
              ),
          ],
        ),
        Expanded(
          child: Form(
            key: _form,
            child: FormPage(
              children: [
                TextFormField(
                  controller: _name,
                  enabled: manage,
                  decoration: const InputDecoration(labelText: 'Name'),
                  validator: (v) =>
                      (v ?? '').trim().isEmpty ? 'Enter a name' : null,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _category,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: [
                    for (final c in complianceCategories)
                      DropdownMenuItem(value: c, child: Text(_cap(c))),
                  ],
                  onChanged: manage
                      ? (v) => setState(() => _category = v ?? _category)
                      : null,
                ),
                const SizedBox(height: 12),
                FormRow(
                  children: [
                    TextFormField(
                      controller: _docNo,
                      enabled: manage,
                      decoration: const InputDecoration(labelText: 'Number'),
                    ),
                    TextFormField(
                      controller: _issuedBy,
                      enabled: manage,
                      decoration: const InputDecoration(labelText: 'Issued by'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                FormRow(
                  children: [
                    _date('Issued', _issued, (d) => _issued = d),
                    _date('Expires', _expiry, (d) => _expiry = d),
                  ],
                ),
                const SizedBox(height: 12),
                FormRow(
                  children: [
                    TextFormField(
                      controller: _remind,
                      enabled: manage,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Remind days before expiry',
                      ),
                      validator: (v) {
                        final n = int.tryParse((v ?? '').trim());
                        return n == null || n < 0
                            ? 'Enter a number of days'
                            : null;
                      },
                    ),
                    DropdownButtonFormField<String?>(
                      initialValue: locations.any((l) => l.id == _locationId)
                          ? _locationId
                          : null,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Location'),
                      items: [
                        const DropdownMenuItem(
                          value: null,
                          child: Text('Whole company'),
                        ),
                        for (final l in locations)
                          DropdownMenuItem(value: l.id, child: Text(l.name)),
                      ],
                      onChanged: manage
                          ? (v) => setState(() => _locationId = v)
                          : null,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _notes,
                  enabled: manage,
                  maxLines: 3,
                  decoration: const InputDecoration(labelText: 'Notes'),
                ),
                if (widget.doc != null)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Active'),
                    value: _active,
                    onChanged: manage
                        ? (v) => setState(() => _active = v)
                        : null,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
