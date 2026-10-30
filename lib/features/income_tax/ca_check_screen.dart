import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../compliance/compliance_widgets.dart' show recentFys;
import 'it_models.dart';
import 'it_repository.dart';

/// `/ca-check`: "Do I need a CA?" (API v1.6 §8).
class CaCheckScreen extends ConsumerStatefulWidget {
  const CaCheckScreen({super.key});

  @override
  ConsumerState<CaCheckScreen> createState() => _CaCheckScreenState();
}

class _CaCheckScreenState extends ConsumerState<CaCheckScreen> {
  String _taxYear = recentFys().first;

  @override
  Widget build(BuildContext context) {
    final value = ref.watch(caRequiredProvider(_taxYear));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeader(
          title: 'Do I need a CA?',
          subtitle: 'What the law requires, and what you can file yourself',
        ),
        FilterBar(
          children: [
            SizedBox(
              width: 170,
              child: DropdownButtonFormField<String>(
                initialValue: _taxYear,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Tax year'),
                items: [
                  for (final f in recentFys())
                    DropdownMenuItem(value: f, child: Text(f)),
                ],
                onChanged: (v) => setState(() => _taxYear = v ?? _taxYear),
              ),
            ),
          ],
        ),
        Expanded(
          child: AsyncValueView<CaRequired>(
            value: value,
            onRetry: () => ref.invalidate(caRequiredProvider(_taxYear)),
            data: (r) => ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                if (r.items.isEmpty)
                  const SectionCard(
                    child: Text('Nothing here needs a chartered accountant.'),
                  ),
                for (final i in r.items) _CaItemCard(item: i),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _CaItemCard extends StatelessWidget {
  const _CaItemCard({required this.item});

  final CaItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final covered = item.canSelfFile;
    return SectionCard(
      title: item.title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Pill(
            item.isRequired ? 'Required' : 'Advised',
            color: item.isRequired
                ? Colors.red.shade700
                : Colors.orange.shade800,
          ),
          const SizedBox(height: 8),
          Text(
            item.isRequired
                ? 'The law requires a chartered accountant for this.'
                : 'A chartered accountant is advised for this.',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(item.reason),
          if (item.law.isNotEmpty)
            Text(item.law, style: theme.textTheme.bodySmall),
          if (covered != null) ...[
            const SizedBox(height: 8),
            Text('You can file this yourself. The app covers $covered.'),
          ],
        ],
      ),
    );
  }
}
