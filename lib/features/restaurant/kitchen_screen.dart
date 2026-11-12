import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_colors.dart';
import '../../core/design_tokens.dart';
import '../../core/money.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../construction/common/c_widgets.dart' show CGate;
import 'rest_models.dart';
import 'rest_perms.dart';
import 'rest_repository.dart';
import 'rest_widgets.dart';

/// `/restaurant/kitchen`: tickets as large cards; tap the button to move a
/// ticket along. Reloads on its own.
class KitchenScreen extends ConsumerStatefulWidget {
  const KitchenScreen({super.key});

  @override
  ConsumerState<KitchenScreen> createState() => _KitchenScreenState();
}

class _KitchenScreenState extends ConsumerState<KitchenScreen> {
  static const _live = 'new,preparing,ready';
  String _station = '';
  RestPoller? _poller;

  ({String station, String status}) get _query =>
      (station: _station, status: _live);

  @override
  void initState() {
    super.initState();
    _poller = RestPoller(
      ref.read(restPollProvider),
      () => ref.invalidate(restKotsProvider(_query)),
    );
  }

  @override
  void dispose() {
    _poller?.dispose();
    super.dispose();
  }

  Future<void> _advance(Kot kot) async {
    final next = kot.status.next;
    if (next == null) return;
    final ok = await restGuarded(
      context,
      () => ref.read(restaurantRepositoryProvider).advanceKot(kot.id, next),
    );
    if (ok) ref.bumpRest();
  }

  Future<void> _advanceLine(KotLine line) async {
    final next = line.kitchenStatus.next;
    if (next == null || line.isCancelled) return;
    final ok = await restGuarded(
      context,
      () => ref.read(restaurantRepositoryProvider).advanceLine(line.id, next),
    );
    if (ok) ref.bumpRest();
  }

  @override
  Widget build(BuildContext context) {
    final stations =
        ref.watch(restSettingsProvider).value?.stations ?? const ['Main'];
    return CGate(
      anyOf: const [RestPerm.kitchen, RestPerm.manage],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(title: 'Kitchen'),
          SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: pageGutter(context)),
              children: [
                for (final s in ['', ...stations])
                  Padding(
                    padding: const EdgeInsets.only(right: Space.sm),
                    child: ChoiceChip(
                      label: Text(s.isEmpty ? 'All stations' : s),
                      selected: _station == s,
                      onSelected: (_) => setState(() => _station = s),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: AsyncValueView(
              value: ref.watch(restKotsProvider(_query)),
              onRetry: () => ref.invalidate(restKotsProvider(_query)),
              data: (kots) {
                if (kots.isEmpty) {
                  return const EmptyView(
                    icon: Icons.soup_kitchen_outlined,
                    message: 'No tickets waiting. New orders show up here.',
                  );
                }
                return LayoutBuilder(
                  builder: (context, box) {
                    final gutter = pageGutter(context);
                    final avail = box.maxWidth - gutter * 2;
                    final cols = math.max(1, (avail / 300).floor());
                    final width = (avail - (cols - 1) * Space.md) / cols;
                    return RefreshIndicator(
                      onRefresh: () async =>
                          ref.refresh(restKotsProvider(_query).future),
                      child: SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: EdgeInsets.all(gutter),
                        child: Wrap(
                          spacing: Space.md,
                          runSpacing: Space.md,
                          children: [
                            for (final k in kots)
                              SizedBox(
                                width: width,
                                child: KotCard(
                                  kot: k,
                                  onAdvance: () => _advance(k),
                                  onLine: _advanceLine,
                                  onPrint: () =>
                                      printKots(context, ref, [k.id]),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class KotCard extends StatelessWidget {
  const KotCard({
    super.key,
    required this.kot,
    required this.onAdvance,
    required this.onLine,
    required this.onPrint,
  });

  final Kot kot;
  final Future<void> Function() onAdvance;
  final ValueChanged<KotLine> onLine;
  final VoidCallback onPrint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.colors;
    final (border, tint, fg) = switch (kot.status) {
      KitchenStatus.ready => (
        colors.success,
        colors.successContainer,
        colors.onSuccessContainer,
      ),
      KitchenStatus.preparing => (
        colors.warning,
        colors.warningContainer,
        colors.onWarningContainer,
      ),
      _ => (colors.info, colors.infoContainer, colors.onInfoContainer),
    };
    final minutes = kot.createdAt == null
        ? 0
        : DateTime.now().difference(kot.createdAt!).inMinutes;
    final late = minutes >= 15 && kot.status != KitchenStatus.ready;
    final next = kot.status.next;
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border.all(color: border, width: 2),
        borderRadius: Radii.largeAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: tint,
            padding: const EdgeInsets.all(Space.md),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        kot.where,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          color: fg,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        'KOT ${kot.kotNo} · ${kot.station}',
                        style: theme.textTheme.titleSmall?.copyWith(color: fg),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      ageText(kot.createdAt),
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: late ? colors.danger : fg,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      kot.status.label,
                      style: theme.textTheme.labelLarge?.copyWith(color: fg),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(Space.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final l in kot.lines)
                  InkWell(
                    onTap: l.isCancelled || l.kitchenStatus.next == null
                        ? null
                        : () => onLine(l),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: Space.xs),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 52,
                            child: Text(
                              '${formatQty(l.qty)} ×',
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w800,
                                decoration: l.isCancelled
                                    ? TextDecoration.lineThrough
                                    : null,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  l.name,
                                  style: theme.textTheme.titleLarge?.copyWith(
                                    decoration: l.isCancelled
                                        ? TextDecoration.lineThrough
                                        : null,
                                  ),
                                ),
                                if ((l.note ?? '').isNotEmpty)
                                  Text(
                                    l.note!,
                                    style: theme.textTheme.titleSmall?.copyWith(
                                      fontStyle: FontStyle.italic,
                                      color: colors.danger,
                                    ),
                                  ),
                                if (l.isCancelled)
                                  Text(
                                    'CANCELLED',
                                    style: theme.textTheme.labelLarge?.copyWith(
                                      color: colors.danger,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          if (!l.isCancelled && l.kitchenStatus != kot.status)
                            StatusTag(
                              l.kitchenStatus.label,
                              bg: colors.neutralContainer,
                              fg: colors.onNeutralContainer,
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.md, 0, Space.md, Space.md),
            child: Row(
              children: [
                IconButton.outlined(
                  tooltip: 'Print ticket',
                  onPressed: onPrint,
                  icon: const Icon(Icons.print_outlined),
                ),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: BusyButton(
                    onPressed: next == null ? null : onAdvance,
                    label: kot.status.advanceLabel.isEmpty
                        ? 'Done'
                        : kot.status.advanceLabel,
                    icon: switch (kot.status) {
                      KitchenStatus.newTicket => Icons.play_arrow,
                      KitchenStatus.preparing =>
                        Icons.notifications_active_outlined,
                      _ => Icons.check,
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
