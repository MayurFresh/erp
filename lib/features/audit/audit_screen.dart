import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../widgets/adaptive_data_list.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_controller.dart';
import '../../widgets/search_field.dart';
import '../auth/session.dart';
import 'audit_repository.dart';

class AuditScreen extends ConsumerStatefulWidget {
  const AuditScreen({super.key});

  @override
  ConsumerState<AuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends ConsumerState<AuditScreen> {
  String? _entity;
  late final PagedController<AuditEntry> _paged = PagedController(
    (offset, limit) => ref
        .read(auditRepositoryProvider)
        .list(entity: _entity, offset: offset, limit: limit),
  );

  @override
  void initState() {
    super.initState();
    _paged.refresh();
  }

  @override
  void dispose() {
    _paged.dispose();
    super.dispose();
  }

  void _show(AuditEntry entry) {
    showDialog<void>(
      context: context,
      builder: (context) => _AuditDetailDialog(entry: entry),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(activeCompanyIdProvider, (_, _) => _paged.refresh());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeader(title: 'Audit log', subtitle: 'Who changed what'),
        FilterBar(
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: SearchField(
                hintText: 'Filter by entity, e.g. invoice',
                onChanged: (v) {
                  _entity = v.isEmpty ? null : v.toLowerCase();
                  _paged.refresh();
                },
              ),
            ),
          ],
        ),
        Expanded(
          child: AdaptiveDataList<AuditEntry>(
            controller: _paged,
            emptyMessage: 'No audit entries.',
            emptyIcon: Icons.history,
            onTap: _show,
            columns: [
              TableColumnSpec('When', (e) => Text(formatDateTime(e.createdAt))),
              TableColumnSpec('User', (e) => Text(e.userName ?? 'System')),
              TableColumnSpec('Entity', (e) => Text(e.entity)),
              TableColumnSpec('Action', (e) => Text(e.action)),
              TableColumnSpec(
                'Record',
                (e) => Text(_summary(e), overflow: TextOverflow.ellipsis),
              ),
            ],
            cardBuilder: (context, e) => ListCard(
              onTap: () => _show(e),
              title: Text('${e.entity} · ${e.action}'),
              subtitle: Text(
                '${e.userName ?? 'System'} · ${formatDateTime(e.createdAt)}\n${_summary(e)}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
      ],
    );
  }

  static String _summary(AuditEntry e) {
    final data = e.after ?? e.before;
    final label = data?['number'] ?? data?['name'] ?? data?['email'];
    return label?.toString() ?? e.entityId;
  }
}

class _AuditDetailDialog extends StatelessWidget {
  const _AuditDetailDialog({required this.entry});

  final AuditEntry entry;

  @override
  Widget build(BuildContext context) {
    const encoder = JsonEncoder.withIndent('  ');
    final mono = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace');
    Widget block(String title, Map<String, dynamic>? data) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        SelectableText(data == null ? '—' : encoder.convert(data), style: mono),
        const SizedBox(height: 12),
      ],
    );
    return AlertDialog(
      title: Text('${entry.entity} · ${entry.action}'),
      scrollable: true,
      content: SizedBox(
        width: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${entry.userName ?? 'System'} · ${formatDateTime(entry.createdAt)}',
            ),
            Text('ID ${entry.entityId}'),
            const SizedBox(height: 12),
            block('Before', entry.before),
            block('After', entry.after),
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
