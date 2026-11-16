import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_tokens.dart';
import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../receivables/receivables_widgets.dart';
import 'extras_repository.dart';

/// `/settings/sms`: DLT details and approved templates for SMS.
class SmsSettingsScreen extends ConsumerWidget {
  const SmsSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => RGate(
    anyOf: const [Perm.integrationsManage],
    child: AsyncValueView<SmsSettings>(
      value: ref.watch(smsSettingsProvider),
      onRetry: () => ref.invalidate(smsSettingsProvider),
      data: (s) => _SmsForm(key: ValueKey('${s.enabled}${s.dltEntityId}${s.senderId}'), initial: s),
    ),
  );
}

class _SmsForm extends ConsumerStatefulWidget {
  const _SmsForm({super.key, required this.initial});
  final SmsSettings initial;

  @override
  ConsumerState<_SmsForm> createState() => _SmsFormState();
}

class _SmsFormState extends ConsumerState<_SmsForm> {
  late bool _enabled = widget.initial.enabled;
  late final _entity = TextEditingController(text: widget.initial.dltEntityId ?? '');
  late final _sender = TextEditingController(text: widget.initial.senderId ?? '');
  late final Map<String, TextEditingController> _ids = {
    for (final t in widget.initial.templates) t.template: TextEditingController(text: t.dltTemplateId ?? ''),
  };
  late final Map<String, TextEditingController> _texts = {
    for (final t in widget.initial.templates) t.template: TextEditingController(text: t.text ?? ''),
  };
  final _phone = TextEditingController();
  bool _saving = false;
  bool _testing = false;

  @override
  void dispose() {
    for (final c in [_entity, _sender, _phone, ..._ids.values, ..._texts.values]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(extrasRepositoryProvider).saveSms({
        'enabled': _enabled,
        'dltEntityId': _entity.text.trim().isEmpty ? null : _entity.text.trim(),
        'senderId': _sender.text.trim().isEmpty ? null : _sender.text.trim(),
        'templates': {
          for (final k in _ids.keys)
            k: {
              'dltTemplateId': _ids[k]!.text.trim().isEmpty ? null : _ids[k]!.text.trim(),
              'text': _texts[k]!.text.trim().isEmpty ? null : _texts[k]!.text.trim(),
            },
        },
      });
      ref.read(extrasRevisionProvider.notifier).bump();
      if (mounted) showInfoSnackBar(context, 'SMS settings saved');
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _test() async {
    setState(() => _testing = true);
    try {
      await ref.read(extrasRepositoryProvider).testSms(_phone.text.trim());
      if (mounted) showInfoSnackBar(context, 'Test message sent');
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final logOnly = widget.initial.driver == 'log';
    return FormPage(
      maxWidth: 900,
      bottomBar: FormActionBar(
        children: [BusyButton(busy: _saving, onPressed: _save, label: 'Save settings', icon: Icons.check)],
      ),
      children: [
        Text('SMS', style: theme.textTheme.headlineSmall),
        SectionCard(
          title: 'Sending',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                logOnly
                    ? 'The server is set to log only, so no real SMS leaves it. Ask your administrator to set the SMS provider in the server settings.'
                    : 'The server sends through ${widget.initial.driver}.',
                style: theme.textTheme.bodySmall,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Send SMS to customers'),
                subtitle: const Text('Used for payment links and reminders when the customer has a phone number.'),
                value: _enabled,
                onChanged: (v) => setState(() => _enabled = v),
              ),
            ],
          ),
        ),
        SectionCard(
          title: 'DLT registration (India)',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'TRAI requires every commercial SMS in India to use a registered entity, sender name and approved template. Register on your operator DLT portal, then enter the ids here.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: Space.md),
              FormRow(
                children: [
                  TextField(key: const ValueKey('dlt-entity'), controller: _entity, decoration: const InputDecoration(labelText: 'Entity id')),
                  TextField(key: const ValueKey('dlt-sender'), controller: _sender, decoration: const InputDecoration(labelText: 'Sender name (header)')),
                ],
              ),
            ],
          ),
        ),
        for (final t in widget.initial.templates)
          SectionCard(
            title: t.label,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  key: ValueKey('dlt-template-${t.template}'),
                  controller: _ids[t.template],
                  decoration: const InputDecoration(labelText: 'Approved template id'),
                ),
                const SizedBox(height: Space.md),
                TextField(
                  controller: _texts[t.template],
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Approved text',
                    helperText: 'Exactly as approved, with {#var#} where the values go.',
                  ),
                ),
              ],
            ),
          ),
        SectionCard(
          title: 'Send a test',
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Phone number'),
                ),
              ),
              const SizedBox(width: Space.md),
              OutlinedButton(
                onPressed: _testing || _phone.text.trim().isEmpty ? null : _test,
                child: const Text('Send test'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
