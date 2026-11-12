import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import 'clinic_repository.dart';
import 'clinic_widgets.dart';
import 'ipd_forms.dart';
import 'ipd_models.dart';

Color _bedColour(BuildContext context, BedStatus s) {
  final c = Theme.of(context).colorScheme;
  return switch (s) {
    BedStatus.available => c.surfaceContainerLowest,
    BedStatus.occupied => c.primaryContainer,
    BedStatus.cleaning => c.tertiaryContainer,
    BedStatus.maintenance => c.surfaceContainerHighest,
  };
}

/// `/clinic/ipd`: the bed board. Wide screens show each ward as a grid of
/// beds; phones show one card per bed under the ward name.
class IpdBoardScreen extends ConsumerStatefulWidget {
  const IpdBoardScreen({super.key});

  @override
  ConsumerState<IpdBoardScreen> createState() => _IpdBoardScreenState();
}

class _IpdBoardScreenState extends ConsumerState<IpdBoardScreen> {
  bool _discharged = false;

  Future<void> _admit([String? bedId]) async {
    final a = await showFormDialog(
      context: context,
      builder: (_) => AdmitDialog(bedId: bedId),
    );
    if (a == null || !mounted) return;
    ref.bumpClinic(const [ClinicKind.ipd], money: true);
    context.push('/clinic/ipd/stays/${a.brief.id}');
  }

  Future<void> _runCharges() async {
    try {
      final n = await ref.read(clinicRepositoryProvider).runBedCharges();
      ref.bumpClinic(const [ClinicKind.ipd]);
      if (mounted) {
        showSuccess(
          context,
          n == 0 ? 'Bed charges are up to date' : '$n bed charges posted',
        );
      }
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _bedTap(IpdBed b) async {
    final stay = b.stay;
    if (stay != null) {
      context.push('/clinic/ipd/stays/${stay.admissionId}');
    } else if (b.status == BedStatus.available) {
      if (ref.read(permissionsProvider).can(Perm.clinicIpdManage)) {
        await _admit(b.id);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    final manage = perms.can(Perm.clinicIpdManage);
    return CGate(
      anyOf: const [Perm.clinicIpd, Perm.clinicIpdManage],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Beds and admissions',
            actions: [
              OutlinedButton.icon(
                style: bigOutlinedButton,
                onPressed: _runCharges,
                icon: const Icon(Icons.event_available_outlined),
                label: const Text('Post bed charges'),
              ),
              if (manage)
                OutlinedButton.icon(
                  style: bigOutlinedButton,
                  onPressed: () => context.push('/clinic/ipd/setup'),
                  icon: const Icon(Icons.tune),
                  label: const Text('Wards and beds'),
                ),
              if (manage)
                FilledButton.icon(
                  style: bigButton,
                  onPressed: _admit,
                  icon: const Icon(Icons.add),
                  label: const Text('Admit patient'),
                ),
            ],
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              pageGutter(context),
              0,
              pageGutter(context),
              8,
            ),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Beds')),
                ButtonSegment(value: true, label: Text('Discharged')),
              ],
              selected: {_discharged},
              onSelectionChanged: (s) => setState(() => _discharged = s.first),
            ),
          ),
          Expanded(
            child: _discharged
                ? const _DischargedList()
                : AsyncValueView<IpdBoard>(
                    value: ref.watch(ipdBoardProvider),
                    onRetry: () => ref.invalidate(ipdBoardProvider),
                    data: (board) => board.wards.isEmpty
                        ? EmptyView(
                            icon: Icons.bed_outlined,
                            message: manage
                                ? 'No wards yet. Add wards and beds first.'
                                : 'No wards set up yet.',
                          )
                        : _BoardBody(board: board, onTap: _bedTap),
                  ),
          ),
        ],
      ),
    );
  }
}

class _BoardBody extends StatelessWidget {
  const _BoardBody({required this.board, required this.onTap});

  final IpdBoard board;
  final ValueChanged<IpdBed> onTap;

  @override
  Widget build(BuildContext context) {
    final gutter = pageGutter(context);
    final c = board.counts;
    final wide = !isPhone(context);
    return ListView(
      padding: EdgeInsets.fromLTRB(gutter, 0, gutter, 24),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              Pill('${c.occupied} of ${c.total} beds occupied'),
              Pill('${c.available} free'),
              if (c.cleaning > 0) Pill('${c.cleaning} being cleaned'),
              if (c.maintenance > 0) Pill('${c.maintenance} in maintenance'),
            ],
          ),
        ),
        for (final w in board.wards) ...[
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 6),
            child: Text(
              '${w.name}  (${wardKindLabel(w.kind)})',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          if (w.beds.isEmpty)
            const Text('No beds in this ward.')
          else if (wide)
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final b in w.beds)
                  SizedBox(
                    width: 190,
                    child: _BedTile(bed: b, onTap: () => onTap(b)),
                  ),
              ],
            )
          else
            for (final b in w.beds)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _BedTile(bed: b, onTap: () => onTap(b), compact: true),
              ),
        ],
      ],
    );
  }
}

class _BedTile extends StatelessWidget {
  const _BedTile({
    required this.bed,
    required this.onTap,
    this.compact = false,
  });

  final IpdBed bed;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stay = bed.stay;
    final lines = <Widget>[
      Text(
        stay?.patientName ?? bed.status.label,
        style: theme.textTheme.bodyLarge?.copyWith(
          fontWeight: stay == null ? FontWeight.w400 : FontWeight.w600,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      Text(
        stay == null
            ? '${formatMoney(bed.dailyRate)} a day'
            : '${stay.doctorName}  |  day ${stay.days}',
        style: theme.textTheme.bodySmall,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ];
    return Card(
      key: ValueKey('bed-${bed.id}'),
      margin: EdgeInsets.zero,
      color: _bedColour(context, bed.status),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: compact
              ? Row(
                  children: [
                    SizedBox(
                      width: 56,
                      child: Text(
                        bed.bedNo,
                        style: theme.textTheme.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: lines,
                      ),
                    ),
                    if (stay != null) const Icon(Icons.chevron_right),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            bed.bedNo,
                            style: theme.textTheme.titleMedium,
                          ),
                        ),
                        Text(
                          bed.status.label,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    ...lines,
                  ],
                ),
        ),
      ),
    );
  }
}

class _DischargedList extends ConsumerWidget {
  const _DischargedList();

  @override
  Widget build(
    BuildContext context,
    WidgetRef ref,
  ) => AsyncValueView<List<AdmissionBrief>>(
    value: ref.watch(ipdDischargedProvider),
    onRetry: () => ref.invalidate(ipdDischargedProvider),
    data: (list) => list.isEmpty
        ? const EmptyView(
            icon: Icons.logout,
            message: 'No discharged patients yet.',
          )
        : ListView(
            padding: EdgeInsets.fromLTRB(
              pageGutter(context),
              0,
              pageGutter(context),
              24,
            ),
            children: [
              for (final a in list)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Card(
                    margin: EdgeInsets.zero,
                    child: ListTile(
                      key: ValueKey('stay-${a.id}'),
                      onTap: () => context.push('/clinic/ipd/stays/${a.id}'),
                      title: Text(a.patientName),
                      subtitle: Text(
                        '${a.number}  |  ${formatDate(a.admitDate)} to '
                        '${formatDate(a.dischargeDate)}  |  ${a.doctorName}',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                    ),
                  ),
                ),
            ],
          ),
  );
}
