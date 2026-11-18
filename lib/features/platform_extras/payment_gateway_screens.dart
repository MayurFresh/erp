import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_tokens.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../core/whatsapp.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../accounts/accounts_repository.dart';
import '../receivables/receivables_widgets.dart';
import 'extras_repository.dart';

/// `/settings/payment-gateway`: provider keys, webhook and the bank account.
class PaymentGatewayScreen extends ConsumerStatefulWidget {
  const PaymentGatewayScreen({super.key});

  @override
  ConsumerState<PaymentGatewayScreen> createState() =>
      _PaymentGatewayScreenState();
}

const _providerNames = {'razorpay': 'Razorpay', 'cashfree': 'Cashfree'};

class _PaymentGatewayScreenState extends ConsumerState<PaymentGatewayScreen> {
  String _provider = 'razorpay';

  @override
  Widget build(BuildContext context) => RGate(
    anyOf: const [Perm.integrationsManage],
    child: AsyncValueView<List<GatewaySettings>>(
      value: ref.watch(gatewaySettingsProvider),
      onRetry: () => ref.invalidate(gatewaySettingsProvider),
      data: (all) {
        final g = all.firstWhere(
          (x) => x.provider == _provider,
          orElse: () => GatewaySettings(provider: _provider, isActive: false),
        );
        return _GatewayForm(
          key: ValueKey(
            '$_provider${g.isActive}${g.accountId}${g.fields.map((f) => f.isSet)}',
          ),
          initial: g,
          provider: _provider,
          onProvider: (p) => setState(() => _provider = p),
        );
      },
    ),
  );
}

class _GatewayForm extends ConsumerStatefulWidget {
  const _GatewayForm({
    super.key,
    required this.initial,
    required this.provider,
    required this.onProvider,
  });
  final GatewaySettings initial;
  final String provider;
  final ValueChanged<String> onProvider;

  @override
  ConsumerState<_GatewayForm> createState() => _GatewayFormState();
}

const _defaultFields = {
  'razorpay': [
    GatewayField('keyId', 'Key id', false, false),
    GatewayField('keySecret', 'Key secret', true, false),
    GatewayField('webhookSecret', 'Webhook secret', true, false),
  ],
  'cashfree': [
    GatewayField('keyId', 'App id', false, false),
    GatewayField('keySecret', 'Secret key', true, false),
  ],
};

class _GatewayFormState extends ConsumerState<_GatewayForm> {
  final _ctrl = <String, TextEditingController>{};
  late String? _account = widget.initial.accountId;
  late bool _active = widget.initial.isActive;
  bool _saving = false;

  List<GatewayField> get _fields => widget.initial.fields.isNotEmpty
      ? widget.initial.fields
      : _defaultFields[widget.provider]!;

  TextEditingController _c(String k) =>
      _ctrl.putIfAbsent(k, TextEditingController.new);

