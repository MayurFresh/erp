import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/json.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import 'platform_models.dart';
import 'platform_repository.dart';
import 'security_screen.dart' show formatStamp;
import '../../core/app_colors.dart';

final gspSettingsProvider = FutureProvider.autoDispose<GspSettings>((ref) {
  ref.watch(activeCompanyIdProvider);
  return ref.watch(platformRepositoryProvider).gsp();
});

final gspSubmissionsProvider = FutureProvider.autoDispose
    .family<List<GspSubmission>, String?>((ref, period) {
      ref.watch(activeCompanyIdProvider);
      return ref.watch(platformRepositoryProvider).submissions(period: period);
    });

/// `/gsp-settings`: e-invoice mode, provider and credentials. Secrets are
/// write-only: the server never returns them, only which are saved.
class GspSettingsScreen extends ConsumerWidget {
  const GspSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => FormPage(
    maxWidth: 720,
    children: [
      const PageHeader(title: 'GST provider'),
      AsyncValueView<GspSettings>(
        value: ref.watch(gspSettingsProvider),
        onRetry: () => ref.invalidate(gspSettingsProvider),
        data: (s) =>
            _GspForm(key: ValueKey(s.mode + (s.provider ?? '')), initial: s),
      ),
    ],
  );
}

class _GspForm extends ConsumerStatefulWidget {
  const _GspForm({super.key, required this.initial});

  final GspSettings initial;

  @override
  ConsumerState<_GspForm> createState() => _GspFormState();
}

class _GspFormState extends ConsumerState<_GspForm> {
  late String _mode = widget.initial.mode;
  late String? _provider = widget.initial.provider;
  final Map<String, TextEditingController> _ctl = {};
  final Set<String> _clear = {};
  bool _saving = false;
  bool _testing = false;
  String? _testResult;
  bool? _testOk;

  TextEditingController _c(String key) => _ctl.putIfAbsent(
    key,
    () => TextEditingController(text: widget.initial.credentials[key] ?? ''),
  );

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  GspProviderInfo? get _info {
    for (final p in widget.initial.providers) {
      if (p.id == _provider) return p;
    }
    return null;
  }

