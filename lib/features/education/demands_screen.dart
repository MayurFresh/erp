import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import 'education_models.dart';
import 'education_repository.dart';
import 'education_widgets.dart';

/// `/education/demands`: raise one instalment's fee bills for a class. The
/// preview shows how many bills will be made before anything is posted.
class DemandsScreen extends ConsumerStatefulWidget {
  const DemandsScreen({super.key});

  @override
  ConsumerState<DemandsScreen> createState() => _DemandsScreenState();
}

class _DemandsScreenState extends ConsumerState<DemandsScreen> {
  String? _classId;
  String? _instalmentId;
  bool _late = true;
  bool _busy = false;
  DemandResult? _preview;
  DemandResult? _done;

  Map<String, Object?> get _body => {
    'classId': _classId,
    'instalmentId': _instalmentId,
    'applyLateFee': _late,
  };

  Future<void> _runPreview() async {
    if (_busy || _classId == null || _instalmentId == null) return;
    setState(() {
      _busy = true;
      _done = null;
    });
    try {
      final r = await ref.read(eduRepositoryProvider).generate({
        ..._body,
        'preview': true,
      });
      if (mounted) setState(() => _preview = r);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _post() async {
    final p = _preview;
    if (_busy || p == null || p.count == 0) return;
    final ok = await confirm(
      context,
      title: 'Post ${p.count} fee bills?',
      message:
          '${p.label} for ${formatMoney(p.amount)} before tax. Each student gets one bill.',
      confirmLabel: 'Post bills',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      final r = await ref.read(eduRepositoryProvider).generate(_body);
      if (!mounted) return;
      ref.bumpEdu(const [EduKind.fees], money: true);
      setState(() {
        _done = r;
        _preview = null;
      });
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final plan = _classId == null
        ? null
        : ref.watch(eduPlanProvider(_classId!));
    final instalments = plan?.value?.instalments ?? const <Instalment>[];
    return CGate(
      anyOf: const [Perm.educationFees, Perm.educationManage],
      child: FormPage(
        maxWidth: 720,
        children: [
          Text('Generate fee bills', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 4),
          const Text(
            'One bill per active student. Students already billed for the instalment are skipped, so it is safe to run again.',
          ),
          const SizedBox(height: 16),
          ClassDropdown(
            value: _classId,
            onChanged: (v) => setState(() {
              _classId = v;
              _instalmentId = null;
              _preview = null;
              _done = null;
            }),
          ),
          const SizedBox(height: 12),
          if (plan != null && plan.hasValue && plan.value == null)
            Text(
              'This class has no fee plan yet. Set it up under Classes and fee plans.',
              style: TextStyle(color: theme.colorScheme.error),
            )
          else
            DropdownButtonFormField<String>(
              key: ValueKey('inst-$_classId-${instalments.length}'),
              initialValue: instalments.any((i) => i.id == _instalmentId)
                  ? _instalmentId
                  : null,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Instalment'),
              items: [
                for (final i in instalments)
                  DropdownMenuItem(
                    value: i.id,
                    child: Text(
                      '${i.label}, due ${formatDate(i.dueDate)}, ${formatMoney(i.total)}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: _classId == null
                  ? null
                  : (v) => setState(() {
                      _instalmentId = v;
                      _preview = null;
                      _done = null;
                    }),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Add the late fee when the due date has passed'),
            subtitle: const Text('Only if the fee plan has a late fee rule'),
            value: _late,
            onChanged: (v) => setState(() {
              _late = v;
              _preview = null;
            }),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              style: bigOutlinedButton,
              onPressed: _busy || _instalmentId == null ? null : _runPreview,
              icon: const Icon(Icons.visibility_outlined),
              label: const Text('Preview'),
            ),
          ),
          if (_preview != null) ...[
            const SizedBox(height: 16),
            SectionCard(
              title: 'Preview, ${_preview!.label}',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${_preview!.count} bills to post',
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: 4),
                  Text('Total before tax ${formatMoney(_preview!.amount)}'),
                  if (_preview!.concessionAmount > 0)
                    Text(
                      'Concessions ${formatMoney(_preview!.concessionAmount)}',
                    ),
                  if (_preview!.lateFeeCount > 0)
                    Text(
                      'Late fee on ${_preview!.lateFeeCount} bills, ${formatMoney(_preview!.lateFeeAmount)}',
                    ),
                  if (_preview!.alreadyBilled > 0)
                    Text(
                      '${_preview!.alreadyBilled} students already billed, skipped',
                    ),
                  if (_preview!.nothingToBill > 0)
                    Text(
                      '${_preview!.nothingToBill} students have nothing to pay',
                    ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    style: bigButton,
                    onPressed: _busy || _preview!.count == 0 ? null : _post,
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send_outlined),
                    label: Text('Post ${_preview!.count} bills'),
                  ),
                ],
              ),
            ),
          ],
          if (_done != null) ...[
            const SizedBox(height: 16),
            SectionCard(
              title: 'Done',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _done!.created == 0
                        ? 'No new bills. Everyone was already billed.'
                        : '${_done!.created} bills posted for ${_done!.label}.',
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => context.go('/education/dues'),
                    child: const Text('See dues'),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
