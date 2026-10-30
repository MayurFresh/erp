import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../accounts/account_model.dart';
import '../accounts/accounts_repository.dart';
import '../auth/session.dart';
import 're_models.dart';
import 're_perms.dart';
import 're_repository.dart';
import 're_widgets.dart';

/// Active bank accounts, the only kind a RERA account may be.
final reraBankAccountsProvider = FutureProvider.autoDispose<List<Account>>((
  ref,
) async {
  ref.watch(activeCompanyIdProvider);
  final page = await ref
      .watch(accountsRepositoryProvider)
      .list(type: 'asset', subtype: 'bank', activeOnly: true, limit: 200);
  return page.data;
});

/// `/rera`: 70% collections account position per project.
class ReraScreen extends ConsumerStatefulWidget {
  const ReraScreen({super.key});

  @override
  ConsumerState<ReraScreen> createState() => _ReraScreenState();
}

class _ReraScreenState extends ConsumerState<ReraScreen> {
  String? _projectId;

  @override
  Widget build(BuildContext context) {
    final id = _projectId;
    return CGate(
      anyOf: const [RePerm.bookingsView],
      child: CPage(
        maxWidth: 900,
        children: [
          const PageHeader(title: 'RERA account'),
          ProjectField(
            value: id,
            onChanged: (v) => setState(() => _projectId = v),
          ),
          const SizedBox(height: 16),
          if (id == null)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('Choose a project to see its RERA position.'),
            )
          else
            AsyncValueView(
              value: ref.watch(projectReraProvider(id)),
              onRetry: () => ref.invalidate(projectReraProvider(id)),
              data: (r) => _ReraBody(key: ValueKey(r.projectId), rera: r),
            ),
        ],
      ),
    );
  }
}

class _ReraBody extends ConsumerStatefulWidget {
  const _ReraBody({super.key, required this.rera});

  final ProjectRera rera;

  @override
  ConsumerState<_ReraBody> createState() => _ReraBodyState();
}

class _ReraBodyState extends ConsumerState<_ReraBody> {
  late final _regNo = TextEditingController(text: widget.rera.reraRegNo);
  late String? _accountId = widget.rera.reraAccountId;
  bool _saving = false;

  @override
  void dispose() {
    _regNo.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref
          .read(realEstateRepositoryProvider)
          .updateProjectRera(
            widget.rera.projectId,
            reraRegNo: trimmedOrNull(_regNo.text),
            reraAccountId: _accountId,
          );
      ref.invalidate(projectReraProvider(widget.rera.projectId));
      ref.bumpR(const [RKind.rera]);
      if (mounted) showSuccess(context, 'RERA details saved');
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = widget.rera;
    final canEdit = ref.watch(permissionsProvider).can('projects.manage');
    final banks =
        ref.watch(reraBankAccountsProvider).value ?? const <Account>[];
    final short = r.hasShortfall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionCard(
          title: 'Position${r.to == null ? '' : ' to ${formatDate(r.to)}'}',
          child: Wrap(
            spacing: 32,
            runSpacing: 12,
            children: [
              LabeledValue('Collections (ex GST)', formatMoney(r.collections)),
              LabeledValue('Required (70%)', formatMoney(r.required)),
              LabeledValue('Deposited', formatMoney(r.deposited)),
              LabeledValue('Withdrawn', formatMoney(r.withdrawn)),
              LabeledValue('Balance', formatMoney(r.balance)),
            ],
          ),
        ),
        Card(
          key: const Key('rera-shortfall'),
          color: short
              ? theme.colorScheme.errorContainer
              : Colors.green.shade50,
          margin: const EdgeInsets.only(bottom: 16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(
                  short ? Icons.warning_amber_rounded : Icons.check_circle,
                  color: short
                      ? theme.colorScheme.error
                      : Colors.green.shade700,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    short
                        ? 'Shortfall of ${formatMoney(r.shortfall)}: deposit '
                              'this much into the RERA account.'
                        : 'The RERA account holds the required 70%.',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
          ),
        ),
        SectionCard(
          title: 'Registration',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _regNo,
                enabled: canEdit,
                decoration: const InputDecoration(
                  labelText: 'RERA registration no.',
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String?>(
                key: ValueKey('rera-acct-$_accountId-${banks.length}'),
                initialValue: banks.any((a) => a.id == _accountId)
                    ? _accountId
                    : null,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: 'RERA bank account',
                  helperText: r.reraAccountName,
                ),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('None'),
                  ),
                  for (final a in banks)
                    DropdownMenuItem<String?>(
                      value: a.id,
                      child: Text(
                        a.displayName,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: canEdit
                    ? (v) => setState(() => _accountId = v)
                    : null,
              ),
              if (canEdit) ...[
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: BusyButton(
                    busy: _saving,
                    onPressed: _save,
                    label: 'Save',
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