  @override
  void dispose() {
    for (final c in _ctrl.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(extrasRepositoryProvider).saveGateway({
        for (final f in _fields)
          if (_c(f.key).text.trim().isNotEmpty) f.key: _c(f.key).text.trim(),
        'accountId': _account,
        'isActive': _active,
      }, provider: widget.provider);
      ref.read(extrasRevisionProvider.notifier).bump();
      if (mounted) showInfoSnackBar(context, 'Payment settings saved');
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final banks = ref.watch(cashBankAccountsProvider).value ?? const [];
    final bankAccounts = banks.where((a) => a.subtype == 'bank').toList();
    bool isSet(String k) =>
        widget.initial.fields.any((f) => f.key == k && f.isSet);
    return FormPage(
      maxWidth: 900,
      bottomBar: FormActionBar(
        children: [
          TextButton(
            onPressed: () => context.go('/payment-links'),
            child: const Text('See payment links'),
          ),
          BusyButton(
            busy: _saving,
            onPressed: _save,
            label: 'Save settings',
            icon: Icons.check,
          ),
        ],
      ),
      children: [
        Text('Online payments', style: theme.textTheme.headlineSmall),
        Wrap(
          spacing: Space.sm,
          children: [
            for (final e in _providerNames.entries)
              ChoiceChip(
                key: ValueKey('gw-provider-${e.key}'),
                label: Text(e.value),
                selected: widget.provider == e.key,
                onSelected: (_) => widget.onProvider(e.key),
              ),
          ],
        ),
        SectionCard(
          title: 'Keys',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.provider == 'cashfree'
                    ? 'Create an app in your Cashfree dashboard. App ids that start with TEST use the sandbox and move no real money. Cashfree signs webhooks with the secret key. Saved secrets are never shown again; leave a field empty to keep it.'
                    : 'Create keys in your Razorpay dashboard. Test keys start with rzp_test_ and move no real money. Saved secrets are never shown again; leave a field empty to keep it.',
                style: theme.textTheme.bodySmall,
              ),
              if (widget.initial.mode != null) ...[
                const SizedBox(height: Space.sm),
                StatusChip(
                  widget.initial.mode!,
                  label: widget.initial.mode == 'test'
                      ? 'Test mode'
                      : 'Live mode',
                ),
              ],
              const SizedBox(height: Space.md),
              FormRow(
                children: [
                  for (final f in _fields)
                    TextField(
                      key: ValueKey(switch (f.key) {
                        'keyId' => 'gw-key-id',
                        'keySecret' => 'gw-key-secret',
                        'webhookSecret' => 'gw-webhook-secret',
                        _ => 'gw-${f.key}',
                      }),
                      controller: _c(f.key),
                      obscureText: f.secret,
                      decoration: InputDecoration(
                        labelText: f.label,
                        helperText: isSet(f.key) ? 'Saved' : null,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        SectionCard(
          title: 'Webhook',
          child: widget.initial.webhookUrl == null
              ? const Text('Save the keys once to get the webhook address.')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.provider == 'cashfree'
                          ? 'In Cashfree, add this address as a webhook for payment link events. Cashfree signs it with your secret key.'
                          : 'In Razorpay, add this webhook address, choose the Payment Link events, and use the same secret as above.',
                    ),
                    const SizedBox(height: Space.sm),
                    SelectableText(widget.initial.webhookUrl!),
                    TextButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: widget.initial.webhookUrl!),
                        );
                        if (context.mounted) {
                          showInfoSnackBar(context, 'Address copied');
                        }
                      },
                      icon: const Icon(Icons.copy_outlined),
                      label: const Text('Copy address'),
                    ),
                  ],
                ),
        ),
        SectionCard(
          title: 'Where the money goes',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<String?>(
                isExpanded: true,
                key: const ValueKey('gw-account'),
                initialValue: bankAccounts.any((a) => a.id == _account)
                    ? _account
                    : null,
                decoration: const InputDecoration(
                  labelText: 'Bank account for receipts',
                ),
                items: [
                  const DropdownMenuItem(
                    value: null,
                    child: Text('Not chosen'),
                  ),
                  for (final a in bankAccounts)
                    DropdownMenuItem(value: a.id, child: Text(a.name)),
                ],
                onChanged: (v) => setState(() => _account = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Offer "Collect online" on invoices'),
                value: _active,
                onChanged: (v) => setState(() => _active = v),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// `/payment-links`: every link and its state, for checking against the bank.
class PaymentLinksScreen extends ConsumerStatefulWidget {
  const PaymentLinksScreen({super.key});

  @override
  ConsumerState<PaymentLinksScreen> createState() => _PaymentLinksScreenState();
}

class _PaymentLinksScreenState extends ConsumerState<PaymentLinksScreen> {
  String? _status;

  @override
  Widget build(BuildContext context) => RGate(
    anyOf: const [Perm.paymentsView],
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.md, Space.md, Space.md, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: Space.sm,
              children: [
                for (final s in const [
                  null,
                  'created',
                  'paid',
                  'expired',
                  'cancelled',
                ])
                  ChoiceChip(
                    label: Text(switch (s) {
                      null => 'All',
                      'created' => 'Waiting',
                      'paid' => 'Paid',
                      'expired' => 'Expired',
                      _ => 'Cancelled',
                    }),
                    selected: _status == s,
                    onSelected: (_) => setState(() => _status = s),
                  ),
              ],
            ),
          ),
        ),
        Expanded(
          child: AsyncValueView<List<PaymentLink>>(
            value: ref.watch(paymentLinksProvider(_status)),
            onRetry: () => ref.invalidate(paymentLinksProvider(_status)),
            data: (list) => list.isEmpty
                ? const EmptyView(
                    icon: Icons.link_off,
                    message:
                        'No payment links yet.\nOpen an invoice and choose Collect online.',
                  )
                : ListView(
                    padding: const EdgeInsets.all(Space.md),
                    children: [
                      for (final l in list)
                        Card(
                          child: ListTile(
                            key: ValueKey('link-${l.id}'),
                            minVerticalPadding: 12,
                            title: Text('${l.invoiceNumber}, ${l.partyName}'),
                            subtitle: Text(
                              '${formatMoney(l.amount)}'
                              '${l.paidAt != null
                                  ? ', paid ${formatDateTime(l.paidAt)}'
                                  : l.expiresAt != null
                                  ? ', expires ${formatDate(l.expiresAt)}'
                                  : ''}'
                              '${l.fee > 0 ? ', fee ${formatMoney(l.fee)}' : ''}',
                            ),
                            trailing: StatusChip(
                              l.status,
                              label: l.statusLabel,
                            ),
                            onTap: () => context.go('/invoices/${l.invoiceId}'),
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

/// Creates a link for [invoiceId] and shows it with share actions.
Future<void> collectOnline(
  BuildContext context,
  WidgetRef ref,
  String invoiceId,
) async {
  final repo = ref.read(extrasRepositoryProvider);
  PaymentLink link;
  try {
    final ready = [
      for (final g in await repo.gateways())
        if (g.isActive) g.provider,
    ];
    String? provider;
    if (ready.length > 1) {
      if (!context.mounted) return;
      provider = await showDialog<String>(
        context: context,
        builder: (c) => SimpleDialog(
          title: const Text('Collect with'),
          children: [
            for (final p in ready)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(c, p),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(_providerNames[p] ?? p),
                ),
              ),
          ],
        ),
      );
      if (provider == null) return;
    }
    link = await repo.createLink(invoiceId, provider: provider);
  } catch (e) {
    if (context.mounted) showErrorSnackBar(context, e);
    return;
  }
  ref.read(extrasRevisionProvider.notifier).bump();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Payment link ready'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${formatMoney(link.amount)} for ${link.invoiceNumber}'),
          const SizedBox(height: Space.sm),
          SelectableText(link.shortUrl ?? ''),
          if (link.expiresAt != null) ...[
            const SizedBox(height: Space.sm),
            Text(
              'Works until ${formatDate(link.expiresAt)}',
              style: Theme.of(c).textTheme.bodySmall,
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: link.shortUrl ?? ''));
            if (c.mounted) showInfoSnackBar(c, 'Link copied');
          },
          child: const Text('Copy'),
        ),
        if (link.whatsappUrl != null)
          TextButton(
            onPressed: () => openWhatsApp(Uri.parse(link.whatsappUrl!)),
            child: const Text('Send on WhatsApp'),
          ),
        FilledButton(
          onPressed: () => Navigator.pop(c),
          child: const Text('Done'),
        ),
      ],
    ),
  );
}
