import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/json.dart';
import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../construction/common/c_widgets.dart' show CGate, showSuccess;
import 'helpdesk_models.dart';
import 'helpdesk_repository.dart';

const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// `/helpdesk/settings`: support hours, SLA targets, auto-close.
class HelpdeskSettingsScreen extends ConsumerWidget {
  const HelpdeskSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(helpdeskSettingsProvider);
    return CGate(
      anyOf: const [Perm.helpdeskSettings],
      child: AsyncValueView<Json>(
        value: async,
        onRetry: () => ref.invalidate(helpdeskSettingsProvider),
        data: (s) => _Form(settings: s),
      ),
    );
  }
}

class _Form extends ConsumerStatefulWidget {
  const _Form({required this.settings});

  final Json settings;

  @override
  ConsumerState<_Form> createState() => _FormState();
}

class _FormState extends ConsumerState<_Form> {
  late String _mode = asString(widget.settings['hoursMode'], 'business');
  late final Set<int> _workDays = {
    for (final d in (widget.settings['workDays'] as List? ?? const []))
      asInt(d),
  };
  late final _start = TextEditingController(
    text: asString(widget.settings['startTime'], '09:00'),
  );
  late final _end = TextEditingController(
    text: asString(widget.settings['endTime'], '18:00'),
  );
  late final _close = TextEditingController(
    text: '${asInt(widget.settings['autoCloseDays'], 7)}',
  );
  late final _renew = TextEditingController(
    text: '${asInt(widget.settings['renewalDays'], 30)}',
  );
  late bool _notify = asBool(widget.settings['notifyCustomer'], true);
  late final Map<String, List<TextEditingController>> _sla = {
    for (final p in ticketPriorities)
      p: [
        TextEditingController(
          text:
              '${asJson(asJson(widget.settings['sla'])[p])['firstResponseHours'] ?? ''}',
        ),
        TextEditingController(
          text:
              '${asJson(asJson(widget.settings['sla'])[p])['resolutionHours'] ?? ''}',
        ),
      ],
  };
  bool _saving = false;

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(helpdeskRepositoryProvider).saveSettings({
        'hoursMode': _mode,
        'workDays': _workDays.toList()..sort(),
        'startTime': _start.text.trim(),
        'endTime': _end.text.trim(),
        'autoCloseDays': int.tryParse(_close.text.trim()) ?? 7,
        'renewalDays': int.tryParse(_renew.text.trim()) ?? 30,
        'notifyCustomer': _notify,
        'sla': {
          for (final e in _sla.entries)
            if (double.tryParse(e.value[0].text) != null &&
                double.tryParse(e.value[1].text) != null)
              e.key: {
                'firstResponseHours': double.parse(e.value[0].text),
                'resolutionHours': double.parse(e.value[1].text),
              },
        },
      });
      ref.read(helpdeskRevisionProvider.notifier).bump();
      if (mounted) showSuccess(context, 'Settings saved');
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => FormPage(
    maxWidth: 760,
    bottomBar: FormActionBar(
      children: [
        TextButton(
          onPressed: () => context.go('/helpdesk/reports'),
          child: const Text('Back'),
        ),
        BusyButton(
          busy: _saving,
          onPressed: _saving ? null : _save,
          label: 'Save',
        ),
      ],
    ),
    children: [
      Text('Hours and SLA', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 12),
      SectionCard(
        title: 'Support hours',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'business', label: Text('Business hours')),
                ButtonSegment(value: '24x7', label: Text('24 by 7')),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
            if (_mode == 'business') ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (var i = 0; i < 7; i++)
                    FilterChip(
                      label: Text(_days[i]),
                      selected: _workDays.contains(i + 1),
                      onSelected: (v) => setState(
                        () =>
                            v ? _workDays.add(i + 1) : _workDays.remove(i + 1),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              FormRow(
                children: [
                  TextField(
                    controller: _start,
                    decoration: const InputDecoration(
                      labelText: 'Opens (HH:MM)',
                    ),
                  ),
                  TextField(
                    controller: _end,
                    decoration: const InputDecoration(
                      labelText: 'Closes (HH:MM)',
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      SectionCard(
        title: 'Targets in hours',
        child: Column(
          children: [
            for (final p in ticketPriorities)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: FormRow(
                  children: [
                    TextField(
                      controller: _sla[p]![0],
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: '${sentence(p)}: first response',
                      ),
                    ),
                    TextField(
                      controller: _sla[p]![1],
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: '${sentence(p)}: resolution',
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      SectionCard(
        title: 'Other',
        child: Column(
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Tell the customer about replies and fixes'),
              value: _notify,
              onChanged: (v) => setState(() => _notify = v),
            ),
            FormRow(
              children: [
                TextField(
                  controller: _close,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Close resolved tickets after (days, 0 is off)',
                  ),
                ),
                TextField(
                  controller: _renew,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Remind about renewals before (days)',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ],
  );
}
