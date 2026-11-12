import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/json.dart';
import '../../core/providers.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import 'platform_models.dart';
import 'platform_repository.dart';
import 'security_screen.dart' show formatStamp;

final ssoProvidersProvider = FutureProvider.autoDispose<List<SsoProvider>>(
  (ref) => ref.watch(platformRepositoryProvider).ssoProviders(),
);

final require2faProvider = FutureProvider.autoDispose<bool>((ref) {
  ref.watch(activeCompanyIdProvider);
  return ref.watch(platformRepositoryProvider).companyRequires2fa();
});

final _rolesProvider = FutureProvider.autoDispose<List<_RoleOpt>>((ref) async {
  ref.watch(activeCompanyIdProvider);
  final json = await ref.watch(apiClientProvider).getJson('/roles');
  return asJsonList(json['data']).map(_RoleOpt.fromJson).toList();
});

class _RoleOpt {
  const _RoleOpt({required this.id, required this.name});

  factory _RoleOpt.fromJson(Json j) =>
      _RoleOpt(id: asString(j['id']), name: asString(j['name']));

  final String id;
  final String name;
}

/// "Require two-step verification" switch for the company (`security.manage`).
class Require2faTile extends ConsumerWidget {
  const Require2faTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final can = ref.watch(permissionsProvider).can('security.manage');
    if (!can) return const SizedBox.shrink();
    return ref
        .watch(require2faProvider)
        .when(
          loading: () => const LinearProgressIndicator(),
          error: (e, _) => ErrorView(
            error: e,
            onRetry: () => ref.invalidate(require2faProvider),
          ),
          data: (on) => SwitchListTile(
            key: const Key('company.require2fa'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Require two-step verification'),
            subtitle: const Text(
              'Everyone in this company must set up 2FA before they can work. '
              'Single sign-on users are exempt.',
            ),
            value: on,
            onChanged: (v) async {
              try {
                await ref.read(platformRepositoryProvider).setRequire2fa(v);
                ref.invalidate(require2faProvider);
              } catch (e) {
                if (context.mounted) showErrorSnackBar(context, e);
              }
            },
          ),
        );
  }
}

