import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_colors.dart';
import '../../core/design_tokens.dart';
import '../../core/permissions.dart';
import '../../core/whatsapp.dart';
import '../../widgets/filter_dropdown.dart';
import '../../widgets/layout.dart';
import '../../widgets/money_text.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../auth/session.dart';
import 'crm_models.dart';
import 'crm_repository.dart';
import 'crm_sheets.dart';

/// Whole rupees with Indian grouping: `₹1,84,500`.
String crmMoney(num? v) => formatMoneySigned(v, decimals: 0);

bool crmCan(WidgetRef ref, String permission) =>
    ref.watch(permissionsProvider).can(permission);

/// Shows [child] only for people who may read CRM.
class CrmGate extends ConsumerWidget {
  const CrmGate({super.key, required this.child, this.permission = Perm.crmView});

  final Widget child;
  final String permission;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider).value;
    if (session == null) return const LoadingView();
    if (!session.can(permission)) {
      return const EmptyView(
        icon: Icons.lock_outline,
        message:
            'You do not have access to this page.\nAsk an administrator for CRM access.',
      );
    }
    return child;
  }
}

String _two(int n) => n.toString().padLeft(2, '0');

String _clock(DateTime t) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final m = t.minute == 0 ? '' : ':${_two(t.minute)}';
  return '$h$m ${t.hour < 12 ? 'am' : 'pm'}';
}

/// `Due yesterday 5 pm`, `Due today 11:30 am`, `Due Mon 5 pm`, `Due 21 Nov 5 pm`.
String dueLabel(DateTime? due, {DateTime? now, String prefix = 'Due'}) {
  if (due == null) return 'No date set';
  final n = (now ?? DateTime.now());
  final d = due.toLocal();
  final today = DateTime(n.year, n.month, n.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = day.difference(today).inDays;
  final when = switch (diff) {
    0 => 'today',
    -1 => 'yesterday',
    1 => 'tomorrow',
    > 1 && < 7 => DateFormat('EEE').format(d),
    < -1 && > -7 => DateFormat('EEE').format(d),
    _ => DateFormat('d MMM').format(d),
  };
  return '$prefix $when ${_clock(d)}';
}

/// `2 h ago`, `3 days ago`.
String agoLabel(DateTime? t, {DateTime? now}) {
  if (t == null) return '';
  final d = (now ?? DateTime.now()).difference(t);
  if (d.inMinutes < 60) return '${d.inMinutes <= 0 ? 1 : d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  final days = d.inDays;
  return '$days ${days == 1 ? 'day' : 'days'} ago';
}

Widget sourceChip(String? source) => source == null || source.isEmpty
    ? const SizedBox.shrink()
    : StatusChip(source, label: crmSourceLabel(source), tone: StatusTone.info);

/// The Today / Leads / Deals / Quotations switcher shown above each list.
class CrmTabs extends ConsumerWidget {
  const CrmTabs({super.key, required this.current});

  /// One of `/crm`, `/crm/leads`, `/crm/deals`.
  final String current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tabs = <(String, String)>[
      ('Today', '/crm'),
      ('Leads', '/crm/leads'),
      ('Deals', '/crm/deals'),
      if (ref.watch(permissionsProvider).can(Perm.quotationsView))
        ('Quotations', '/quotations'),
    ];
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.colors.hairline)),
      ),
      margin: EdgeInsets.only(bottom: Space.sm),
      padding: EdgeInsets.symmetric(horizontal: pageGutter(context) - 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final (label, path) in tabs)
              InkWell(
                onTap: path == current ? null : () => context.go(path),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 48),
                  padding: const EdgeInsets.symmetric(horizontal: Space.md),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        width: 2,
                        color: path == current
                            ? theme.colorScheme.primary
                            : Colors.transparent,
                      ),
                    ),
                  ),
                  child: Text(
                    label,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: path == current
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                      fontWeight: path == current
                          ? FontWeight.w700
                          : FontWeight.w500,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// "All salespeople" / person filter, only for people with `crm.all`.
class CrmOwnerFilter extends ConsumerWidget {
  const CrmOwnerFilter({super.key, this.includeAll = true});

  final bool includeAll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!crmCan(ref, Perm.crmAll)) return const SizedBox.shrink();
    final owners = ref.watch(crmOwnersProvider).value ?? const <CrmOwner>[];
    final choice = ref.watch(crmOwnerChoiceProvider);
    return FilterDropdown<String>(
      label: 'Salesperson',
      value: owners.any((o) => o.id == choice) || choice == 'all'
          ? choice
          : null,
      anyLabel: 'Me',
      width: 220,
      options: {
        if (includeAll) 'all': 'All salespeople',
        for (final o in owners) o.id: o.name,
      },
      onChanged: (v) => ref.read(crmOwnerChoiceProvider.notifier).set(v),
    );
  }
}

