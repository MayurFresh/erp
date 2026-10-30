import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import 'compliance_models.dart';
import 'compliance_repository.dart';

/// `/setup-health`: a score and a checklist of what is still missing.
class SetupHealthScreen extends ConsumerWidget {
  const SetupHealthScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(setupHealthProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeader(
          title: 'Setup health',
          subtitle: 'Details the statutory features rely on',
        ),
        Expanded(
          child: AsyncValueView<SetupHealth>(
            value: value,
            onRetry: () => ref.invalidate(setupHealthProvider),
            data: (h) => ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                _ScoreCard(score: h.score),
                const SizedBox(height: 12),
                for (final required in const [true, false]) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
                    child: Text(
                      required ? 'Required' : 'Recommended',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  for (final c in h.checks.where((c) => c.required == required))
                    _CheckTile(check: c),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ScoreCard extends StatelessWidget {
  const _ScoreCard({required this.score});

  final int score;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = score >= 80
        ? Colors.green.shade700
        : score >= 50
        ? Colors.orange.shade800
        : theme.colorScheme.error;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            SizedBox.square(
              dimension: 88,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox.expand(
                    child: CircularProgressIndicator(
                      value: score / 100,
                      strokeWidth: 9,
                      color: color,
                      backgroundColor: color.withValues(alpha: 0.15),
                    ),
                  ),
                  Text('$score%', style: theme.textTheme.titleLarge),
                ],
              ),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Text(
                score >= 100
                    ? 'Everything is in place.'
                    : 'Fix the open items below so returns, TDS and '
                          'invoices come out right.',
                style: theme.textTheme.bodyLarge,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CheckTile extends StatelessWidget {
  const _CheckTile({required this.check});

  final HealthCheck check;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        leading: Icon(
          check.ok ? Icons.check_circle : Icons.error_outline,
          color: check.ok
              ? Colors.green.shade700
              : check.required
              ? scheme.error
              : Colors.orange.shade800,
        ),
        title: Text(check.title),
        subtitle: check.detail.isEmpty ? null : Text(check.detail),
        trailing: check.ok || check.link.isEmpty
            ? null
            : const Icon(Icons.chevron_right),
        onTap: check.ok || check.link.isEmpty
            ? null
            : () => context.go(check.link),
      ),
    );
  }
}
