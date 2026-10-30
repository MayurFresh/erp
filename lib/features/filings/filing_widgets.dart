import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_exception.dart';
import '../../core/json.dart';
import '../../core/money.dart';
import '../../core/validators.dart';
import '../../widgets/busy.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../compliance/compliance_widgets.dart';
import 'filing_models.dart';
import 'filings_repository.dart';

IconData _checkIcon(String status) => switch (status) {
  'pass' => Icons.check_circle_outline,
  'warn' => Icons.warning_amber_outlined,
  'fail' => Icons.cancel_outlined,
  _ => Icons.remove_circle_outline,
};

Color _checkColor(BuildContext context, String status) => switch (status) {
  'pass' => Colors.green.shade700,
  'warn' => Colors.orange.shade800,
  'fail' => Theme.of(context).colorScheme.error,
  _ => Theme.of(context).colorScheme.onSurfaceVariant,
};

/// Pre-filing checks with pass / warn / fail / skip icons. A row with a
/// `link` opens that screen.
class PrefileChecksList extends StatelessWidget {
  const PrefileChecksList({super.key, required this.checks});

  final List<PrefileCheck> checks;

  @override
  Widget build(BuildContext context) {
    if (checks.isEmpty) {
      return const Text('No checks for this return.');
    }
    return Column(
      children: [
        for (final c in checks)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              _checkIcon(c.status),
              color: _checkColor(context, c.status),
              semanticLabel: c.status,
            ),
            title: Text(c.count == null ? c.title : '${c.title} (${c.count})'),
            subtitle: c.detail.isEmpty ? null : Text(c.detail),
            trailing: c.link == null ? null : const Icon(Icons.chevron_right),
            onTap: c.link == null ? null : () => context.go(c.link!),
          ),
      ],
    );
  }
}

/// Small "unverified" badge for responses with a non-empty `unverified` list.
class UnverifiedBadge extends StatelessWidget {
  const UnverifiedBadge(this.items, {super.key});

  final List<String> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Tooltip(
      message: items.join('\n'),
      child: InkWell(
        onTap: () => showDialog<void>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Unverified figures'),
            content: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'These rates, caps or dates have not been checked against '
                    'the current law. Confirm them before relying on the '
                    'result.',
                  ),
                  const SizedBox(height: 8),
                  for (final i in items) Text('• $i'),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        ),
        child: Pill('Unverified', color: Colors.orange.shade800),
      ),
    );
  }
}

/// Asks for the filing details and records the return. Returns the new
/// [Filing], or null when cancelled or failed.
Future<Filing?> showMarkFiledDialog(
  BuildContext context,
  WidgetRef ref, {
  required String returnType,
  required String period,
  String arnLabel = 'ARN',
  Map<String, dynamic> extra = const {},
  FilingErrorHandler? onError,
}) => showDialog<Filing>(
  context: context,
  builder: (_) => _MarkFiledDialog(
    ref: ref,
    returnType: returnType,
    period: period,
    arnLabel: arnLabel,
    extra: extra,
    onError: onError,
  ),
);

/// Handles an API error the dialog does not know (e.g. `CASH_SHORTFALL`).
/// Return true when handled; the dialog then closes without a filing.
typedef FilingErrorHandler =
    Future<bool> Function(BuildContext context, ApiException error);

class _MarkFiledDialog extends StatefulWidget {
  const _MarkFiledDialog({
    required this.ref,
    required this.returnType,
    required this.period,
    required this.arnLabel,
    required this.extra,
    this.onError,
  });

  final FilingErrorHandler? onError;
  final WidgetRef ref;
  final String returnType;
  final String period;
  final String arnLabel;
  final Map<String, dynamic> extra;

  @override
  State<_MarkFiledDialog> createState() => _MarkFiledDialogState();
}

class _MarkFiledDialogState extends State<_MarkFiledDialog> with DirtyTracking {
  final _form = GlobalKey<FormState>();
  final _arn = TextEditingController();
  final _notes = TextEditingController();
  final _amount = TextEditingController();
  DateTime _filedOn = DateTime.now();
  String? _dateError;

