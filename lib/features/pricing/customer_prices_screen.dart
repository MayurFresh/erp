import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../../widgets/busy.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import 'price_rows_editor.dart';
import 'pricing_repository.dart';

/// Prices agreed with one customer. They override the customer's price list.
class CustomerPricesScreen extends ConsumerWidget {
  const CustomerPricesScreen({super.key, required this.partyId});

  final String partyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => AsyncValueView(
    value: ref.watch(customerPricesProvider(partyId)),
    onRetry: () => ref.invalidate(customerPricesProvider(partyId)),
    data: (rows) => _Body(
      partyId: partyId,
      initial: [for (final r in rows) RowDraft.from(r)],
    ),
  );
}

class _Body extends ConsumerStatefulWidget {
  const _Body({required this.partyId, required this.initial});

  final String partyId;
  final List<RowDraft> initial;

  @override
  ConsumerState<_Body> createState() => _BodyState();
}

class _BodyState extends ConsumerState<_Body> with DirtyTracking {
  final _formKey = GlobalKey<FormState>();
  late final List<RowDraft> _rows = widget.initial;
  bool _saving = false;

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !validateAndReveal(_formKey)) return;
    setState(() => _saving = true);
    try {
      await ref.read(pricingRepositoryProvider).saveCustomerPrices(
        widget.partyId,
        [for (final r in _rows) ?r.toRow()],
      );
      markSaved();
      ref.read(pricingRevisionProvider.notifier).bump();
      if (!mounted) return;
      showInfoSnackBar(context, 'Customer prices saved');
      context.go('/parties/${widget.partyId}');
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(permissionsProvider).can(Perm.pricingManage);
    return track(
      Form(
        key: _formKey,
        onChanged: markDirty,
        child: FormPage(
          maxWidth: 800,
          bottomBar: FormActionBar(
            children: [
              TextButton(
                onPressed: _saving ? null : () => leave('/parties/${widget.partyId}'),
                child: const Text('Cancel'),
              ),
              if (canEdit)
                BusyButton(busy: _saving, onPressed: _save, label: 'Save prices', icon: Icons.check),
            ],
          ),
          children: [
            Text('Customer prices', style: Theme.of(context).textTheme.headlineSmall),
            SectionCard(
              title: 'Agreed prices',
              child: IgnorePointer(
                ignoring: !canEdit,
                child: PriceRowsEditor(
                  rows: _rows,
                  emptyText: 'No special prices. This customer pays the price list or item price.',
                  onChanged: () {
                    setState(() {});
                    markDirty();
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