/// `/security`: company security switch and the SSO providers.
class SecurityAdminScreen extends ConsumerWidget {
  const SecurityAdminScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final providers = ref.watch(ssoProvidersProvider);
    final repo = ref.read(platformRepositoryProvider);
    return FormPage(
      maxWidth: 900,
      children: [
        PageHeader(
          title: 'Security',
          actions: [
            FilledButton.icon(
              key: const Key('sso.add'),
              onPressed: () => context.push('/security/new'),
              icon: const Icon(Icons.add),
              label: const Text('Add SSO provider'),
            ),
          ],
        ),
        const SectionCard(title: 'Sign-in policy', child: Require2faTile()),
        SectionCard(
          title: 'Single sign-on providers',
          child: AsyncValueView<List<SsoProvider>>(
            value: providers,
            onRetry: () => ref.invalidate(ssoProvidersProvider),
            data: (list) => list.isEmpty
                ? const Text('No providers yet.')
                : Column(
                    children: [
                      for (final p in list)
                        ListTile(
                          key: Key('sso.${p.id}'),
                          contentPadding: EdgeInsets.zero,
                          title: Text(p.name),
                          subtitle: Text(
                            '${p.issuer}\n${p.emailDomains.join(', ')}'
                            '${p.enforce ? '  Enforced' : ''}'
                            '${p.isActive ? '' : '  Inactive'}',
                          ),
                          isThreeLine: true,
                          onTap: () => context.push('/security/${p.id}'),
                          trailing: PopupMenuButton<String>(
                            key: Key('sso.menu.${p.id}'),
                            onSelected: (v) async {
                              try {
                                if (v == 'edit') {
                                  context.push('/security/${p.id}');
                                } else if (v == 'test') {
                                  final r = await repo.testSsoProvider(p.id);
                                  if (context.mounted) {
                                    showInfoSnackBar(
                                      context,
                                      asBool(r['ok'])
                                          ? 'Connection works'
                                          : asString(r['message'], 'Failed'),
                                    );
                                  }
                                } else {
                                  await repo.deleteSsoProvider(p.id);
                                  ref.invalidate(ssoProvidersProvider);
                                }
                              } catch (e) {
                                if (context.mounted) {
                                  showErrorSnackBar(context, e);
                                }
                              }
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: 'edit', child: Text('Edit')),
                              PopupMenuItem(
                                value: 'test',
                                child: Text('Test connection'),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text('Deactivate'),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

/// `/security/new` and `/security/:id`.
class SsoProviderEditScreen extends ConsumerStatefulWidget {
  const SsoProviderEditScreen({super.key, this.providerId});

  final String? providerId;

  @override
  ConsumerState<SsoProviderEditScreen> createState() =>
      _SsoProviderEditScreenState();
}

class _SsoProviderEditScreenState extends ConsumerState<SsoProviderEditScreen>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _issuer = TextEditingController();
  final _clientId = TextEditingController();
  final _secret = TextEditingController();
  final _domains = TextEditingController();
  bool _enforce = false;
  bool _autoProvision = false;
  String? _companyId;
  String? _roleId;
  bool _hasSecret = false;
  bool _loaded = false;
  bool _saving = false;

  bool get _isNew => widget.providerId == null;

  @override
  void dispose() {
    for (final c in [_name, _issuer, _clientId, _secret, _domains]) {
      c.dispose();
    }
    super.dispose();
  }

  void _fill(SsoProvider p) {
    _name.text = p.name;
    _issuer.text = p.issuer;
    _clientId.text = p.clientId;
    _domains.text = p.emailDomains.join(', ');
    _enforce = p.enforce;
    _autoProvision = p.autoProvision;
    _companyId = p.defaultCompanyId;
    _roleId = p.defaultRoleId;
    _hasSecret = p.hasClientSecret;
    _loaded = true;
  }

  Future<void> _save() async {
    setState(() => serverErrors = const {});
    if (!validateAndReveal(_formKey)) return;
    final domains = _domains.text
        .split(RegExp(r'[,\s]+'))
        .where((d) => d.isNotEmpty)
        .map((d) => d.toLowerCase())
        .toList();
    setState(() => _saving = true);
    try {
      await ref
          .read(platformRepositoryProvider)
          .saveSsoProvider(widget.providerId, {
            'name': _name.text.trim(),
            'issuer': _issuer.text.trim(),
            'clientId': _clientId.text.trim(),
            if (_secret.text.isNotEmpty) 'clientSecret': _secret.text,
            'emailDomains': domains,
            'enforce': _enforce,
            'autoProvision': _autoProvision,
            'defaultCompanyId': ?_companyId,
            'defaultRoleId': ?_roleId,
          });
      ref.invalidate(ssoProvidersProvider);
      if (mounted) {
        showInfoSnackBar(context, 'Provider saved');
        context.go('/security');
      }
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isNew && !_loaded) {
      final list = ref.watch(ssoProvidersProvider);
      return AsyncValueView<List<SsoProvider>>(
        value: list,
        onRetry: () => ref.invalidate(ssoProvidersProvider),
        data: (all) {
          final found = all.where((p) => p.id == widget.providerId);
          if (found.isEmpty) {
            return const EmptyView(message: 'Provider not found.');
          }
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_loaded) setState(() => _fill(found.first));
          });
          return const LoadingView();
        },
      );
    }
    final session = ref.watch(sessionProvider).value;
    final roles = ref.watch(_rolesProvider).value ?? const <_RoleOpt>[];
    return Form(
      key: _formKey,
      child: FormPage(
        maxWidth: 640,
        children: [
          Text(
            _isNew ? 'Add SSO provider' : 'Edit SSO provider',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 16),
          SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  key: const Key('sso.name'),
                  controller: _name,
                  decoration: const InputDecoration(
                    labelText: 'Name (shown on the sign-in button)',
                  ),
                  validator: (v) => requiredField(v, 'Name'),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  key: const Key('sso.issuer'),
                  controller: _issuer,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: 'Issuer URL',
                    helperText: 'e.g. https://accounts.google.com',
                    errorText: serverError('issuer'),
                  ),
                  validator: (v) => (v ?? '').trim().startsWith('https://')
                      ? null
                      : 'Must start with https://',
                ),
                const SizedBox(height: 16),
                FormRow(
                  children: [
                    TextFormField(
                      key: const Key('sso.clientId'),
                      controller: _clientId,
                      decoration: const InputDecoration(labelText: 'Client ID'),
                      validator: (v) => requiredField(v, 'Client ID'),
                    ),
                    TextFormField(
                      key: const Key('sso.secret'),
                      controller: _secret,
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText: 'Client secret',
                        helperText: _hasSecret
                            ? 'Saved. Leave blank to keep it.'
                            : null,
                      ),
                      validator: (v) => _isNew && (v ?? '').isEmpty
                          ? 'Client secret is required'
                          : null,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextFormField(
                  key: const Key('sso.domains'),
                  controller: _domains,
                  decoration: InputDecoration(
                    labelText: 'Email domains',
                    helperText: 'Comma separated, e.g. acme.in, acme.com',
                    errorText: serverError('emailDomains'),
                  ),
                  validator: (v) => (v ?? '').trim().isEmpty
                      ? 'Add at least one domain'
                      : null,
                ),
                SwitchListTile(
                  key: const Key('sso.enforce'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Enforce SSO'),
                  subtitle: const Text(
                    'Password sign-in is blocked for these domains. Users '
                    'with security access keep a password as a fallback.',
                  ),
                  value: _enforce,
                  onChanged: (v) => setState(() => _enforce = v),
                ),
                SwitchListTile(
                  key: const Key('sso.autoProvision'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Create users on first sign-in'),
                  value: _autoProvision,
                  onChanged: (v) => setState(() => _autoProvision = v),
                ),
                if (_autoProvision) ...[
                  DropdownButtonFormField<String>(
                    key: const Key('sso.defaultCompany'),
                    initialValue: _companyId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Default company',
                    ),
                    items: [
                      for (final c in session?.companies ?? const [])
                        DropdownMenuItem(value: c.id, child: Text(c.name)),
                    ],
                    onChanged: (v) => setState(() => _companyId = v),
                    validator: (v) => v == null ? 'Choose a company' : null,
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    key: const Key('sso.defaultRole'),
                    initialValue: roles.any((r) => r.id == _roleId)
                        ? _roleId
                        : null,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Default role',
                    ),
                    items: [
                      for (final r in roles)
                        DropdownMenuItem(value: r.id, child: Text(r.name)),
                    ],
                    onChanged: (v) => setState(() => _roleId = v),
                    validator: (v) => v == null ? 'Choose a role' : null,
                  ),
                ],
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: BusyButton(
                    key: const Key('sso.save'),
                    busy: _saving,
                    onPressed: _save,
                    label: 'Save',
                    icon: Icons.save_outlined,
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

// Background jobs ---------------------------------------------------------

final _jobStatusProvider = NotifierProvider<_StatusFilter, String?>(
  _StatusFilter.new,
);

class _StatusFilter extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? v) => state = v;
}

final jobsProvider = FutureProvider.autoDispose<Paged<Job>>((ref) {
  ref.watch(activeCompanyIdProvider);
  return ref
      .watch(platformRepositoryProvider)
      .jobs(status: ref.watch(_jobStatusProvider));
});

Color? _statusColor(BuildContext context, String status) {
  final scheme = Theme.of(context).colorScheme;
  return switch (status) {
    'failed' => scheme.errorContainer,
    'done' || 'sent' => scheme.primaryContainer,
    _ => null,
  };
}

String _sentence(String s) =>
    s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

class _StatusChips extends StatelessWidget {
  const _StatusChips({
    required this.options,
    required this.value,
    required this.onChanged,
  });

  final List<String> options;
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      ChoiceChip(
        label: const Text('All'),
        selected: value == null,
        onSelected: (_) => onChanged(null),
      ),
      for (final o in options)
        ChoiceChip(
          key: Key('filter.$o'),
          label: Text(_sentence(o)),
          selected: value == o,
          onSelected: (_) => onChanged(o),
        ),
    ],
  );
}

/// `/jobs`: background jobs with retry for failed ones.
class JobsScreen extends ConsumerWidget {
  const JobsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobs = ref.watch(jobsProvider);
    return Column(
      children: [
        PageHeader(
          title: 'Background jobs',
          actions: [
            IconButton(
              tooltip: 'Refresh',
              onPressed: () => ref.invalidate(jobsProvider),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: _StatusChips(
              options: const ['queued', 'running', 'done', 'failed'],
              value: ref.watch(_jobStatusProvider),
              onChanged: ref.read(_jobStatusProvider.notifier).set,
            ),
          ),
        ),
        Expanded(
          child: AsyncValueView<Paged<Job>>(
            value: jobs,
            onRetry: () => ref.invalidate(jobsProvider),
            data: (page) => page.data.isEmpty
                ? const EmptyView(message: 'No jobs.')
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: page.data.length,
                    itemBuilder: (_, i) {
                      final j = page.data[i];
                      return Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxWidth: double.infinity,
                          ),
                          child: Card(
                            child: ListTile(
                              key: Key('job.${j.id}'),
                              title: Wrap(
                                spacing: 8,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Text(j.kind),
                                  Pill(
                                    _sentence(j.status),
                                    color: _statusColor(context, j.status),
                                  ),
                                ],
                              ),
                              subtitle: Text(
                                'Attempt ${j.attempts}/${j.maxAttempts}  '
                                '${formatStamp(j.createdAt)}'
                                '${j.createdBy == null ? '' : '  by ${j.createdBy}'}'
                                '${j.error == null ? '' : '\n${j.error}'}',
                              ),
                              isThreeLine: j.error != null,
                              trailing: j.status == 'failed'
                                  ? TextButton(
                                      key: Key('job.retry.${j.id}'),
                                      onPressed: () async {
                                        try {
                                          await ref
                                              .read(platformRepositoryProvider)
                                              .retryJob(j.id);
                                          ref.invalidate(jobsProvider);
                                        } catch (e) {
                                          if (context.mounted) {
                                            showErrorSnackBar(context, e);
                                          }
                                        }
                                      },
                                      child: const Text('Retry'),
                                    )
                                  : null,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

// Delivery log ------------------------------------------------------------

final _outboxStatusProvider = NotifierProvider<_StatusFilter, String?>(
  _StatusFilter.new,
);

final outboxProvider = FutureProvider.autoDispose<Paged<OutboxRow>>((ref) {
  ref.watch(activeCompanyIdProvider);
  return ref
      .watch(platformRepositoryProvider)
      .outbox(status: ref.watch(_outboxStatusProvider));
});

/// `/outbox`: emails and WhatsApp messages the system sent.
class OutboxScreen extends ConsumerWidget {
  const OutboxScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(outboxProvider);
    return Column(
      children: [
        PageHeader(
          title: 'Delivery log',
          subtitle: 'Emails and WhatsApp messages sent by Progen',
          actions: [
            IconButton(
              tooltip: 'Refresh',
              onPressed: () => ref.invalidate(outboxProvider),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: _StatusChips(
              options: const ['pending', 'sent', 'failed', 'skipped'],
              value: ref.watch(_outboxStatusProvider),
              onChanged: ref.read(_outboxStatusProvider.notifier).set,
            ),
          ),
        ),
        Expanded(
          child: AsyncValueView<Paged<OutboxRow>>(
            value: rows,
            onRetry: () => ref.invalidate(outboxProvider),
            data: (page) => page.data.isEmpty
                ? const EmptyView(message: 'Nothing sent yet.')
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: page.data.length,
                    itemBuilder: (_, i) {
                      final r = page.data[i];
                      return Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxWidth: double.infinity,
                          ),
                          child: Card(
                            child: ListTile(
                              key: Key('outbox.${r.id}'),
                              leading: Icon(
                                r.channel == 'email'
                                    ? Icons.email_outlined
                                    : Icons.chat_outlined,
                              ),
                              title: Text(
                                r.subject ?? r.template,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '${r.to}  ${formatStamp(r.createdAt)}'
                                '${r.error == null ? '' : '\n${r.error}'}',
                              ),
                              isThreeLine: r.error != null,
                              trailing: Pill(
                                _sentence(r.status),
                                color: _statusColor(context, r.status),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}
