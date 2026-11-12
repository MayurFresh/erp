import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import 'bill_dialog.dart';
import 'clinic_dialogs.dart';
import 'clinic_models.dart';
import 'clinic_repository.dart';
import 'clinic_widgets.dart';

/// `/clinic`: today's queue by doctor, with booking, registration and tokens.
class FrontDeskScreen extends ConsumerStatefulWidget {
  const FrontDeskScreen({super.key});

  @override
  ConsumerState<FrontDeskScreen> createState() => _FrontDeskScreenState();
}

class _FrontDeskScreenState extends ConsumerState<FrontDeskScreen> {
  DateTime _day = today();
  String? _doctorId;

  Future<void> _register() async {
    final saved = await showFormDialog<Patient>(
      context: context,
      builder: (_) => PatientFormDialog(
        canEditNotes: ref.read(permissionsProvider).can(Perm.clinicConsult),
      ),
    );
    if (saved == null || !mounted) return;
    ref.bumpClinic(const [ClinicKind.patients], money: true);
    showSuccess(context, '${saved.name} registered, ${saved.brief.uhid}');
    final book = await confirm(
      context,
      title: 'Book a visit for ${saved.name}?',
      message: 'Issue a walk-in token or book a time.',
      confirmLabel: 'Book',
    );
    if (book && mounted) await _book(patient: saved.brief);
  }

  Future<void> _book({PatientBrief? patient, bool walkIn = false}) async {
    final appt = await showFormDialog<Appointment>(
      context: context,
      builder: (_) =>
          BookDialog(patient: patient, doctorId: _doctorId, walkIn: walkIn),
    );
    if (appt == null || !mounted) return;
    ref.bumpClinic(const [ClinicKind.appointments]);
    showSuccess(
      context,
      appt.tokenNo != null && appt.startTime == null
          ? 'Token ${appt.tokenNo} for ${appt.patient.name}'
          : 'Booked ${appt.patient.name} at ${appt.startTime}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    final desk = perms.canAny(const [Perm.clinicFrontDesk, Perm.clinicManage]);
    final isToday = _day == today();
    final queue = ref.watch(
      clinicQueueProvider((date: apiDate(_day), doctorId: _doctorId)),
    );
    return CGate(
      anyOf: const [Perm.clinicView],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Front desk',
            actions: [
              if (desk)
                OutlinedButton.icon(
                  style: bigOutlinedButton,
                  onPressed: () => _book(walkIn: true),
                  icon: const Icon(Icons.confirmation_number_outlined),
                  label: const Text('Walk-in token'),
                ),
              if (desk)
                OutlinedButton.icon(
                  style: bigOutlinedButton,
                  onPressed: _book,
                  icon: const Icon(Icons.event_outlined),
                  label: const Text('Book appointment'),
                ),
              if (desk)
                FilledButton.icon(
                  style: bigButton,
                  onPressed: _register,
                  icon: const Icon(Icons.person_add_alt_outlined),
                  label: const Text('Register patient'),
                ),
            ],
          ),
          FilterBar(
            children: [
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  IconButton(
                    tooltip: 'Previous day',
                    onPressed: () => setState(
                      () => _day = _day.subtract(const Duration(days: 1)),
                    ),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  TextButton(
                    onPressed: () async {
                      final d = await showDatePicker(
                        context: context,
                        initialDate: _day,
                        firstDate: DateTime(2020),
                        lastDate: today().add(const Duration(days: 180)),
                      );
                      if (d != null) {
                        setState(() => _day = DateUtils.dateOnly(d));
                      }
                    },
                    child: Text(
                      isToday ? 'Today, ${dayLabel(_day)}' : dayLabel(_day),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Next day',
                    onPressed: () => setState(
                      () => _day = _day.add(const Duration(days: 1)),
                    ),
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 300, minWidth: 200),
                child: DoctorDropdown(
                  value: _doctorId,
                  allowAll: true,
                  onChanged: (v) => setState(() => _doctorId = v),
                ),
              ),
              TextButton.icon(
                onPressed: () => context.go('/clinic/patients'),
                icon: const Icon(Icons.groups_outlined),
                label: const Text('Patients'),
              ),
            ],
          ),
          Expanded(
            child: AsyncValueView<List<Appointment>>(
              value: queue,
              onRetry: () => ref.invalidate(clinicQueueProvider),
              data: (list) => list.isEmpty
                  ? EmptyView(
                      icon: Icons.event_available_outlined,
                      message: isToday
                          ? 'No one in the queue yet.'
                          : 'No appointments on this day.',
                    )
                  : QueueView(appointments: list, desk: desk),
            ),
          ),
        ],
      ),
    );
  }
}

/// Appointments grouped by doctor, with the row actions.
class QueueView extends ConsumerStatefulWidget {
  const QueueView({
    super.key,
    required this.appointments,
    required this.desk,
    this.onOpen,
  });

