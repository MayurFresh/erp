import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/permissions.dart';
import '../../core/whatsapp.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import 'contact_model.dart';
import 'parties_repository.dart';

/// Contact persons of a party: call and WhatsApp buttons for everyone who
/// can see the party, add, edit and delete with `parties.edit`.
class ContactsSection extends ConsumerWidget {
  const ContactsSection({super.key, required this.partyId});

  final String partyId;

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref, [
    ContactPerson? existing,
  ]) async {
    final body = await showFormDialog<Map<String, Object?>>(
      context: context,
      builder: (_) => ContactDialog(existing: existing),
    );
    if (body == null || !context.mounted) return;
    try {
      final repo = ref.read(partiesRepositoryProvider);
      if (existing == null) {
        await repo.addContact(partyId, body);
      } else {
        await repo.updateContact(partyId, existing.id, body);
      }
      ref.invalidate(partyContactsProvider(partyId));
      if (context.mounted) {
        showInfoSnackBar(context, 'Contact ${body['name']} saved');
      }
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    ContactPerson c,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Delete ${c.name}?'),
        content: const Text(
          'Quotations that name this contact keep their text.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(d).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(d).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await ref.read(partiesRepositoryProvider).deleteContact(partyId, c.id);
      ref.invalidate(partyContactsProvider(partyId));
      if (context.mounted) showInfoSnackBar(context, 'Contact deleted');
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(permissionsProvider).can(Perm.partiesEdit);
    final value = ref.watch(partyContactsProvider(partyId));
    return SectionCard(
      title: 'Contact persons',
      // On narrow phones the labelled button does not fit beside the title.
      trailing: !canEdit
          ? null
          : MediaQuery.sizeOf(context).width < 420
          ? IconButton(
              tooltip: 'Add contact',
              onPressed: () => _edit(context, ref),
              icon: const Icon(Icons.person_add_alt_1_outlined),
            )
          : TextButton.icon(
              onPressed: () => _edit(context, ref),
              icon: const Icon(Icons.add),
              label: const Text('Add contact'),
            ),
      child: switch (value) {
        AsyncValue(:final error?, hasValue: false) => Row(
          children: [
            Expanded(child: Text(errorMessage(error))),
            TextButton(
              onPressed: () => ref.invalidate(partyContactsProvider(partyId)),
              child: const Text('Retry'),
            ),
          ],
        ),
        AsyncValue(value: final list?) =>
          list.isEmpty
              ? const Text('No contact persons yet.')
              : Column(
                  children: [
                    for (final c in list)
                      _ContactTile(
                        contact: c,
                        onEdit: canEdit ? () => _edit(context, ref, c) : null,
                        onDelete: canEdit
                            ? () => _delete(context, ref, c)
                            : null,
                      ),
                  ],
                ),
        _ => const LinearProgressIndicator(),
      },
    );
  }
}

class _ContactTile extends StatelessWidget {
  const _ContactTile({required this.contact, this.onEdit, this.onDelete});

  final ContactPerson contact;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final c = contact;
    final theme = Theme.of(context);
    final phone = (c.phone ?? '').trim();
    final lines = [
      if ((c.designation ?? '').isNotEmpty) c.designation!,
      if (phone.isNotEmpty) phone,
      if ((c.email ?? '').isNotEmpty) c.email!,
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(c.name, style: theme.textTheme.titleSmall),
                    if (c.isPrimary) const Pill('Primary'),
                  ],
                ),
                if (lines.isNotEmpty)
                  Text(
                    lines.join(' · '),
                    style: theme.textTheme.bodySmall,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          if (phone.isNotEmpty) ...[
            IconButton(
              tooltip: 'Call ${c.name}',
              onPressed: () => launchUrl(Uri(scheme: 'tel', path: phone)),
              icon: const Icon(Icons.call_outlined),
            ),
            IconButton(
              tooltip: 'WhatsApp ${c.name}',
              onPressed: () => openWhatsApp(
                whatsAppUri(phone: phone, text: 'Hello ${c.name},'),
              ),
              icon: const Icon(Icons.chat_outlined),
            ),
          ],
          if (onEdit != null || onDelete != null)
            PopupMenuButton<String>(
              tooltip: 'More for ${c.name}',
              onSelected: (v) =>
                  v == 'edit' ? onEdit?.call() : onDelete?.call(),
              itemBuilder: (_) => [
                if (onEdit != null)
                  const PopupMenuItem(value: 'edit', child: Text('Edit')),
                if (onDelete != null)
                  const PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
        ],
      ),
    );
  }
}

/// Add or edit one contact; pops with the request body.
class ContactDialog extends StatefulWidget {
  const ContactDialog({super.key, this.existing});

  final ContactPerson? existing;

  @override
  State<ContactDialog> createState() => _ContactDialogState();
}

class _ContactDialogState extends State<ContactDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.existing?.name);
  late final _designation = TextEditingController(
    text: widget.existing?.designation,
  );
  late final _phone = TextEditingController(text: widget.existing?.phone);
  late final _email = TextEditingController(text: widget.existing?.email);
  late final _notes = TextEditingController(text: widget.existing?.notes);
  late bool _primary = widget.existing?.isPrimary ?? false;

  @override
  void dispose() {
    _name.dispose();
    _designation.dispose();
    _phone.dispose();
    _email.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _submit() {
    if (!validateAndReveal(_formKey)) return;
    Navigator.of(context).pop(<String, Object?>{
      'name': _name.text.trim(),
      'designation': trimmedOrNull(_designation.text),
      'phone': trimmedOrNull(_phone.text),
      'email': trimmedOrNull(_email.text),
      'notes': trimmedOrNull(_notes.text),
      'isPrimary': _primary,
    });
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    return AlertDialog(
      title: Text(editing ? 'Edit contact' : 'Add contact'),
      scrollable: true,
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
                autofocus: true,
                maxLength: 120,
                decoration: const InputDecoration(labelText: 'Name'),
                validator: (v) => requiredField(v, 'Name'),
              ),
              TextFormField(
                controller: _designation,
                maxLength: 80,
                decoration: const InputDecoration(
                  labelText: 'Designation (optional)',
                ),
              ),
              TextFormField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                maxLength: 20,
                decoration: const InputDecoration(
                  labelText: 'Phone (optional)',
                ),
              ),
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                maxLength: 120,
                decoration: const InputDecoration(
                  labelText: 'Email (optional)',
                ),
                validator: (v) {
                  final t = (v ?? '').trim();
                  return t.isEmpty || t.contains('@')
                      ? null
                      : 'Enter a valid email';
                },
              ),
              TextFormField(
                controller: _notes,
                maxLines: 2,
                maxLength: 300,
                decoration: const InputDecoration(
                  labelText: 'Notes (optional)',
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Primary contact'),
                value: _primary,
                onChanged: (v) => setState(() => _primary = v),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}