  Future<void> _save() async {
    if (_saving) return;
    final info = _info;
    final creds = <String, String?>{};
    if (_mode == 'gsp' && info != null) {
      for (final f in info.fields) {
        final text = _c(f.key).text.trim();
        if (_clear.contains(f.key)) {
          creds[f.key] = null;
        } else if (f.secret) {
          if (text.isNotEmpty) creds[f.key] = text; // blank keeps the saved one
        } else {
          creds[f.key] = text.isEmpty ? null : text;
        }
      }
    }
    setState(() => _saving = true);
    try {
      await ref.read(platformRepositoryProvider).saveGsp({
        'mode': _mode,
        if (_mode == 'gsp') 'provider': _provider,
        if (creds.isNotEmpty) 'credentials': creds,
      });
      ref.invalidate(gspSettingsProvider);
      if (mounted) showInfoSnackBar(context, 'Provider settings saved');
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    try {
      final r = await ref.read(platformRepositoryProvider).testGsp();
      if (mounted) {
        setState(() {
          _testOk = asBool(r['ok']);
          _testResult = asString(r['message']);
        });
      }
    } catch (e) {
      setState(() {
        _testOk = false;
        _testResult = errorMessage(e);
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.initial;
    final info = _info;
    final live = s.providers;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionCard(
          title: 'E-invoice and e-way bill mode',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<String>(
                key: const Key('gsp.mode'),
                showSelectedIcon: false,
                segments: [
                  const ButtonSegment(value: 'manual', label: Text('Manual')),
                  const ButtonSegment(value: 'sandbox', label: Text('Sandbox')),
                  ButtonSegment(
                    value: 'gsp',
                    label: const Text('Provider'),
                    enabled: live.isNotEmpty,
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: (v) => setState(() => _mode = v.first),
              ),
              const SizedBox(height: 8),
              Text(switch (_mode) {
                'manual' => 'You copy the IRN from the government portal.',
                'sandbox' =>
                  'A local fake generates test IRNs. Not valid for filing.',
                _ => 'Documents are sent through your GST provider.',
              }),
              if (live.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('No provider is installed on this server yet.'),
                ),
              if (_mode == 'gsp' && live.isNotEmpty) ...[
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  key: const Key('gsp.provider'),
                  initialValue: _provider,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Provider'),
                  items: [
                    for (final p in live)
                      DropdownMenuItem(value: p.id, child: Text(p.name)),
                  ],
                  onChanged: (v) => setState(() => _provider = v),
                ),
                if (info != null) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    children: [for (final c in info.capabilities) Pill(c)],
                  ),
                  for (final f in info.fields) ...[
                    const SizedBox(height: 16),
                    _credField(f, s),
                  ],
                ],
              ],
            ],
          ),
        ),
        SectionCard(
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              BusyButton(
                key: const Key('gsp.save'),
                busy: _saving,
                onPressed: _save,
                label: 'Save',
                icon: Icons.save_outlined,
              ),
              OutlinedButton.icon(
                key: const Key('gsp.test'),
                onPressed: _testing ? null : _test,
                icon: _testing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_tethering),
                label: const Text('Test connection'),
              ),
              if (_testResult != null)
                Text(
                  _testResult!,
                  key: const Key('gsp.testResult'),
                  style: TextStyle(
                    color: _testOk == true
                        ? context.colors.success
                        : Theme.of(context).colorScheme.error,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _credField(
    ({String key, String label, bool secret}) f,
    GspSettings s,
  ) {
    final saved = s.savedSecrets.contains(f.key) && !_clear.contains(f.key);
    return TextField(
      key: Key('gsp.cred.${f.key}'),
      controller: _c(f.key),
      obscureText: f.secret,
      enableSuggestions: !f.secret,
      autocorrect: false,
      decoration: InputDecoration(
        labelText: f.label,
        helperText: f.secret
            ? (saved ? 'Saved. Leave blank to keep it.' : 'Not saved yet')
            : null,
        suffixIcon: f.secret && saved
            ? IconButton(
                tooltip: 'Clear saved value',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => setState(() => _clear.add(f.key)),
              )
            : null,
      ),
    );
  }
}

/// Submissions card for the GSTR-1 tab.
class GspSubmissionsCard extends ConsumerWidget {
  const GspSubmissionsCard({super.key, this.period});

  final String? period;

  @override
  Widget build(BuildContext context, WidgetRef ref) => SectionCard(
    title: 'Provider submissions',
    child: AsyncValueView<List<GspSubmission>>(
      value: ref.watch(gspSubmissionsProvider(period)),
      onRetry: () => ref.invalidate(gspSubmissionsProvider(period)),
      data: (rows) => rows.isEmpty
          ? const Text('Nothing uploaded through a provider yet.')
          : Column(
              children: [
                for (final r in rows)
                  ListTile(
                    key: Key('submission.${r.id}'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text('${r.period}  ${r.reference}'),
                    subtitle: Text(
                      '${r.provider}  ${formatStamp(r.createdAt)}',
                    ),
                    trailing: Pill(r.status),
                  ),
              ],
            ),
    ),
  );
}

/// "Upload via provider" for GSTR-1. Handles the prefile-failure
/// acknowledgement and the "provider cannot do this" answer.
class Gstr1UploadButton extends ConsumerStatefulWidget {
  const Gstr1UploadButton({super.key, required this.period});

  final String period;

  @override
  ConsumerState<Gstr1UploadButton> createState() => _Gstr1UploadButtonState();
}

class _Gstr1UploadButtonState extends ConsumerState<Gstr1UploadButton> {
  bool _busy = false;

  Future<void> _upload({bool force = false}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final r = await ref
          .read(platformRepositoryProvider)
          .uploadGstr1(widget.period, force: force);
      ref.invalidate(gspSubmissionsProvider);
      if (mounted) {
        showInfoSnackBar(context, 'Uploaded. Reference ${r.reference}');
      }
    } catch (e) {
      final api = apiError(e);
      if (api?.code == 'PREFILE_FAILED' && !force && mounted) {
        final ok = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Checks failed'),
            content: Text('${api!.message}\n\nUpload anyway?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const Key('gstr1.uploadAnyway'),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Upload anyway'),
              ),
            ],
          ),
        );
        if (ok == true) {
          await _upload(force: true);
          return;
        }
      } else if (mounted) {
        showErrorSnackBar(
          context,
          api?.statusCode == 501
              ? 'The selected provider cannot upload GSTR-1. Use Export GSTN JSON.'
              : e,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    key: const Key('gstr1.upload'),
    onPressed: _busy ? null : () => _upload(),
    icon: _busy
        ? const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.cloud_upload_outlined),
    label: const Text('Upload via provider'),
  );
}
