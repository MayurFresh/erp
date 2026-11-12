import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import 'clinic_models.dart';
import 'clinic_repository.dart';
import 'clinic_widgets.dart';
import 'front_desk_screen.dart';

/// `/clinic/doctor`: the doctor's day, the next patient and the consultation.
class DoctorDayScreen extends ConsumerStatefulWidget {
  const DoctorDayScreen({super.key});

  @override
  ConsumerState<DoctorDayScreen> createState() => _DoctorDayScreenState();
}

class _DoctorDayScreenState extends ConsumerState<DoctorDayScreen> {
  String? _doctorId;
  bool _starting = false;

  Future<void> _open(Appointment a) async {
    if (_starting) return;
    setState(() => _starting = true);
    try {
      final v = a.visitId != null
          ? null
          : await ref
                .read(clinicRepositoryProvider)
                .startVisit(appointmentId: a.id);
      ref.bumpClinic(const [ClinicKind.appointments, ClinicKind.visits]);
      if (mounted) context.go('/clinic/visits/${v?.id ?? a.visitId}');
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider).value;
    final doctors = ref.watch(clinicDoctorsProvider).value ?? const <Doctor>[];
    final mine = doctors
        .where((d) => d.userId != null && d.userId == session?.user?.id)
        .firstOrNull;
    final doctorId = _doctorId ?? mine?.id;
    final consult = ref.watch(permissionsProvider).can(Perm.clinicConsult);
    final queue = doctorId == null
        ? null
        : ref.watch(
            clinicQueueProvider((date: apiDate(today()), doctorId: doctorId)),
          );
    return CGate(
      anyOf: const [Perm.clinicConsult],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(title: 'My day'),
          FilterBar(
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320, minWidth: 220),
                child: DoctorDropdown(
                  value: doctorId,
                  onChanged: (v) => setState(() => _doctorId = v),
                ),
              ),
            ],
          ),
          Expanded(
            child: queue == null
                ? const EmptyView(
                    icon: Icons.medical_services_outlined,
                    message: 'Choose a doctor to see the day.',
                  )
                : AsyncValueView<List<Appointment>>(
                    value: queue,
                    onRetry: () => ref.invalidate(clinicQueueProvider),
                    data: (list) {
                      final inRoom = list
                          .where((a) => a.status == ApptStatus.inConsultation)
                          .firstOrNull;
                      final waiting =
                          list
                              .where((a) => a.status == ApptStatus.arrived)
                              .toList()
                            ..sort(
                              (a, b) => (a.tokenNo ?? 1 << 30).compareTo(
                                b.tokenNo ?? 1 << 30,
                              ),
                            );
                      final next = inRoom ?? waiting.firstOrNull;
                      final gutter = pageGutter(context);
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: EdgeInsets.fromLTRB(gutter, 4, gutter, 4),
                            child: SectionCard(
                              title: inRoom != null
                                  ? 'With you now'
                                  : 'Next patient',
                              child: next == null
                                  ? const Text('No one is waiting.')
                                  : Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '${next.patient.name}   ${next.when}',
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleMedium,
                                        ),
                                        Text(
                                          [
                                            next.patient.line,
                                            if (next.reason != null)
                                              next.reason!,
                                          ].join('  |  '),
                                        ),
                                        const SizedBox(height: 10),
                                        FilledButton.icon(
                                          style: bigButton,
                                          onPressed: consult && !_starting
                                              ? () => _open(next)
                                              : null,
                                          icon: const Icon(
                                            Icons.play_arrow_outlined,
                                          ),
                                          label: Text(
                                            inRoom != null
                                                ? 'Continue consultation'
                                                : 'Open consultation',
                                          ),
                                        ),
                                      ],
                                    ),
                            ),
                          ),
                          Expanded(
                            child: list.isEmpty
                                ? const EmptyView(
                                    icon: Icons.event_available_outlined,
                                    message: 'No appointments today.',
                                  )
                                : QueueView(
                                    appointments: list,
                                    desk: false,
                                    onOpen: (a) {
                                      if (a.status == ApptStatus.arrived ||
                                          a.status ==
                                              ApptStatus.inConsultation ||
                                          a.status == ApptStatus.booked) {
                                        _open(a);
                                      } else if (a.visitId != null) {
                                        context.go(
                                          '/clinic/visits/${a.visitId}',
                                        );
                                      } else {
                                        context.go(
                                          '/clinic/patients/${a.patient.id}',
                                        );
                                      }
                                    },
                                  ),
                          ),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
