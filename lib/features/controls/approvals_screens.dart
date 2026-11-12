import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/json.dart';
import '../../core/money.dart';
import '../../widgets/adaptive_data_list.dart';
import '../../widgets/busy.dart';
import '../../widgets/filter_dropdown.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_controller.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import 'controls_models.dart';
import 'controls_perms.dart';
import 'controls_repository.dart';
import '../../core/app_colors.dart';
import '../../widgets/form_support.dart';

Color statusColor(BuildContext context, String status) {
  final scheme = Theme.of(context).colorScheme;
  return switch (status) {
    'approved' => context.colors.success,
    'rejected' => scheme.error,
    'cancelled' => scheme.outline,
    _ => context.colors.warning,
  };
}

String statusLabel(String status) =>
    status.isEmpty ? '' : status[0].toUpperCase() + status.substring(1);

/// `/approvals`: tabs "Waiting for me", "My requests" and "All".
class ApprovalsScreen extends ConsumerStatefulWidget {
  const ApprovalsScreen({super.key});

  @override
  ConsumerState<ApprovalsScreen> createState() => _ApprovalsScreenState();
}

class _ApprovalsScreenState extends ConsumerState<ApprovalsScreen> {
  String _scope = 'awaiting_me';
  String? _status;
  String? _docType;
  late final PagedController<ApprovalRequest> _controller = PagedController(
    (offset, limit) => ref
        .read(controlsRepositoryProvider)
        .approvals(
          scope: _scope,
          status: _status,
          docType: _docType,
          offset: offset,
          limit: limit,
        ),
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

  void _reload() {
    _controller.refresh();
    ref.read(approvalsRevisionProvider.notifier).bump();
  }

  @override
  Widget build(BuildContext context) {
    final canViewAll = ref
        .watch(permissionsProvider)
        .can(ControlsPerm.approvalsView);
    final counts = ref.watch(approvalCountProvider).value;
    String tab(String label, int? n) =>
        n == null || n == 0 ? label : '$label ($n)';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeader(
          title: 'Approvals',
          subtitle: 'Documents waiting for a decision',
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<String>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: 'awaiting_me',
                  label: Text(tab('Waiting for me', counts?.$1)),
                ),
                ButtonSegment(
                  value: 'mine',
                  label: Text(tab('My requests', counts?.$2)),
                ),
                if (canViewAll)
                  const ButtonSegment(value: 'all', label: Text('All')),
              ],
              selected: {_scope},
              onSelectionChanged: (v) {
                setState(() => _scope = v.first);
                _controller.refresh();
              },
            ),
          ),
        ),
        FilterBar(
          children: [
            FilterDropdown<String>(
              label: 'Status',
              value: _status,
              anyLabel: 'Any status',
              options: const {
                'pending': 'Pending',
                'approved': 'Approved',
                'rejected': 'Rejected',
                'cancelled': 'Cancelled',
              },
              onChanged: (v) {
                setState(() => _status = v);
                _controller.refresh();
              },
            ),
            FilterDropdown<String>(
              label: 'Type',
              value: _docType,
              anyLabel: 'Any type',
              options: approvalDocTypes,
              onChanged: (v) {
                setState(() => _docType = v);
                _controller.refresh();
              },
            ),
          ],
        ),
        Expanded(
          child: AdaptiveDataList<ApprovalRequest>(
            controller: _controller,
            emptyIcon: Icons.fact_check_outlined,
            emptyMessage: _scope == 'awaiting_me'
                ? 'Nothing is waiting for your approval.'
                : 'No approval requests.',
            onTap: (r) async {
              await context.push('/approvals/${r.id}');
              if (mounted) _reload();
            },
            columns: [
              TableColumnSpec('Number', (r) => Text(r.number)),
              TableColumnSpec('Type', (r) => Text(approvalDocLabel(r.docType))),
              TableColumnSpec('Party', (r) => Text(r.partyName ?? '—')),
              TableColumnSpec(
                'Amount',
                (r) => Text(formatMoney(r.amount)),
                numeric: true,
              ),
              TableColumnSpec(
                'Level',
                (r) => Text(
                  r.isPending ? '${r.currentLevel}/${r.totalLevels}' : '—',
                ),
              ),
              TableColumnSpec(
                'Status',
                (r) => Pill(
                  statusLabel(r.status),
                  color: statusColor(context, r.status),
                ),
              ),
              TableColumnSpec('Requested by', (r) => Text(r.requestedByName)),
              TableColumnSpec('Date', (r) => Text(formatDate(r.date))),
            ],
            cardBuilder: (context, r) => ListCard(
              onTap: () async {
                await context.push('/approvals/${r.id}');
                if (mounted) _reload();
              },
              title: Text('${r.number} · ${approvalDocLabel(r.docType)}'),
              subtitle: Text(
                '${r.partyName ?? r.requestedByName} · ${formatDate(r.date)}',
              ),
              trailing: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(formatMoney(r.amount)),
                  Pill(
                    statusLabel(r.status),
                    color: statusColor(context, r.status),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// `/approvals/:id`.
class ApprovalDetailScreen extends ConsumerWidget {
  const ApprovalDetailScreen({super.key, required this.id});

  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(approvalProvider(id));
    return AsyncValueView(
      value: value,
      onRetry: () => ref.invalidate(approvalProvider(id)),
      data: (request) => _ApprovalBody(request: request),
    );
  }
}

class _ApprovalBody extends ConsumerWidget {
  const _ApprovalBody({required this.request});

  final ApprovalRequest request;

  void _changed(WidgetRef ref) {
    ref.invalidate(approvalProvider(request.id));
    ref.read(approvalsRevisionProvider.notifier).bump();
  }

  Future<void> _approve(BuildContext context, WidgetRef ref) async {
    final comment = await showDialog<String>(
      context: context,
      builder: (_) => const _CommentDialog(
        title: 'Approve',
        confirm: 'Approve',
        required: false,
      ),
    );
    if (comment == null || !context.mounted) return;
    try {
      final done = await runBlocking(
        context,
        () => ref
            .read(controlsRepositoryProvider)
            .approve(request.id, comment: comment),
      );
      if (done == null || !context.mounted) return;
      _changed(ref);
      showInfoSnackBar(
        context,
        done.status == 'approved'
            ? 'Approved. ${done.documentNumber ?? 'Document'} created.'
            : 'Approved. Sent to the next level.',
      );
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _reject(BuildContext context, WidgetRef ref) async {
    final comment = await showDialog<String>(
      context: context,
      builder: (_) => const _CommentDialog(
        title: 'Reject',
        confirm: 'Reject',
        required: true,
      ),
    );
    if (comment == null || !context.mounted) return;
    try {
      final done = await runBlocking(
        context,
        () => ref.read(controlsRepositoryProvider).reject(request.id, comment),
      );
      if (done == null || !context.mounted) return;
      _changed(ref);
      showInfoSnackBar(context, 'Rejected.');
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _cancel(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel this request?'),
        content: const Text('The document will not be created.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Cancel request'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      final done = await runBlocking(
        context,
        () => ref.read(controlsRepositoryProvider).cancel(request.id),
      );
      if (done == null || !context.mounted) return;
      _changed(ref);
      showInfoSnackBar(context, 'Request cancelled.');
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(currentUserIdProvider);
    final canCancel =
        request.isPending && me != null && me == request.requestedById;
    return FormPage(
      maxWidth: 900,
      children: [
        PageHeader(
          title: request.number,
          subtitle:
              '${approvalDocLabel(request.docType)} · ${formatMoney(request.amount)}',
          actions: [
            Pill(
              statusLabel(request.status),
              color: statusColor(context, request.status),
            ),
          ],
        ),
        if (request.isPending)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (request.canAct) ...[
                  FilledButton.icon(
                    onPressed: () => _approve(context, ref),
                    icon: const Icon(Icons.check),
                    label: const Text('Approve'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _reject(context, ref),
                    icon: const Icon(Icons.close),
                    label: const Text('Reject'),
                  ),
                ],
                if (canCancel)
                  TextButton.icon(
                    onPressed: () => _cancel(context, ref),
                    icon: const Icon(Icons.undo),
                    label: const Text('Cancel request'),
                  ),
              ],
            ),
          ),
        SectionCard(
          title: 'Summary',
          child: Wrap(
            spacing: 32,
            runSpacing: 12,
            children: [
              LabeledValue('Date', formatDate(request.date)),
              LabeledValue('Party', request.partyName ?? ''),
              LabeledValue('Location', request.locationName ?? ''),
              LabeledValue('Requested by', request.requestedByName),
              LabeledValue('Rule', request.ruleName),
              if (request.narration != null)
                LabeledValue('Narration', request.narration!),
              if (request.documentNumber != null)
                LabeledValue('Document', request.documentNumber!),
            ],
          ),
        ),
        SectionCard(
          title: 'Details',
          child: _PayloadView(request: request),
        ),
        SectionCard(
          title: 'Approval levels',
          child: _LevelsTimeline(request: request),
        ),
        SectionCard(
          title: 'History',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final a in request.actions)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(_actionIcon(a.action)),
                  title: Text(
                    '${statusLabel(a.action)}${a.level == null ? '' : ' · level ${a.level}'} by ${a.byName}',
                  ),
                  subtitle: a.comment == null && a.at == null
                      ? null
                      : Text(
                          [
                            if (a.at != null) formatDateTime(a.at),
                            if (a.comment != null) '“${a.comment}”',
                          ].join('\n'),
                        ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  IconData _actionIcon(String action) => switch (action) {
    'approved' => Icons.check_circle_outline,
    'rejected' => Icons.cancel_outlined,
    'cancelled' => Icons.undo,
    _ => Icons.send_outlined,
  };
}

class _LevelsTimeline extends StatelessWidget {
  const _LevelsTimeline({required this.request});

  final ApprovalRequest request;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final approvedLevels = {
      for (final a in request.actions)
        if (a.action == 'approved' && a.level != null) a.level!,
    };
    return Column(
      children: [
        for (final l in request.levels)
          Builder(
            builder: (context) {
              final done =
                  approvedLevels.contains(l.level) ||
                  request.status == 'approved';
              final current =
                  request.isPending && l.level == request.currentLevel;
              return ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  done
                      ? Icons.check_circle_outline
                      : current
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: done
                      ? context.colors.success
                      : current
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outline,
                ),
                title: Text('Level ${l.level} · ${l.label}'),
                subtitle: current ? const Text('Waiting for a decision') : null,
              );
            },
          ),
      ],
    );
  }
}

/// The create body as submitted, shown per document type: party, date,
/// narration, lines and totals (best effort over the payload's keys).
class _PayloadView extends StatelessWidget {
  const _PayloadView({required this.request});

  final ApprovalRequest request;

  static const _skip = {'lines', 'allocations', 'custom', 'idempotencyKey'};

  String _text(Object? v) {
    if (v is num) return formatPlain(v);
    if (v is bool) return v ? 'Yes' : 'No';
    return v.toString();
  }

  @override
  Widget build(BuildContext context) {
    final p = request.payload;
    final scalars = [
      for (final e in p.entries)
        if (!_skip.contains(e.key) &&
            e.value != null &&
            (e.value is String || e.value is num || e.value is bool))
          e,
    ];
    final lines = asJsonList(p['lines']);
    final theme = Theme.of(context);
    if (scalars.isEmpty && lines.isEmpty) {
      return const Text('No further details.');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (scalars.isNotEmpty)
          Wrap(
            spacing: 32,
            runSpacing: 12,
            children: [
              for (final e in scalars)
                LabeledValue(_label(e.key), _text(e.value)),
            ],
          ),
        if (lines.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('Lines (${lines.length})', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          for (final (i, line) in lines.indexed)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                '${i + 1}. ${[for (final e in line.entries)
                  if (e.value != null && (e.value is String || e.value is num || e.value is bool)) '${_label(e.key)}: ${_text(e.value)}'].join(' · ')}',
              ),
            ),
        ],
      ],
    );
  }

  String _label(String key) {
    final spaced = key.replaceAllMapped(
      RegExp('[A-Z]'),
      (m) => ' ${m[0]!.toLowerCase()}',
    );
    return spaced[0].toUpperCase() + spaced.substring(1);
  }
}

class _CommentDialog extends StatefulWidget {
  const _CommentDialog({
    required this.title,
    required this.confirm,
    required this.required,
  });

  final String title;
  final String confirm;
  final bool required;

  @override
  State<_CommentDialog> createState() => _CommentDialogState();
}

class _CommentDialogState extends State<_CommentDialog> {
  final _comment = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: Form(
      key: _formKey,
      child: TextFormField(
        controller: _comment,
        autofocus: true,
        maxLines: 3,
        maxLength: 500,
        decoration: InputDecoration(
          labelText: widget.required ? 'Comment (required)' : 'Comment',
        ),
        validator: (v) {
          final text = v?.trim() ?? '';
          if (!widget.required && text.isEmpty) return null;
          if (text.isEmpty) return 'Comment is required';
          if (text.length < 3) return 'Comment must be at least 3 characters';
          return null;
        },
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          if (validateAndReveal(_formKey)) {
            Navigator.of(context).pop(_comment.text.trim());
          }
        },
        child: Text(widget.confirm),
      ),
    ],
  );
}
