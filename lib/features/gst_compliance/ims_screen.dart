import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../compliance/compliance_widgets.dart';
import '../compliance/tax_perms.dart';
import 'gst_compliance_repository.dart';

const _bucketLabels = {
  'in_books_accepted': 'In books, accepted',
  'in_books_rejected': 'In books, rejected',
  'pending': 'Pending',
  'not_in_books': 'Not in books',
};

/// `/ims`: accept, reject or hold supplier documents before filing GSTR-3B.
class ImsScreen extends ConsumerStatefulWidget {
  const ImsScreen({super.key});

  @override
  ConsumerState<ImsScreen> createState() => _ImsScreenState();
}

class _ImsScreenState extends ConsumerState<ImsScreen> {
  String _period = previousMonth();
  String? _bucket;
  final Set<String> _selected = {};
  bool _busy = false;

  Future<void> _act(String action) async {
    String? reason;
    if (action == 'reject' || action == 'pending') {
      reason = await _askReason(action == 'reject' ? 'Reject' : 'Keep pending');
      if (reason == null) return;
    }
    setState(() => _busy = true);
    try {
      final n = await ref
          .read(gstComplianceRepositoryProvider)
          .imsAction(_selected.toList(), action, reason: reason);
      _selected.clear();
      ref.read(gstComplianceRevisionProvider.notifier).bump();
      if (mounted) showInfoSnackBar(context, 'Updated $n documents.');
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askReason(String title) {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLength: 300,
          decoration: const InputDecoration(labelText: 'Reason'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (c.text.trim().length >= 3) Navigator.pop(ctx, c.text.trim());
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final can = ref.watch(permissionsProvider).can(TaxPerm.gstManage);
    final value = ref.watch(imsProvider(_period));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeader(
          title: 'Invoice Management System',
          subtitle:
              'Accept, reject or hold supplier documents before you file '
              'GSTR-3B. No action counts as accepted.',
        ),
        FilterBar(
          children: [
            MonthPicker(
              period: _period,
              onChanged: (p) => setState(() {
                _period = p;
                _selected.clear();
              }),
            ),
          ],
        ),
        Expanded(
          child: AsyncValueView<ImsView>(
            value: value,
            onRetry: () => ref.invalidate(imsProvider(_period)),
            data: (v) => _content(v, can),
          ),
        ),
      ],
    );
  }

  Widget _content(ImsView v, bool can) {
    if (!v.imported) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('No GSTR-2B file is imported for this month.'),
        ),
      );
    }
    final rows = _bucket == null
        ? v.rows
        : v.rows.where((r) => r.bucket == _bucket).toList();
    final summaries = {
      'in_books_accepted': v.accepted,
      'in_books_rejected': v.rejected,
      'pending': v.pending,
      'not_in_books': v.notInBooks,
    };
    return Column(
      children: [
        SizedBox(
          height: 64,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            children: [
              for (final e in summaries.entries)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    selected: _bucket == e.key,
                    label: Text(
                      '${_bucketLabels[e.key]}: ${e.value.count} · '
                      '${formatMoney(e.value.itc)}',
                    ),
                    onSelected: (s) =>
                        setState(() => _bucket = s ? e.key : null),
                  ),
                ),
            ],
          ),
        ),
        if (can && _selected.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('${_selected.length} selected'),
                FilledButton(
                  onPressed: _busy ? null : () => _act('accept'),
                  child: const Text('Accept'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : () => _act('reject'),
                  child: const Text('Reject'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : () => _act('pending'),
                  child: const Text('Keep pending'),
                ),
                TextButton(
                  onPressed: _busy ? null : () => _act('none'),
                  child: const Text('Clear action'),
                ),
              ],
            ),
          ),
        if (can && rows.isNotEmpty)
          CheckboxListTile(
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Select all shown'),
            value: rows.every((r) => _selected.contains(r.id)),
            onChanged: (s) => setState(() {
              if (s == true) {
                _selected.addAll(rows.map((r) => r.id));
              } else {
                _selected.removeAll(rows.map((r) => r.id));
              }
            }),
          ),
        Expanded(
          child: rows.isEmpty
              ? const Center(child: Text('No documents here.'))
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
                  itemCount: rows.length,
                  itemBuilder: (_, i) => _tile(rows[i], can),
                ),
        ),
      ],
    );
  }

  Widget _tile(ImsRow r, bool can) {
    const names = {
      'accept': 'Accepted',
      'reject': 'Rejected',
      'pending': 'Pending',
    };
    final action =
        names[r.imsAction] ?? (r.bucket == 'not_in_books' ? 'No action' : 'Deemed accepted');
    return CheckboxListTile(
      controlAffinity: ListTileControlAffinity.leading,
      value: _selected.contains(r.id),
      onChanged: can
          ? (s) => setState(() {
              if (s == true) {
                _selected.add(r.id);
              } else {
                _selected.remove(r.id);
              }
            })
          : null,
      title: Text('${r.supplierName.isEmpty ? r.supplierGstin : r.supplierName} · ${r.docNo}'),
      subtitle: Text(
        '${formatDate(r.docDate)} · ${_bucketLabels[r.bucket]} · $action'
        '${r.purchaseNumber.isEmpty ? '' : ' · ${r.purchaseNumber}'}'
        '${r.imsReason.isEmpty ? '' : '\n${r.imsReason}'}',
      ),
      secondary: Text(formatMoney(r.tax)),
    );
  }
}
