import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../widgets/layout.dart';
import 'gst_compliance_repository.dart';

/// GST rate history of one item, newest first. Shown on the item form.
class RateHistoryCard extends ConsumerWidget {
  const RateHistoryCard({super.key, required this.itemId});

  final String itemId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rates = ref.watch(itemRatesProvider(itemId)).value;
    if (rates == null || rates.isEmpty) return const SizedBox.shrink();
    return SectionCard(
      title: 'GST rate history',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final r in rates)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                'From ${formatDate(r.effectiveFrom)}: ${formatPercent(r.rate)}'
                '${r.reason.isEmpty ? '' : ' · ${r.reason}'}',
              ),
            ),
          const SizedBox(height: 4),
          Text(
            'An invoice uses the rate in force on its date.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