Future<void> callNumber(String phone) =>
    launchUrl(Uri(scheme: 'tel', path: phone.trim())).then((_) {});

Future<void> whatsappTo(String phone, String name) =>
    openWhatsApp(whatsAppUri(phone: phone, text: 'Hello $name, ')).then((_) {});

/// Call, WhatsApp and Log outcome in one row. Call and WhatsApp are hidden
/// when there is no phone; Log outcome when [onLog] is null.
class ContactButtons extends StatelessWidget {
  const ContactButtons({
    super.key,
    this.phone,
    required this.name,
    this.onLog,
    this.logLabel = 'Log outcome',
  });

  final String? phone;
  final String name;
  final VoidCallback? onLog;
  final String logLabel;

  @override
  Widget build(BuildContext context) {
    final p = (phone ?? '').trim();
    final hasPhone = p.isNotEmpty;
    final canWa = normalizeIndianPhone(p) != null;
    const pad = EdgeInsets.symmetric(horizontal: 4);
    final size = const Size(0, Layout.touchTarget);
    Widget label(String t) => Text(t, maxLines: 1, overflow: TextOverflow.ellipsis);
    return Row(
      children: [
        if (hasPhone) ...[
          Expanded(
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(padding: pad, minimumSize: size),
              onPressed: () => callNumber(p),
              child: label('Call'),
            ),
          ),
          const SizedBox(width: Space.sm),
        ],
        if (canWa) ...[
          Expanded(
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(padding: pad, minimumSize: size),
              onPressed: () => whatsappTo(p, name),
              child: label('WhatsApp'),
            ),
          ),
          const SizedBox(width: Space.sm),
        ],
        if (onLog != null)
          Expanded(
            child: FilledButton(
              style: FilledButton.styleFrom(padding: pad, minimumSize: size),
              onPressed: onLog,
              child: label(logLabel),
            ),
          ),
      ],
    );
  }
}

/// A group heading: "Overdue" with a count on the right.
class CrmGroupHeading extends StatelessWidget {
  const CrmGroupHeading(this.label, this.count, {super.key, this.bad = false});

  final String label;
  final int count;
  final bool bad;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, Space.md, 2, Space.xs + 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: bad ? context.colors.danger : theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Text('$count', style: theme.textTheme.labelLarge),
        ],
      ),
    );
  }
}

/// A follow-up row as on the Today screen.
class FollowUpTile extends ConsumerWidget {
  const FollowUpTile({super.key, required this.activity, this.overdue = false});