  @override
  void dispose() {
    _arn.dispose();
    _notes.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final today = DateTime.now();
    final ok = _form.currentState!.validate();
    final late = DateTime(
      _filedOn.year,
      _filedOn.month,
      _filedOn.day,
    ).isAfter(DateTime(today.year, today.month, today.day));
    setState(() => _dateError = late ? 'Cannot be in the future' : null);
    if (!ok || late) return;
    final amount = parseIndianNumber(_amount.text);
    final body = <String, dynamic>{
      'returnType': widget.returnType,
      'period': widget.period,
      'filedOn': apiDate(_filedOn),
      if (_arn.text.trim().isNotEmpty) 'arn': _arn.text.trim(),
      if (_notes.text.trim().isNotEmpty) 'notes': _notes.text.trim(),
      'amountPaid': ?amount,
      ...widget.extra,
    };
    final repo = widget.ref.read(filingsRepositoryProvider);
    var acknowledged = false;
    while (true) {
      if (!mounted) return;
      try {
        final f = await runBlocking(
          context,
          () => repo.create({
            ...body,
            if (acknowledged) 'acknowledgeFailures': true,
          }),
        );
        if (f == null) return;
        widget.ref.read(filingsRevisionProvider.notifier).bump();
        markSaved();
        if (mounted) Navigator.of(context).pop(f);
        return;
      } on ApiException catch (e) {
        if (!mounted) return;
        if (e.code == 'PREFILE_FAILED' && !acknowledged) {
          final checks = asJsonList(
            e.details['checks'],
          ).map(PrefileCheck.fromJson).toList();
          final again = await showDialog<bool>(
            context: context,
            builder: (_) => AlertDialog(
              title: const Text('Checks failed'),
              content: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    PrefileChecksList(checks: checks),
                    const SizedBox(height: 8),
                    const Text('Record anyway?'),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('No, go back'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Record anyway'),
                ),
              ],
            ),
          );
          if (again != true) return;
          acknowledged = true;
          continue;
        }
        if (e.code == 'ALREADY_FILED') {
          await showDialog<void>(
            context: context,
            builder: (_) => AlertDialog(
              title: const Text('Already filed'),
              content: Text(
                'A filed record already exists for '
                '${returnTypeLabel(widget.returnType)} ${widget.period}. '
                'Cancel it in the filing register first, then record it again.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('OK'),
                ),
              ],
            ),
          );
          return;
        }
        final handler = widget.onError;
        if (handler != null && await handler(context, e)) {
          if (mounted) Navigator.of(context).pop();
          return;
        }
        if (mounted) showErrorSnackBar(context, e);
        return;
      } catch (e) {
        if (mounted) showErrorSnackBar(context, e);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) => track(
    AlertDialog(
      title: Text('Mark ${returnTypeLabel(widget.returnType)} filed'),
      content: SingleChildScrollView(
        child: Form(
          key: _form,
          onChanged: markDirty,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Period ${widget.period}'),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: DayButton(
                  label: 'Filed on',
                  value: _filedOn,
                  onChanged: (d) {
                    markDirty();
                    setState(() => _filedOn = d ?? _filedOn);
                  },
                ),
              ),
              if (_dateError != null)
                Text(
                  _dateError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _arn,
                decoration: InputDecoration(labelText: widget.arnLabel),
                validator: (v) => maxLength(v, 60, widget.arnLabel),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _amount,
                decoration: const InputDecoration(
                  labelText: 'Amount paid (optional)',
                ),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [moneyInput()],
                validator: (v) =>
                    validateMoney(v, isRequired: false, label: 'Amount paid'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _notes,
                decoration: const InputDecoration(labelText: 'Notes'),
                maxLines: 2,
                validator: validateNotes,
              ),
              const SizedBox(height: 8),
              const Text('Keep the acknowledgement PDF from the portal.'),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('Cancel'),
        ),
        BusyButton(onPressed: _submit, label: 'Mark filed', icon: Icons.check),
      ],
    ),
  );
}

/// Asks for a mandatory reason; null when dismissed.
Future<String?> askReason(BuildContext context, String title) =>
    showDialog<String>(
      context: context,
      builder: (_) => _ReasonDialog(title: title),
    );

class _ReasonDialog extends StatefulWidget {
  const _ReasonDialog({required this.title});

  final String title;

  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  final _form = GlobalKey<FormState>();
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: Form(
      key: _form,
      child: TextFormField(
        controller: _reason,
        autofocus: true,
        maxLines: 2,
        decoration: const InputDecoration(labelText: 'Reason'),
        validator: (v) =>
            requiredValue(v, 'Reason') ?? maxLength(v, 500, 'Reason'),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Keep'),
      ),
      FilledButton(
        onPressed: () {
          if (_form.currentState!.validate()) {
            Navigator.of(context).pop(_reason.text.trim());
          }
        },
        child: const Text('Confirm'),
      ),
    ],
  );
}
