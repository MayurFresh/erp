import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/json.dart';
import '../../core/money.dart';
import '../../widgets/adaptive_data_list.dart';
import '../../widgets/busy.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_controller.dart';
import '../../widgets/states.dart';
import '../compliance/compliance_widgets.dart' show pickTextFile;
import 'approvals_screens.dart' show statusColor, statusLabel;
import 'controls_models.dart';
import 'controls_repository.dart';
import '../../core/app_colors.dart';

/// Kinds whose rows can carry a date the postings are made on.
bool importNeedsAsOf(String kind) =>
    kind == 'opening_stock' || kind == 'account_balances';

bool importHasAsOf(String kind) => importNeedsAsOf(kind) || kind == 'parties';

bool importHasUpdateExisting(String kind) =>
    kind == 'items' || kind == 'parties';

/// `/imports`: the import wizard and the history of past imports.
class ImportsScreen extends ConsumerStatefulWidget {
  const ImportsScreen({
    super.key,
    this.pollInterval = const Duration(seconds: 2),
  });

  final Duration pollInterval;

  @override
  ConsumerState<ImportsScreen> createState() => _ImportsScreenState();
}

class _ImportsScreenState extends ConsumerState<ImportsScreen> {
  bool _history = false;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const PageHeader(
        title: 'Import data',
        subtitle: 'Bring items, parties and opening balances in from CSV',
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: SegmentedButton<bool>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: false, label: Text('New import')),
            ButtonSegment(value: true, label: Text('History')),
          ],
          selected: {_history},
          onSelectionChanged: (v) => setState(() => _history = v.first),
        ),
      ),
      Expanded(
        child: _history
            ? const _ImportHistory()
            : _ImportWizard(pollInterval: widget.pollInterval),
      ),
    ],
  );
}

class _ImportWizard extends ConsumerStatefulWidget {
  const _ImportWizard({required this.pollInterval});

  final Duration pollInterval;

  @override
  ConsumerState<_ImportWizard> createState() => _ImportWizardState();
}

class _ImportWizardState extends ConsumerState<_ImportWizard> {
  String _kind = 'items';
  final _csv = TextEditingController();
  String? _fileName;
  DateTime? _asOf;
  bool _updateExisting = false;
  bool _validating = false;
  String? _csvError;
  ImportJob? _job;

  @override
  void dispose() {
    _csv.dispose();
    super.dispose();
  }

  Future<void> _template() async {
    try {
      final text = await runBlocking(
        context,
        () => ref.read(controlsRepositoryProvider).importTemplate(_kind),
      );
      if (text == null || !mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('${importKinds[_kind]} template'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText(
                text,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: text));
                if (context.mounted) {
                  showInfoSnackBar(
                    context,
                    'Template copied. Paste it into a spreadsheet.',
                  );
                }
              },
              child: const Text('Copy'),
            ),
            TextButton(
              onPressed: () {
                _csv.text = text;
                _fileName = null;
                Navigator.of(context).pop();
              },
              child: const Text('Use as starting point'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _pickFile() async {
    try {
      final file = await pickTextFile(const ['csv', 'txt', 'tsv']);
      if (file == null || !mounted) return;
      setState(() {
        _csv.text = file.text;
        _fileName = file.name;
        _csvError = null;
      });
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _pickAsOf() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _asOf ?? now,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year + 1, 12, 31),
    );
    if (picked != null && mounted) setState(() => _asOf = picked);
  }

  Future<void> _validate() async {
    final text = _csv.text.trim();
    String? error;
    if (text.isEmpty) {
      error = 'Choose a file or paste the CSV';
    } else if (importNeedsAsOf(_kind) && _asOf == null) {
      error = 'Choose the "as of" date';
    }
    setState(() => _csvError = error);
    if (error != null) return;
    setState(() => _validating = true);
    try {
      final job = await ref
          .read(controlsRepositoryProvider)
          .createImport(
            kind: _kind,
            csv: _csv.text,
            fileName: _fileName,
            asOf: importHasAsOf(_kind) && _asOf != null
                ? apiDate(_asOf!)
                : null,
            updateExisting: importHasUpdateExisting(_kind) && _updateExisting,
          );
      if (mounted) setState(() => _job = job);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _validating = false);
    }
  }

  void _restart() => setState(() {
    _job = null;
    _csv.clear();
    _fileName = null;
  });

  @override
  Widget build(BuildContext context) {
    final job = _job;
    return FormPage(
      maxWidth: 900,
      children: [
        SectionCard(
          title: '1. What are you importing?',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<String>(
                initialValue: _kind,
                decoration: const InputDecoration(labelText: 'Import'),
                items: [
                  for (final e in importKinds.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: job != null
                    ? null
                    : (v) => setState(() => _kind = v ?? _kind),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _template,
                  icon: const Icon(Icons.download_outlined),
                  label: const Text('Download template'),
                ),
              ),
            ],
          ),
        ),
        if (job == null)
          SectionCard(
            title: '2. Add your data',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _pickFile,
                      icon: const Icon(Icons.upload_file_outlined),
                      label: const Text('Choose CSV file'),
                    ),
                    if (_fileName != null) Text(_fileName!),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _csv,
                  minLines: 5,
                  maxLines: 10,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  decoration: InputDecoration(
                    labelText: 'Or paste CSV / rows copied from Excel',
                    alignLabelWithHint: true,
                    errorText: _csvError,
                  ),
                  onChanged: (_) => setState(() => _csvError = null),
                ),
                const SizedBox(height: 12),
                if (importHasAsOf(_kind))
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: _pickAsOf,
                      icon: const Icon(Icons.calendar_today_outlined),
                      label: Text(
                        _asOf == null
                            ? importNeedsAsOf(_kind)
                                  ? 'As of date (required)'
                                  : 'As of date (for opening balances)'
                            : 'As of ${formatDate(_asOf)}',
                      ),
                    ),
                  ),
                if (importHasUpdateExisting(_kind))
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Update records that already exist'),
                    subtitle: const Text(
                      'Off: a row that matches an existing record is an error.',
                    ),
                    value: _updateExisting,
                    onChanged: (v) => setState(() => _updateExisting = v),
                  ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: BusyButton(
                    busy: _validating,
                    onPressed: _validate,
                    label: 'Validate',
                    icon: Icons.rule,
                  ),
                ),
              ],
            ),
          )
        else
          ImportJobPanel(
            key: ValueKey(job.id),
            job: job,
            pollInterval: widget.pollInterval,
            onRestart: _restart,
          ),
      ],
    );
  }
}