  final List<Appointment> appointments;
  final bool desk;

  /// Replaces the default tap (patient file), e.g. to open a consultation.
  final void Function(Appointment)? onOpen;

  @override
  ConsumerState<QueueView> createState() => _QueueViewState();
}

class _QueueViewState extends ConsumerState<QueueView> {
  final _busy = <String>{};

  Future<void> _run(Appointment a, Future<void> Function() action) async {
    if (!_busy.add(a.id)) return;
    setState(() {});
    final ok = await guarded(context, action);
    if (ok) ref.bumpClinic(const [ClinicKind.appointments]);
    _busy.remove(a.id);
    if (mounted) setState(() {});
  }

  Future<void> _status(Appointment a, String status) async {
    String? reason;
    if (status == 'cancelled') {
      reason = await showReasonDialog(
        context,
        title: 'Cancel ${a.patient.name}?',
        message: 'The time becomes free for someone else.',
        confirmLabel: 'Cancel appointment',
      );
      if (reason == null) return;
    }
    await _run(a, () async {
      await ref
          .read(clinicRepositoryProvider)
          .setStatus(a.id, status, reason: reason);
    });
  }

  Future<void> _reschedule(Appointment a) async {
    final moved = await showFormDialog<Appointment>(
      context: context,
      builder: (_) => RescheduleDialog(appointment: a),
    );
    if (moved != null) ref.bumpClinic(const [ClinicKind.appointments]);
  }

  Future<void> _bill(Appointment a) async {
    if (a.visitId == null) return;
    final done = await showFormDialog<bool>(
      context: context,
      builder: (_) => BillDialog(visitId: a.visitId!),
    );
    if (done == true) {
      ref.bumpClinic(const [
        ClinicKind.appointments,
        ClinicKind.visits,
      ], money: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final byDoctor = <String, List<Appointment>>{};
    for (final a in widget.appointments) {
      byDoctor.putIfAbsent(a.doctorName, () => []).add(a);
    }
    final perms = ref.watch(permissionsProvider);
    final canBill = perms.can(Perm.invoicesCreate);
    final gutter = pageGutter(context);
    return ListView(
      padding: EdgeInsets.fromLTRB(gutter, 0, gutter, 24),
      children: [
        for (final entry in byDoctor.entries) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 12, 0, 6),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: entry.key,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  TextSpan(
                    text:
                        '   ${entry.value.where((a) => a.status == ApptStatus.arrived).length} waiting, '
                        '${entry.value.where((a) => a.status == ApptStatus.booked).length} booked, '
                        '${entry.value.where((a) => a.status == ApptStatus.done).length} done',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          for (final a in entry.value)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Card(
                margin: EdgeInsets.zero,
                child: ListTile(
                  key: ValueKey('appt-${a.id}'),
                  onTap: () => widget.onOpen != null
                      ? widget.onOpen!(a)
                      : context.go('/clinic/patients/${a.patient.id}'),
                  leading: SizedBox(
                    width: 64,
                    child: Text(
                      a.when.isEmpty ? '-' : a.when.replaceFirst('  ', '\n'),
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                  title: Text(
                    a.patient.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    [
                      a.patient.line,
                      if (a.reason != null) a.reason!,
                    ].join('  |  '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(child: ApptStatusChip(a.status)),
                      if (_busy.contains(a.id))
                        const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      else
                        PopupMenuButton<String>(
                          tooltip: 'Actions',
                          onSelected: (v) {
                            switch (v) {
                              case 'arrived':
                              case 'cancelled':
                              case 'no_show':
                                _status(a, v);
                              case 'reschedule':
                                _reschedule(a);
                              case 'bill':
                                _bill(a);
                              case 'patient':
                                context.go('/clinic/patients/${a.patient.id}');
                            }
                          },
                          itemBuilder: (_) => [
                            const PopupMenuItem(
                              value: 'patient',
                              child: Text('Patient file'),
                            ),
                            if (widget.desk &&
                                a.status == ApptStatus.booked) ...const [
                              PopupMenuItem(
                                value: 'arrived',
                                child: Text('Mark arrived'),
                              ),
                              PopupMenuItem(
                                value: 'reschedule',
                                child: Text('Reschedule'),
                              ),
                              PopupMenuItem(
                                value: 'no_show',
                                child: Text('Mark no show'),
                              ),
                            ],
                            if (widget.desk &&
                                (a.status == ApptStatus.booked ||
                                    a.status == ApptStatus.arrived))
                              const PopupMenuItem(
                                value: 'cancelled',
                                child: Text('Cancel'),
                              ),
                            if (canBill && a.visitId != null && !a.billed)
                              const PopupMenuItem(
                                value: 'bill',
                                child: Text('Bill the visit'),
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ],
    );
  }
}
