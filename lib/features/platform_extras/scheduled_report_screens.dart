import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_tokens.dart';
import '../../core/money.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../receivables/receivables_widgets.dart';
import '../../core/permissions.dart';
import 'extras_repository.dart';

const _periodLabels = {
  'previous_day': 'Previous day',
  'previous_week': 'Previous 7 days',
  'previous_month': 'Previous month',
  'month_to_date': 'Month to date',
  'fy_to_date': 'Financial year to date',
};

/// `/scheduled-reports`: the reports that are emailed on a schedule.
class ScheduledReportsScreen extends ConsumerWidget {
  const ScheduledReportsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => RGate(
    anyOf: const [Perm.reportsView],
    child: Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.go('/scheduled-reports/new'),
        icon: const Icon(Icons.add),
        label: const Text('New schedule'),
      ),
      body: AsyncValueView<List<ScheduledReport>>(
        value: ref.watch(scheduledReportsProvider),
        onRetry: () => ref.invalidate(scheduledReportsProvider),
        data: (list) => list.isEmpty
            ? const EmptyView(
                icon: Icons.schedule_send_outlined,
                message: 'No scheduled reports yet.\nPick a report, a time and who gets it by email.',
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(Space.md, Space.md, Space.md, 96),
                children: [
                  for (final r in list)
                    Card(
                      child: ListTile(
                        key: ValueKey('report-${r.id}'),
                        minVerticalPadding: 12,
                        title: Text(r.name),
                        subtitle: Text(
                          '${r.reportLabel.isEmpty ? r.report : r.reportLabel}. ${r.when}\n'
                          '${r.isActive ? (r.nextRunAt == null ? '' : 'Next: ${formatDateTime(r.nextRunAt)}') : 'Paused'}',
                        ),
                        isThreeLine: true,
                        trailing: StatusChip(
                          r.isActive ? 'active' : 'paused',
                          label: r.isActive ? 'On' : 'Paused',
                        ),
                        onTap: () => context.go('/scheduled-reports/${r.id}'),
                      ),
                    ),
                ],
              ),
      ),
    ),
  );
}

/// `/scheduled-reports/new` and `/scheduled-reports/:id`: form, run now and history.
class ScheduledReportFormScreen extends ConsumerWidget {
  const ScheduledReportFormScreen({super.key, this.id});

  final String? id;

  @override
  Widget build(BuildContext context, WidgetRef ref) => RGate(
    anyOf: const [Perm.reportsView],
    child: id == null
        ? const _ReportForm(initial: null)
        : AsyncValueView<List<ScheduledReport>>(
            value: ref.watch(scheduledReportsProvider),
            onRetry: () => ref.invalidate(scheduledReportsProvider),
            data: (list) {
              final found = list.where((r) => r.id == id);
              if (found.isEmpty) {
                return const EmptyView(message: 'This schedule was not found.');
              }
              return _ReportForm(key: ValueKey(id), initial: found.first);
            },
          ),
  );
}

class _ReportForm extends ConsumerStatefulWidget {
  const _ReportForm({super.key, required this.initial});
  final ScheduledReport? initial;

  @override
  ConsumerState<_ReportForm> createState() => _ReportFormState();
}

