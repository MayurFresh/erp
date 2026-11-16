import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_tokens.dart';
import '../../core/permissions.dart';
import '../../widgets/filter_dropdown.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/money_text.dart';
import '../../widgets/search_field.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import 'crm_models.dart';
import 'crm_repository.dart';
import 'crm_widgets.dart';

/// `/crm/leads`: every enquiry, filtered by status and source.
class CrmLeadsScreen extends ConsumerStatefulWidget {
  const CrmLeadsScreen({super.key});

  @override
  ConsumerState<CrmLeadsScreen> createState() => _CrmLeadsScreenState();
}

class _CrmLeadsScreenState extends ConsumerState<CrmLeadsScreen> {
  String _status = 'open';
  String _source = '';
  String _q = '';

  String get _key => '$_status|$_source|$_q';

  @override
  Widget build(BuildContext context) {
    final canManage = crmCan(ref, Perm.crmManage);
    final gutter = pageGutter(context);
    return CrmGate(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Sales',
            actions: [
              const CrmOwnerFilter(),
              if (canManage)
                FilledButton.icon(
                  onPressed: () => showAddLead(context, ref),
                  icon: const Icon(Icons.add),
                  label: const Text('Add lead'),
                ),
            ],
          ),
          const CrmTabs(current: '/crm/leads'),
          Padding(
            padding: EdgeInsets.fromLTRB(gutter, 0, gutter, Space.xs),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final (value, label) in crmLeadStatuses)
                    Padding(
                      padding: const EdgeInsets.only(right: Space.sm),
                      child: ChoiceChip(
                        label: Text(label),
                        selected: _status == value,
                        onSelected: (_) => setState(() => _status = value),
                      ),
                    ),
                ],
              ),
            ),
          ),
          FilterBar(
            children: [
              FilterDropdown<String>(
                label: 'Source',
                value: _source.isEmpty ? null : _source,
                anyLabel: 'All sources',
                options: {for (final s in crmSources) s.$1: s.$2},
                onChanged: (v) => setState(() => _source = v ?? ''),
              ),
              SizedBox(
                width: 240,
                child: SearchField(
                  hintText: 'Search name or phone',
                  onChanged: (v) => setState(() => _q = v.trim()),
                ),
              ),
            ],
          ),
          Expanded(
            child: AsyncValueView(
              value: ref.watch(crmLeadsProvider(_key)),
              onRetry: () => ref.invalidate(crmLeadsProvider(_key)),
              data: (leads) {
                if (leads.isEmpty) {
                  final filtered = _status != 'open' || _source.isNotEmpty || _q.isNotEmpty;
                  return EmptyView(
                    message: filtered
                        ? 'No leads match these filters.'
                        : 'No open leads. Add the next enquiry you get.',
                    action: filtered
                        ? OutlinedButton(
                            onPressed: () => setState(() {
                              _status = 'open';
                              _source = '';
                              _q = '';
                            }),
                            child: const Text('Clear filters'),
                          )
                        : canManage
                        ? FilledButton(
                            onPressed: () => showAddLead(context, ref),
                            child: const Text('Add lead'),
                          )
                        : null,
                  );
                }
                return Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 860),
                    child: ListView.separated(
                      padding: EdgeInsets.fromLTRB(gutter, 0, gutter, Space.xxl),
                      itemCount: leads.length,
                      separatorBuilder: (_, _) => const SizedBox(height: Space.sm),
                      itemBuilder: (_, i) => _LeadCard(lead: leads[i]),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _LeadCard extends StatelessWidget {
  const _LeadCard({required this.lead});

  final CrmLead lead;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = lead;
    final next = l.nextFollowUp;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push('/crm/leads/${l.id}'),
        child: Padding(
          padding: const EdgeInsets.all(Space.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      l.name,
                      style: theme.textTheme.titleMedium,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if ((l.estimatedValue ?? 0) > 0) ...[
                    const SizedBox(width: Space.sm),
                    MoneyText(
                      l.estimatedValue,
                      decimals: 0,
                      style: theme.textTheme.titleMedium,
                    ),
                  ],
                ],
              ),
              if ((l.requirement ?? '').isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    l.requirement!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              const SizedBox(height: Space.sm),
              Wrap(
                spacing: Space.sm,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  StatusChip(l.status),
                  sourceChip(l.source),
                  Text(
                    next == null
                        ? (l.isClosed ? '' : 'No follow-up set')
                        : '${crmKindLabel(next.kind)}: ${dueLabel(next.dueAt, prefix: 'due')}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: next != null && next.overdue
                          ? theme.colorScheme.error
                          : null,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The Add lead form. A duplicate shows the lead already there and lets the
/// person add anyway.
Future<void> showAddLead(BuildContext context, WidgetRef ref) async {
  final created = await showFormDialog<CrmLead>(
    context: context,
    builder: (_) => const _AddLeadDialog(),
  );
  if (created != null && context.mounted) {
    context.push('/crm/leads/${created.id}');
  }
}

class _AddLeadDialog extends ConsumerStatefulWidget {
  const _AddLeadDialog();

  @override
  ConsumerState<_AddLeadDialog> createState() => _AddLeadDialogState();
}

class _AddLeadDialogState extends ConsumerState<_AddLeadDialog> {
  final _key = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _company = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _city = TextEditingController();
  final _need = TextEditingController();
  final _value = TextEditingController();
  String _source = 'phone';
  bool _busy = false;
  String? _error;
  Map<String, dynamic>? _existing;

  Future<void> _save({bool force = false}) async {
    if (!_key.currentState!.validate()) return;
    String? t(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
    setState(() {
      _busy = true;
      _error = null;
      _existing = null;
    });
    try {
      final lead = await ref.read(crmRepositoryProvider).addLead({
        'name': _name.text.trim(),
        'companyName': ?t(_company),
        'phone': ?t(_phone),
        'email': ?t(_email),
        'city': ?t(_city),
        'requirement': ?t(_need),
        'estimatedValue': ?double.tryParse(_value.text.trim()),
        'source': _source,
        if (force) 'force': true,
      });
      ref.bumpCrm();
      if (mounted) Navigator.of(context).pop(lead);
    } catch (e) {
      if (!mounted) return;
      final api = apiError(e);
      setState(() {
        _busy = false;
        if (api?.code == 'DUPLICATE_LEAD') {
          final ex = api!.details['existing'];
          _existing = ex is Map ? Map<String, dynamic>.from(ex) : <String, dynamic>{};
        } else {
          _error = errorMessage(e);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ex = _existing;
    return AlertDialog(
      title: const Text('Add lead'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Form(
            key: _key,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (ex != null) ...[
                  Container(
                    padding: const EdgeInsets.all(Space.md),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: Radii.mediumAll,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'This phone or email is already an open lead.',
                          style: theme.textTheme.titleSmall,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${ex['name'] ?? 'Existing lead'}'
                          '${ex['status'] == null ? '' : ', ${ex['status']}'}',
                        ),
                        const SizedBox(height: Space.sm),
                        Wrap(
                          spacing: Space.sm,
                          children: [
                            if (ex['id'] != null)
                              OutlinedButton(
                                onPressed: () {
                                  final id = ex['id'];
                                  Navigator.of(context).pop();
                                  context.push('/crm/leads/$id');
                                },
                                child: const Text('Open existing lead'),
                              ),
                            FilledButton(
                              onPressed: _busy ? null : () => _save(force: true),
                              child: const Text('Add anyway'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: Space.md),
                ],
                TextFormField(
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Name'),
                  validator: (v) =>
                      (v ?? '').trim().isEmpty ? 'Enter a name' : null,
                ),
                const SizedBox(height: Space.md),
                FormRow(
                  children: [
                    TextFormField(
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(labelText: 'Phone'),
                      validator: (_) =>
                          _phone.text.trim().isEmpty && _email.text.trim().isEmpty
                          ? 'Enter a phone or an email'
                          : null,
                    ),
                    TextFormField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(labelText: 'Email'),
                    ),
                  ],
                ),
                const SizedBox(height: Space.md),
                FormRow(
                  children: [
                    TextFormField(
                      controller: _company,
                      decoration: const InputDecoration(labelText: 'Company'),
                    ),
                    TextFormField(
                      controller: _city,
                      decoration: const InputDecoration(labelText: 'City'),
                    ),
                  ],
                ),
                const SizedBox(height: Space.md),
                TextFormField(
                  controller: _need,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: 'What they need'),
                ),
                const SizedBox(height: Space.md),
                FormRow(
                  children: [
                    TextFormField(
                      controller: _value,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Estimated value',
                        prefixText: '₹ ',
                      ),
                    ),
                    DropdownButtonFormField<String>(
                      initialValue: _source,
                      decoration: const InputDecoration(labelText: 'Source'),
                      items: [
                        for (final s in crmSources)
                          DropdownMenuItem(value: s.$1, child: Text(s.$2)),
                      ],
                      onChanged: (v) => setState(() => _source = v ?? _source),
                    ),
                  ],
                ),
                if (_error != null) ...[
                  const SizedBox(height: Space.md),
                  Text(
                    _error!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : () => _save(),
          child: Text(_busy ? 'Saving' : 'Save lead'),
        ),
      ],
    );
  }
}