  final CrmActivity activity;
  final bool overdue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final a = activity;
    final muted = theme.textTheme.bodySmall;
    final owes = owesText(a.partyBalance, crmMoney);
    final canManage = crmCan(ref, Perm.crmManage);
    final due = dueLabel(a.dueAt);
    final meta = <Widget>[
      Text(due, style: muted),
      if (a.source != null) sourceChip(a.source),
      if (owes != null)
        Text(
          owes,
          style: muted?.copyWith(color: context.colors.warning),
        ),
    ];
    final path = a.path;
    return InkWell(
      onTap: path == null ? null : () => context.push(path),
      child: Padding(
        padding: const EdgeInsets.all(Space.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    a.title,
                    style: theme.textTheme.titleMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (a.value > 0) ...[
                  const SizedBox(width: Space.sm),
                  MoneyText(
                    a.value,
                    decimals: 0,
                    style: theme.textTheme.titleMedium,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 3),
            Text(
              [crmKindLabel(a.kind), a.subject]
                  .where((s) => s.isNotEmpty)
                  .join(': '),
              style: theme.textTheme.bodyMedium,
            ),
            if ((a.notes ?? '').isNotEmpty)
              Text(a.notes!, style: muted, maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: Space.sm),
            Wrap(
              spacing: Space.sm,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: meta,
            ),
            const SizedBox(height: Space.sm + 2),
            ContactButtons(
              phone: a.phone,
              name: a.title,
              onLog: canManage
                  ? () => showLogOutcome(context, activity: a)
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// Stripe on the left edge for overdue groups.
class CrmGroupCard extends StatelessWidget {
  const CrmGroupCard({super.key, required this.children, this.bad = false});

  final List<Widget> children;
  final bool bad;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          border: bad
              ? Border(left: BorderSide(color: context.colors.danger, width: 3))
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) Divider(height: 1, color: context.colors.hairline),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// Pick one reason; returns null when cancelled.
Future<String?> showReasonPicker(
  BuildContext context, {
  required List<String> reasons,
  String title = 'Why was it lost?',
  String action = 'Mark lost',
}) {
  return showDialog<String>(
    context: context,
    builder: (context) {
      String? chosen;
      final other = TextEditingController();
      return StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  RadioGroup<String>(
                    groupValue: chosen,
                    onChanged: (v) => setState(() => chosen = v),
                    child: Column(
                      children: [
                        for (final r in reasons)
                          RadioListTile<String>(
                            value: r,
                            title: Text(r),
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                          ),
                        const RadioListTile<String>(
                          value: '__other',
                          title: Text('Other'),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ],
                    ),
                  ),
                  if (chosen == '__other')
                    TextField(
                      controller: other,
                      autofocus: true,
                      maxLength: 60,
                      decoration: const InputDecoration(labelText: 'Reason'),
                      onChanged: (_) => setState(() {}),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed:
                  chosen == null ||
                      (chosen == '__other' && other.text.trim().isEmpty)
                  ? null
                  : () => Navigator.of(context).pop(
                      chosen == '__other' ? other.text.trim() : chosen,
                    ),
              child: Text(action),
            ),
          ],
        ),
      );
    },
  );
}

/// Runs [call], reports failure as a snackbar, and bumps the lists on success.
Future<bool> crmGuarded(
  BuildContext context,
  WidgetRef ref,
  Future<void> Function() call, {
  String? done,
}) async {
  try {
    await call();
  } catch (e) {
    if (context.mounted) showErrorSnackBar(context, e);
    return false;
  }
  ref.bumpCrm();
  if (done != null && context.mounted) {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(done), behavior: SnackBarBehavior.floating),
      );
  }
  return true;
}

/// Label and value in a 2 x 2 grid.
class SummaryGrid extends StatelessWidget {
  const SummaryGrid({super.key, required this.cells});

  /// (label, value, bad)
  final List<(String, String, bool)> cells;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget cell((String, String, bool) c) => Padding(
      padding: const EdgeInsets.all(Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(c.$1, style: theme.textTheme.bodySmall),
          const SizedBox(height: 2),
          Text(
            c.$2,
            style: theme.textTheme.titleMedium?.copyWith(
              color: c.$3 ? context.colors.danger : null,
            ),
          ),
        ],
      ),
    );
    final line = Divider(height: 1, color: context.colors.hairline);
    final vline = VerticalDivider(width: 1, color: context.colors.hairline);
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [Expanded(child: cell(cells[0])), vline, Expanded(child: cell(cells[1]))],
            ),
          ),
          line,
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [Expanded(child: cell(cells[2])), vline, Expanded(child: cell(cells[3]))],
            ),
          ),
        ],
      ),
    );
  }
}

/// The four account facts from `/crm/parties/:id/overview`.
SummaryGrid accountSummary(PartyOverview o) => SummaryGrid(
  cells: [
    (
      'Owes now',
      o.owes <= 0
          ? 'Nothing'
          : '${crmMoney(o.owes)}${o.overdue > 0 && (o.oldestOverdueDays ?? 0) > 0 ? ' · ${o.oldestOverdueDays} days late' : ''}',
      o.overdue > 0,
    ),
    (
      'Credit limit',
      o.creditLimit == null || o.creditLimit == 0
          ? 'Not set'
          : crmMoney(o.creditLimit),
      false,
    ),
    ('Bought in 12 months', crmMoney(o.sales12m), false),
    (
      'Usually pays in',
      o.avgDaysToPay == null
          ? 'No paid bills yet'
          : '${o.avgDaysToPay!.round()} days',
      false,
    ),
  ],
);