/// `/imports/:id`: one import (also reached from the notification link).
class ImportJobScreen extends ConsumerWidget {
  const ImportJobScreen({super.key, required this.id});

  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<ImportJob>(
      future: ref.read(controlsRepositoryProvider).importJob(id),
      builder: (context, snap) {
        if (snap.hasError) {
          return ErrorView(
            error: snap.error!,
            onRetry: () => (context as Element).markNeedsBuild(),
          );
        }
        final job = snap.data;
        if (job == null) return const LoadingView();
        return FormPage(
          maxWidth: 900,
          children: [
            PageHeader(
              title: 'Import · ${importKinds[job.kind] ?? job.kind}',
              subtitle: job.fileName,
            ),
            ImportJobPanel(
              job: job,
              onRestart: () => context.go('/imports'),
              restartLabel: 'New import',
            ),
          ],
        );
      },
    );
  }
}

/// Steps 3 and 4: review the errors and preview, commit, watch progress
/// (polling `GET /imports/:id`) and see the result.
class ImportJobPanel extends ConsumerStatefulWidget {
  const ImportJobPanel({
    super.key,
    required this.job,
    required this.onRestart,
    this.pollInterval = const Duration(seconds: 2),
    this.restartLabel = 'Start over',
  });

  final ImportJob job;
  final VoidCallback onRestart;
  final Duration pollInterval;
  final String restartLabel;

  @override
  ConsumerState<ImportJobPanel> createState() => _ImportJobPanelState();
}

class _ImportJobPanelState extends ConsumerState<ImportJobPanel> {
  late ImportJob _job = widget.job;
  Timer? _timer;
  bool _committing = false;

