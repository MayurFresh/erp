import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../compliance/tax_perms.dart';
import 'gst_compliance_repository.dart';

/// `/gst-slab-review`: item-by-item review of the 22 September 2025 slabs.
/// Nothing changes until the user accepts a row.
class SlabReviewScreen extends ConsumerStatefulWidget {
  const SlabReviewScreen({super.key});

  @override
  ConsumerState<SlabReviewScreen> createState() => _SlabReviewScreenState();
}

class _SlabReviewScreenState extends ConsumerState<SlabReviewScreen> {
  final Map<String, double> _pick = {};
  bool _busy = false;

  Future<void> _apply(SlabReview r) async {
    setState(() => _busy = true);
    try {
      final n = await ref
          .read(gstComplianceRepositoryProvider)
          .applySlab(r.effectiveFrom, _pick);
      _pick.clear();
      ref.read(gstComplianceRevisionProvider.notifier).bump();
      if (mounted) showInfoSnackBar(context, 'Saved $n items.');
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final can = ref.watch(permissionsProvider).can(TaxPerm.gstManage);
    final value = ref.watch(slabReviewProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeader(
          title: 'GST slab review',
          subtitle: 'Items at 12% or 28% and the rate they may move to',
        ),
        Expanded(
          child: AsyncValueView<SlabReview>(
            value: value,
            onRetry: () => ref.invalidate(slabReviewProvider),
            data: (r) => ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                Text(r.note),
                const SizedBox(height: 8),
                Text(
                  'Invoices dated before ${formatDate(r.effectiveFrom)} keep '
                  'the old rate.',
                ),
                const SizedBox(height: 12),
                if (r.rows.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: Text('No items at 12% or 28%.')),
                  ),
                for (final row in r.rows) _tile(row, can),
                if (can && _pick.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: FilledButton(
                      onPressed: _busy ? null : () => _apply(r),
                      child: Text('Save ${_pick.length} items'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _tile(SlabRow row, bool can) {
    final chosen = _pick[row.itemId];
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(row.name, style: Theme.of(context).textTheme.titleSmall),
            Text(
              '${row.hsnCode.isEmpty ? 'No HSN' : 'HSN ${row.hsnCode}'} · '
              'now ${formatPercent(row.currentRate)} · proposed '
              '${formatPercent(row.proposedRate)}'
              '${row.needsCheck ? ' · check the notification for this HSN' : ''}',
            ),
            const SizedBox(height: 8),
            if (row.reviewed)
              const Text('Reviewed')
            else if (can)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    selected: chosen == row.proposedRate,
                    label: Text('Move to ${formatPercent(row.proposedRate)}'),
                    onSelected: (s) => setState(() {
                      s ? _pick[row.itemId] = row.proposedRate : _pick.remove(row.itemId);
                    }),
                  ),
                  ChoiceChip(
                    selected: chosen == row.currentRate,
                    label: Text('Keep ${formatPercent(row.currentRate)}'),
                    onSelected: (s) => setState(() {
                      s ? _pick[row.itemId] = row.currentRate : _pick.remove(row.itemId);
                    }),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
