import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/money.dart';
import '../../../widgets/layout.dart';
import '../../../widgets/states.dart';
import '../common/c_perms.dart';
import '../common/c_revisions.dart';
import '../common/c_widgets.dart';
import '../data/construction_repository.dart';

/// Creates a draft wage sheet from a site's attendance.
class WageFormScreen extends ConsumerStatefulWidget {
  const WageFormScreen({super.key, this.initialSiteId});

  final String? initialSiteId;

  @override
  ConsumerState<WageFormScreen> createState() => _WageFormScreenState();
}

class _WageFormScreenState extends ConsumerState<WageFormScreen> {
  String? _siteId;
  // Default: the last seven days, ending today.
  DateTime _from = today().subtract(const Duration(days: 6));
  DateTime _to = today();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _siteId = widget.initialSiteId;
  }

  Future<void> _create() async {
    final site = _siteId;
    if (site == null) return;
    if (_from.isAfter(_to)) {
      showInfoSnackBar(context, 'The start date is after the end date.');
      return;
    }
    setState(() => _busy = true);
    try {
      final sheet = await ref
          .read(constructionRepositoryProvider)
          .createWageSheet(
            siteId: site,
            from: apiDate(_from),
            to: apiDate(_to),
          );
      ref.bumpC(const [CKind.wages]);
      if (!mounted) return;
      showSuccess(context, '${sheet.number} prepared');
      context.go('/wage-sheets/${sheet.id}');
    } catch (error) {
      if (!mounted) return;
      showErrorSnackBar(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => CGate(
    anyOf: const [CPerm.wagesManage],
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(title: 'New wage sheet'),
        Expanded(
          child: BottomBarLayout(
            bar: Wrap(
              alignment: WrapAlignment.end,
              spacing: 12,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  style: bigOutlinedButton,
                  onPressed: _busy ? null : () => context.go('/wage-sheets'),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  style: bigButton,
                  onPressed: _busy || _siteId == null ? null : _create,
                  child: const Text('Create draft'),
                ),
              ],
            ),
            child: CPage(
              maxWidth: 680,
              children: [
                SectionCard(
                  title: 'Period',
                  child: FormRow(
                    children: [
                      SiteField(
                        value: _siteId,
                        onChanged: (value) => setState(() => _siteId = value),
                      ),
                      DateField(
                        label: 'From',
                        value: _from,
                        lastDate: today(),
                        onChanged: (value) => setState(() => _from = value),
                      ),
                      DateField(
                        label: 'To',
                        value: _to,
                        lastDate: today(),
                        onChanged: (value) => setState(() => _to = value),
                      ),
                    ],
                  ),
                ),
                const SectionCard(
                  title: 'How it works',
                  child: Text(
                    'Attendance is converted to wages using each worker’s daily '
                    'rate. Overtime is paid at twice the ordinary hourly rate. '
                    'The period cannot overlap another wage sheet for the site.',
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}