  @override
  void initState() {
    super.initState();
    _syncPolling();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _syncPolling() {
    if (_job.inProgress) {
      _timer ??= Timer.periodic(widget.pollInterval, (_) => _poll());
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  Future<void> _poll() async {
    try {
      final next = await ref
          .read(controlsRepositoryProvider)
          .importJob(_job.id);
      if (!mounted) return;
      setState(() => _job = next);
      _syncPolling();
    } catch (_) {
      // Keep polling; a transient failure should not stop the progress view.
    }
  }

  Future<void> _commit() async {
    setState(() => _committing = true);
    try {
      final next = await ref
          .read(controlsRepositoryProvider)
          .commitImport(_job.id);
      if (!mounted) return;
      setState(() => _job = next);
      _syncPolling();
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _committing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final job = _job;
    final theme = Theme.of(context);
    final canCommit = job.status == 'validated';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionCard(
          title: '3. Review',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 32,
                runSpacing: 12,
                children: [
                  LabeledValue('Status', statusLabel(job.status)),
                  LabeledValue('Rows', '${job.totalRows}'),
                  LabeledValue('Valid rows', '${job.validRows}'),
                  LabeledValue('Errors', '${job.totalRows - job.validRows}'),
                  if (job.asOf != null)
                    LabeledValue('As of', formatDate(job.asOf)),
                ],
              ),
              if (job.errors.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  job.errors.length >= 200
                      ? 'Errors (first 200)'
                      : 'Errors (${job.errors.length})',
                  style: theme.textTheme.titleSmall,
                ),
                for (final e in job.errors)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      Icons.error_outline,
                      color: theme.colorScheme.error,
                    ),
                    title: Text(e.message),
                    subtitle: Text(
                      'Row ${e.row}${e.column == null ? '' : ' · ${e.column}'}',
                    ),
                  ),
              ],
              if (job.preview.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  'Preview (first ${job.preview.length} rows)',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                _PreviewTable(rows: job.preview),
              ],
              if (job.status == 'invalid')
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text(
                    'Fix the errors in your file and validate again.',
                  ),
                ),
            ],
          ),
        ),
        SectionCard(
          title: '4. Import',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (job.inProgress) ...[
                Text(
                  job.status == 'queued' ? 'Queued…' : 'Importing…',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                const LinearProgressIndicator(),
              ],
              if (job.status == 'done')
                Row(
                  children: [
                    Icon(
                      Icons.check_circle_outline,
                      color: context.colors.success,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Done. ${job.created} created, ${job.updated} updated, ${job.skipped} skipped.',
                      ),
                    ),
                  ],
                ),
              if (job.status == 'failed')
                Row(
                  children: [
                    Icon(Icons.error, color: theme.colorScheme.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Import failed. Nothing was written. ${job.error ?? ''}',
                      ),
                    ),
                  ],
                ),
              if (canCommit)
                Text(
                  'Nothing is written until you import. All ${job.validRows} rows are saved together or not at all.',
                ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (canCommit)
                    BusyButton(
                      busy: _committing,
                      onPressed: _commit,
                      label: 'Import ${job.validRows} rows',
                      icon: Icons.playlist_add_check,
                    ),
                  if (!job.inProgress)
                    OutlinedButton(
                      onPressed: widget.onRestart,
                      child: Text(widget.restartLabel),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PreviewTable extends StatelessWidget {
  const _PreviewTable({required this.rows});

  final List<Json> rows;

  @override
  Widget build(BuildContext context) {
    final columns = <String>[];
    for (final r in rows) {
      for (final k in r.keys) {
        if (!columns.contains(k)) columns.add(k);
      }
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columnSpacing: 20,
        headingRowHeight: 40,
        dataRowMinHeight: 36,
        dataRowMaxHeight: 40,
        columns: [for (final c in columns) DataColumn(label: Text(c))],
        rows: [
          for (final r in rows)
            DataRow(
              cells: [
                for (final c in columns)
                  DataCell(Text(r[c] == null ? '' : '${r[c]}')),
              ],
            ),
        ],
      ),
    );
  }
}

class _ImportHistory extends ConsumerStatefulWidget {
  const _ImportHistory();

  @override
  ConsumerState<_ImportHistory> createState() => _ImportHistoryState();
}

class _ImportHistoryState extends ConsumerState<_ImportHistory> {
  late final PagedController<ImportJob> _controller = PagedController(
    (offset, limit) => ref
        .read(controlsRepositoryProvider)
        .imports(offset: offset, limit: limit),
  );

  @override
  void initState() {
    super.initState();
    _controller.refresh();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _result(ImportJob j) => j.hasResult
      ? '${j.created} created · ${j.updated} updated · ${j.skipped} skipped'
      : '${j.validRows}/${j.totalRows} valid rows';

  @override
  Widget build(BuildContext context) => AdaptiveDataList<ImportJob>(
    controller: _controller,
    emptyIcon: Icons.upload_file_outlined,
    emptyMessage: 'No imports yet.',
    onTap: (j) => context.push('/imports/${j.id}'),
    columns: [
      TableColumnSpec('Date', (j) => Text(formatDateTime(j.createdAt))),
      TableColumnSpec('Import', (j) => Text(importKinds[j.kind] ?? j.kind)),
      TableColumnSpec('File', (j) => Text(j.fileName ?? '—'), maxWidth: 220),
      TableColumnSpec('Rows', (j) => Text('${j.totalRows}'), numeric: true),
      TableColumnSpec('Result', (j) => Text(_result(j))),
      TableColumnSpec(
        'Status',
        (j) => Pill(statusLabel(j.status), color: _color(context, j.status)),
      ),
      TableColumnSpec('By', (j) => Text(j.createdByName)),
    ],
    cardBuilder: (context, j) => ListCard(
      onTap: () => context.push('/imports/${j.id}'),
      title: Text('${importKinds[j.kind] ?? j.kind} · ${j.totalRows} rows'),
      subtitle: Text('${formatDateTime(j.createdAt)} · ${_result(j)}'),
      trailing: Pill(statusLabel(j.status), color: _color(context, j.status)),
    ),
  );

  Color _color(BuildContext context, String status) => switch (status) {
    'done' => context.colors.success,
    'failed' || 'invalid' => Theme.of(context).colorScheme.error,
    _ => statusColor(context, 'pending'),
  };
}
