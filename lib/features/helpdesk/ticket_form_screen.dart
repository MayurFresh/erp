import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/picker_field.dart';
import '../construction/common/c_widgets.dart' show CGate, showSuccess;
import '../parties/party_model.dart';
import '../parties/party_picker.dart';
import 'helpdesk_models.dart';
import 'helpdesk_repository.dart';

/// `/helpdesk/new`: log a ticket for a customer.
class TicketFormScreen extends ConsumerStatefulWidget {
  const TicketFormScreen({super.key});

  @override
  ConsumerState<TicketFormScreen> createState() => _TicketFormScreenState();
}

class _TicketFormScreenState extends ConsumerState<TicketFormScreen>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  final _subject = TextEditingController();
  final _description = TextEditingController();
  final _category = TextEditingController();
  final _serial = TextEditingController();
  Party? _party;
  String _channel = 'phone';
  String _priority = 'medium';
  String? _assignee;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_subject, _description, _category, _serial]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => serverErrors = const {});
    if (!validateAndReveal(_formKey)) return;
    if (_party == null) {
      setState(() => serverErrors = {'partyId': 'Choose the customer'});
      return;
    }
    setState(() => _saving = true);
    try {
      final t = await ref.read(helpdeskRepositoryProvider).createTicket({
        'partyId': _party!.id,
        'subject': _subject.text.trim(),
        'description': trimmedOrNull(_description.text),
        'channel': _channel,
        'priority': _priority,
        'category': trimmedOrNull(_category.text),
        'serialNo': trimmedOrNull(_serial.text),
        if (_assignee != null) 'assigneeId': _assignee,
      });
      ref.read(helpdeskRevisionProvider.notifier).bump();
      if (!mounted) return;
      showSuccess(context, 'Ticket ${t.number} logged');
      context.go('/helpdesk/${t.id}');
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final staff =
        ref.watch(helpdeskStaffProvider).value ??
        const <({String id, String name})>[];
    return CGate(
      anyOf: const [Perm.helpdeskManage],
      child: Form(
        key: _formKey,
        child: FormPage(
          maxWidth: 760,
          bottomBar: FormActionBar(
            children: [
              TextButton(
                onPressed: _saving ? null : () => context.go('/helpdesk'),
                child: const Text('Cancel'),
              ),
              BusyButton(
                busy: _saving,
                onPressed: _saving ? null : _save,
                label: 'Log ticket',
              ),
            ],
          ),
          children: [
            Text('New ticket', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            SectionCard(
              title: 'Customer and problem',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PickerField(
                    label: 'Customer',
                    value: _party?.name,
                    errorText: serverError('partyId'),
                    onTap: () async {
                      final p = await pickParty(
                        context,
                        ref,
                        type: PartyType.customer,
                      );
                      if (p != null) setState(() => _party = p);
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _subject,
                    decoration: InputDecoration(
                      labelText: 'Subject',
                      errorText: serverError('subject'),
                    ),
                    validator: (v) => requiredField(v, 'Subject'),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _description,
                    minLines: 3,
                    maxLines: 6,
                    decoration: const InputDecoration(labelText: 'Details'),
                  ),
                ],
              ),
            ),
            SectionCard(
              title: 'Handling',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FormRow(
                    children: [
                      DropdownButtonFormField<String>(
                        initialValue: _channel,
                        decoration: const InputDecoration(labelText: 'Channel'),
                        items: [
                          for (final e in ticketChannels.entries)
                            DropdownMenuItem(
                              value: e.key,
                              child: Text(e.value),
                            ),
                        ],
                        onChanged: (v) => setState(() => _channel = v!),
                      ),
                      DropdownButtonFormField<String>(
                        initialValue: _priority,
                        decoration: const InputDecoration(
                          labelText: 'Priority',
                        ),
                        items: [
                          for (final p in ticketPriorities)
                            DropdownMenuItem(
                              value: p,
                              child: Text(sentence(p)),
                            ),
                        ],
                        onChanged: (v) => setState(() => _priority = v!),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  FormRow(
                    children: [
                      TextFormField(
                        controller: _category,
                        decoration: const InputDecoration(
                          labelText: 'Category',
                        ),
                      ),
                      TextFormField(
                        controller: _serial,
                        decoration: const InputDecoration(
                          labelText: 'Serial number (optional)',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String?>(
                    initialValue: _assignee,
                    decoration: const InputDecoration(labelText: 'Assign to'),
                    items: [
                      const DropdownMenuItem(
                        value: null,
                        child: Text('Unassigned'),
                      ),
                      for (final s in staff)
                        DropdownMenuItem(value: s.id, child: Text(s.name)),
                    ],
                    onChanged: (v) => setState(() => _assignee = v),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