class _ReportFormState extends ConsumerState<_ReportForm> {
  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late final _emails = TextEditingController(
    text: widget.initial?.recipientEmails.join(', ') ?? '',
  );
  late String _report = widget.initial?.report ?? 'sales_register';
  late String? _period = widget.initial?.period;
  late String _frequency = widget.initial?.frequency ?? 'daily';
  late int _weekday = widget.initial?.weekday ?? 1;
  late int _monthDay = widget.initial?.monthDay ?? 1;
  late String _time = widget.initial?.time ?? '08:00';
  late bool _active = widget.initial?.isActive ?? true;
  List<CatalogueReport> _catalogue = const [];
  bool _saving = false;
  bool _running = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    ref.read(extrasRepositoryProvider).catalogue().then((c) {
      if (mounted) setState(() => _catalogue = c);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _name.dispose();
    _emails.dispose();
    super.dispose();
  }

  Future<void> _pickTime() async {
    final parts = _time.split(':');
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1])),
    );
    if (t != null) {
      setState(() => _time = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}');
    }
  }

  Future<void> _save() async {
    final emails = _emails.text
        .split(RegExp(r'[,\s;]+'))
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toList();
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Give the schedule a name.');
      return;
    }
    if (emails.isEmpty && (widget.initial?.recipientUserIds.isEmpty ?? true)) {
      setState(() => _error = 'Add at least one email address.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(extrasRepositoryProvider).saveReport(
        ScheduledReport(
          id: widget.initial?.id,
          name: _name.text.trim(),
          report: _report,
          period: _period,
          frequency: _frequency,
          weekday: _weekday,
          monthDay: _monthDay,
          time: _time,
          recipientEmails: emails,
          recipientUserIds: widget.initial?.recipientUserIds ?? const [],
          isActive: _active,
        ),
      );
      ref.read(extrasRevisionProvider.notifier).bump();
      if (mounted) {
        showInfoSnackBar(context, 'Schedule saved');
        context.go('/scheduled-reports');
      }
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _runNow() async {
    setState(() => _running = true);
    try {
      final r = await ref.read(extrasRepositoryProvider).runReport(widget.initial!.id!);
      ref.read(extrasRevisionProvider.notifier).bump();
      if (mounted) {
        showInfoSnackBar(
          context,
          r.status == 'sent'
              ? 'Sent to ${r.recipients} ${r.recipients == 1 ? 'recipient' : 'recipients'}'
              : 'Could not send: ${r.error ?? 'unknown error'}',
        );
      }
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete this schedule?'),
        content: const Text('The report will stop being sent. Past runs are removed too.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(extrasRepositoryProvider).deleteReport(widget.initial!.id!);
      ref.read(extrasRevisionProvider.notifier).bump();
      if (mounted) context.go('/scheduled-reports');
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const days = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
    final reports = _catalogue.isEmpty
        ? const [CatalogueReport('sales_register', 'Sales register', true)]
        : _catalogue;
    final ranged = !{'receivables_ageing', 'stock_valuation'}.contains(_report);
    return FormPage(
      maxWidth: 900,
      bottomBar: FormActionBar(
        children: [
          if (widget.initial != null) ...[
            TextButton(onPressed: _delete, child: const Text('Delete')),
            OutlinedButton.icon(
              onPressed: _running ? null : _runNow,
              icon: const Icon(Icons.send_outlined),
              label: const Text('Send now'),
            ),
          ],
          BusyButton(busy: _saving, onPressed: _save, label: 'Save schedule', icon: Icons.check),
        ],
      ),
      children: [
        Text(widget.initial == null ? 'New scheduled report' : 'Scheduled report', style: theme.textTheme.headlineSmall),
        SectionCard(
          title: 'Report',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const ValueKey('report-name'),
                controller: _name,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              const SizedBox(height: Space.md),
              FormRow(
                children: [
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    key: const ValueKey('report-kind'),
                    initialValue: _report,
                    decoration: const InputDecoration(labelText: 'Report'),
                    items: [
                      for (final r in reports)
                        DropdownMenuItem(value: r.key, enabled: r.allowed, child: Text(r.label)),
                    ],
                    onChanged: (v) => setState(() => _report = v ?? _report),
                  ),
                  if (ranged)
                    DropdownButtonFormField<String?>(
                      isExpanded: true,
                      initialValue: _period,
                      decoration: const InputDecoration(labelText: 'Period covered'),
                      items: [
                        const DropdownMenuItem(value: null, child: Text('Matches the frequency')),
                        for (final e in _periodLabels.entries)
                          DropdownMenuItem(value: e.key, child: Text(e.value)),
                      ],
                      onChanged: (v) => setState(() => _period = v),
                    ),
                ],
              ),
            ],
          ),
        ),
        SectionCard(
          title: 'When',
          child: FormRow(
            children: [
              DropdownButtonFormField<String>(
                    isExpanded: true,
                key: const ValueKey('report-frequency'),
                initialValue: _frequency,
                decoration: const InputDecoration(labelText: 'How often'),
                items: const [
                  DropdownMenuItem(value: 'daily', child: Text('Every day')),
                  DropdownMenuItem(value: 'weekly', child: Text('Every week')),
                  DropdownMenuItem(value: 'monthly', child: Text('Every month')),
                ],
                onChanged: (v) => setState(() => _frequency = v ?? _frequency),
              ),
              if (_frequency == 'weekly')
                DropdownButtonFormField<int>(
                  isExpanded: true,
                  initialValue: _weekday,
                  decoration: const InputDecoration(labelText: 'Day'),
                  items: [for (var i = 0; i < 7; i++) DropdownMenuItem(value: i, child: Text(days[i]))],
                  onChanged: (v) => setState(() => _weekday = v ?? _weekday),
                ),
              if (_frequency == 'monthly')
                DropdownButtonFormField<int>(
                  isExpanded: true,
                  initialValue: _monthDay,
                  decoration: const InputDecoration(labelText: 'Day of month'),
                  items: [for (var i = 1; i <= 28; i++) DropdownMenuItem(value: i, child: Text('$i'))],
                  onChanged: (v) => setState(() => _monthDay = v ?? _monthDay),
                ),
              InkWell(
                onTap: _pickTime,
                child: InputDecorator(
                  decoration: const InputDecoration(labelText: 'Time (India)'),
                  child: Text(_time),
                ),
              ),
            ],
          ),
        ),
        SectionCard(
          title: 'Who gets it',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const ValueKey('report-emails'),
                controller: _emails,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  labelText: 'Email addresses',
                  helperText: 'Separate with commas. The email has a summary and a CSV file.',
                  errorText: _error,
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Send on schedule'),
                value: _active,
                onChanged: (v) => setState(() => _active = v),
              ),
            ],
          ),
        ),
        if (widget.initial?.id != null) _History(id: widget.initial!.id!),
      ],
    );
  }
}

class _History extends ConsumerWidget {
  const _History({required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) => SectionCard(
    title: 'History',
    child: ref.watch(reportRunsProvider(id)).when(
      loading: () => const LoadingView(),
      error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(reportRunsProvider(id))),
      data: (runs) => runs.isEmpty
          ? const Text('Nothing has been sent yet.')
          : Column(
              children: [
                for (final r in runs)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(r.status == 'sent'
                        ? 'Sent to ${r.recipients}, ${r.rowCount} rows'
                        : 'Failed: ${r.error ?? ''}'),
                    subtitle: Text('${formatDateTime(r.ranAt)}, ${r.trigger == 'manual' ? 'sent by hand' : 'on schedule'}'),
                    trailing: StatusChip(r.status == 'sent' ? 'sent' : 'failed'),
                  ),
              ],
            ),
    ),
  );
}
