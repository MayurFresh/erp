import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/business_profile.dart';
import '../../core/design_tokens.dart';
import '../../core/providers.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../company/company_model.dart';
import '../settings/settings_repository.dart';
import 'business_models.dart';
import 'business_repository.dart';
import 'type_picker.dart';

const List<String> _kBrandColours = [
  '#1565C0',
  '#00796B',
  '#2E7D32',
  '#EF6C00',
  '#C62828',
  '#6A1B9A',
  '#37474F',
];

Color? _parseColour(String? hex) {
  if (hex == null) return null;
  final m = RegExp(r'^#([0-9a-fA-F]{6})$').firstMatch(hex.trim());
  if (m == null) return null;
  return Color(0xFF000000 | int.parse(m.group(1)!, radix: 16));
}

/// `/business-profile`: business type, plan, modules, words, currency, logo
/// and brand colour. Modules only shape the menu; permissions are the real
/// access control.
class BusinessProfileScreen extends ConsumerWidget {
  const BusinessProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => AsyncValueView(
    value: ref.watch(settingsCompanyProvider),
    onRetry: () => ref.invalidate(settingsCompanyProvider),
    data: (company) =>
        BusinessProfileForm(key: ValueKey(company.id), company: company),
  );
}

class BusinessProfileForm extends ConsumerStatefulWidget {
  const BusinessProfileForm({super.key, required this.company});

  final Company company;

  @override
  ConsumerState<BusinessProfileForm> createState() => _FormState();
}

class _FormState extends ConsumerState<BusinessProfileForm> {
  late Company _company = widget.company;
  late Set<String> _modules = _effectiveModules(_company);
  late Map<String, TextEditingController> _words = _wordControllers(_company);
  late String _plan = _company.plan;
  late String _country = _company.country;
  late String? _brand = _company.brandColor;
  late final _currencyCtl = TextEditingController(text: _company.currency);
  Uint8List? _logo;
  bool _busy = false;

  static Set<String> _effectiveModules(Company c) =>
      (c.enabledModules ?? [for (final m in kModules) m.key]).toSet();

  static Map<String, TextEditingController> _wordControllers(Company c) => {
    for (final k in kTermDefaults.keys)
      k: TextEditingController(text: c.terms[k] ?? kTermDefaults[k]),
  };

  @override
  void initState() {
    super.initState();
    _loadLogo();
  }

  @override
  void dispose() {
    for (final c in _words.values) {
      c.dispose();
    }
    _currencyCtl.dispose();
    super.dispose();
  }

  Future<void> _loadLogo() async {
    final id = _company.logoFileId;
    if (id == null) return;
    try {
      final bytes = await ref.read(apiClientProvider).getBytes('/files/$id');
      if (mounted) setState(() => _logo = bytes);
    } catch (_) {}
  }

  void _adopt(Company company) {
    for (final c in _words.values) {
      c.dispose();
    }
    setState(() {
      _company = company;
      _modules = _effectiveModules(company);
      _words = _wordControllers(company);
      _plan = company.plan;
      _country = company.country;
      _currencyCtl.text = company.currency;
      _brand = company.brandColor;
    });
    ref.invalidate(settingsCompanyProvider);
  }

  Future<void> _run(Future<Company> Function() action, String done) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final company = await action();
      await ref.read(sessionProvider.notifier).reloadMe();
      _adopt(company);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(done)));
      }
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<Company> _apply(Map<String, Object?> body) async {
    final created = await ref.read(businessRepositoryProvider).apply({
      for (final e in body.entries)
        if (e.value != null || e.key == 'enabledModules') e.key: e.value,
    });
    if (created > 0 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$created role templates were added.')),
      );
    }
    return Company.fromJson(await ref.read(apiClientProvider).get('/company'));
  }

  Future<void> _changeType() async {
    final catalogue = await ref.read(businessCatalogueProvider.future);
    if (!mounted) return;
    final picked = await showDialog<BusinessTypeDef>(
      context: context,
      builder: (_) => _TypeDialog(
        catalogue: catalogue,
        current: _company.businessType,
        currentModules: _modules,
        country: _country,
      ),
    );
    if (picked == null) return;
    await _run(
      () => _apply({'businessType': picked.id}),
      'Business type changed to ${picked.name}.',
    );
  }

  Future<void> _save() => _run(() async {
    final terms = {
      for (final e in _words.entries)
        if (e.value.text.trim().isNotEmpty &&
            e.value.text.trim() != kTermDefaults[e.key])
          e.key: e.value.text.trim(),
    };
    var company = await _apply({
      'plan': _plan == _company.plan ? null : _plan,
      'country': _country == _company.country ? null : _country,
      'currency': _currencyCtl.text.trim().toUpperCase() == _company.currency
          ? null
          : _currencyCtl.text.trim().toUpperCase(),
      'enabledModules': _modules.toList(),
      'terms': terms,
    });
    if ((_brand ?? '') != (company.brandColor ?? '')) {
      company = await ref.read(businessRepositoryProvider).patchCompany({
        'brandColor': _brand,
      });
    }
    return company;
  }, 'Business profile saved.');

  Future<void> _pickLogo() async {
    final file = await FilePicker.pickFile(type: FileType.image);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    final name = file.name;
    final ext = name.toLowerCase().split('.').last;
    final mime = ext == 'png'
        ? 'image/png'
        : ext == 'webp'
        ? 'image/webp'
        : 'image/jpeg';
    await _run(
      () => ref.read(businessRepositoryProvider).uploadLogo(bytes, name, mime),
      'Logo updated.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final catalogue = ref.watch(businessCatalogueProvider).value;
    final type = catalogue?.byId(_company.businessType);
    final india = _country == 'IN';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeader(
          title: 'Business profile',
          subtitle: 'Your business type, plan, menu and wording',
        ),
        Expanded(
          child: FormPage(
            bottomBar: FormActionBar(
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : _save,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Save changes'),
                ),
              ],
            ),
            children: [
              SectionCard(
                title: 'Business type',
                icon: Icons.category_outlined,
                trailing: TextButton(
                  onPressed: _busy ? null : _changeType,
                  child: const Text('Change'),
                ),
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(typeIcon(type?.icon ?? 'business_center')),
                  title: Text(type?.name ?? _company.businessType),
                  subtitle: Text(type?.description ?? ''),
                ),
              ),
              SectionCard(
                title: 'Plan',
                icon: Icons.workspace_premium_outlined,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LayoutBuilder(
                      builder: (context, box) => FlowGrid(
                        columns: (box.maxWidth / 220).floor().clamp(
                          1,
                          kPlans.length,
                        ),
                        equalHeight: true,
                        children: [
                          for (final p in kPlans)
                            (
                              1,
                              _PlanCard(
                                key: Key('plan-${p.id}'),
                                plan: p,
                                selected: p.id == _plan,
                                onTap: () => setState(() => _plan = p.id),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: Space.sm),
                    Text(
                      'The plan is a setting only; nothing is billed.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              SectionCard(
                title: 'Country and currency',
                icon: Icons.public,
                child: FormRow(
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: _country,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Country'),
                      items: [
                        for (final c in kCountries)
                          DropdownMenuItem(value: c.code, child: Text(c.name)),
                      ],
                      onChanged: (v) {
                        if (v == null) return;
                        setState(() {
                          _country = v;
                          _currencyCtl.text = countryByCode(v).currency;
                        });
                      },
                    ),
                    TextField(
                      controller: _currencyCtl,
                      textCapitalization: TextCapitalization.characters,
                      maxLength: 3,
                      decoration: const InputDecoration(
                        labelText: 'Currency code',
                        helperText:
                            'Cannot change once invoices or bills exist',
                        counterText: '',
                      ),
                    ),
                  ],
                ),
              ),
              SectionCard(
                title: 'Modules',
                icon: Icons.apps,
                child: Column(
                  children: [
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'A switched-off module disappears from the menu. What '
                        'each person can do is still set by their role.',
                      ),
                    ),
                    const SizedBox(height: Space.sm),
                    FormRow(
                      maxColumns: 3,
                      minCellWidth: 300,
                      children: [
                        for (final m in kModules)
                          SwitchListTile(
                            key: Key('module-${m.key}'),
                            contentPadding: EdgeInsets.zero,
                            title: Text(m.label),
                            subtitle: Text(
                              m.indiaOnly && !india
                                  ? '${m.description} (India only)'
                                  : m.description,
                            ),
                            value:
                                _modules.contains(m.key) &&
                                (!m.indiaOnly || india),
                            onChanged: (m.indiaOnly && !india)
                                ? null
                                : (on) => setState(
                                    () => on
                                        ? _modules.add(m.key)
                                        : _modules.remove(m.key),
                                  ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              SectionCard(
                title: 'Your words',
                icon: Icons.translate,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('These replace our words in menus and titles.'),
                    const SizedBox(height: Space.md),
                    FormRow(
                      minCellWidth: 200,
                      children: [
                        for (final e in _words.entries)
                          TextField(
                            key: Key('word-${e.key}'),
                            controller: e.value,
                            maxLength: 30,
                            decoration: InputDecoration(
                              labelText: kTermDefaults[e.key],
                              counterText: '',
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              SectionCard(
                title: 'Logo and colour',
                icon: Icons.palette_outlined,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: Theme.of(
                                context,
                              ).colorScheme.outlineVariant,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: _logo == null
                              ? const Icon(Icons.image_outlined)
                              : Image.memory(_logo!, fit: BoxFit.contain),
                        ),
                        const SizedBox(width: 12),
                        OutlinedButton.icon(
                          onPressed: _busy ? null : _pickLogo,
                          icon: const Icon(Icons.upload_outlined),
                          label: const Text('Upload logo'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const Text('Brand colour'),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final hex in _kBrandColours)
                          Semantics(
                            button: true,
                            selected: _brand == hex,
                            label: 'Colour $hex',
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: () => setState(() => _brand = hex),
                              child: Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: _parseColour(hex),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    width: _brand == hex ? 3 : 1,
                                    color: _brand == hex
                                        ? Theme.of(
                                            context,
                                          ).colorScheme.onSurface
                                        : Theme.of(context).colorScheme.outline,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One plan in the picker; the whole card is the tap target.
class _PlanCard extends StatelessWidget {
  const _PlanCard({
    super.key,
    required this.plan,
    required this.selected,
    required this.onTap,
  });

  final PlanDef plan;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        borderRadius: Radii.smallAll,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(Space.md),
          decoration: BoxDecoration(
            borderRadius: Radii.smallAll,
            border: Border.all(
              width: selected ? 2 : 1,
              color: selected ? scheme.primary : scheme.outlineVariant,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(plan.name, style: theme.textTheme.titleSmall),
                  ),
                  Icon(
                    selected ? Icons.check_circle : Icons.circle_outlined,
                    size: 18,
                    color: selected ? scheme.primary : scheme.outline,
                  ),
                ],
              ),
              const SizedBox(height: Space.xs),
              for (final f in plan.features)
                Text(
                  f,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Pick a new type and see what changes before confirming.
class _TypeDialog extends StatefulWidget {
  const _TypeDialog({
    required this.catalogue,
    required this.current,
    required this.currentModules,
    required this.country,
  });

  final BusinessCatalogue catalogue;
  final String current;
  final Set<String> currentModules;
  final String country;

  @override
  State<_TypeDialog> createState() => _TypeDialogState();
}

class _TypeDialogState extends State<_TypeDialog> {
  late String _id = widget.current;

  String _labels(Iterable<String> keys) =>
      keys.map((k) => kModules.where((m) => m.key == k).first.label).join(', ');

  @override
  Widget build(BuildContext context) {
    final picked = widget.catalogue.byId(_id);
    final changed = picked != null && _id != widget.current;
    final next = picked == null
        ? <String>{}
        : picked.modules
              .where(
                (m) =>
                    widget.country == 'IN' ||
                    !kModules.firstWhere((d) => d.key == m).indiaOnly,
              )
              .toSet();
    final on = next.difference(widget.currentModules);
    final off = widget.currentModules.difference(next);
    return AlertDialog(
      title: const Text('Change business type'),
      content: SizedBox(
        width: 640,
        child: widget.catalogue.types.isEmpty
            ? const Text('The list of business types could not be loaded.')
            : SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    BusinessTypePicker(
                      catalogue: widget.catalogue,
                      selected: _id,
                      onSelected: (t) => setState(() => _id = t.id),
                    ),
                    if (changed) ...[
                      const Divider(height: 24),
                      Text(
                        'What changes',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        on.isEmpty
                            ? 'No modules are turned on.'
                            : 'Turned on: ${_labels(on)}.',
                      ),
                      Text(
                        off.isEmpty
                            ? 'No modules are turned off.'
                            : 'Turned off: ${_labels(off)}.',
                      ),
                      Text(
                        'Role templates added: '
                        '${picked.roles.map((r) => r.name).join(', ')}.',
                      ),
                      const Text(
                        'Existing roles, users and data are not changed or '
                        'removed. Your words are reset to this type.',
                      ),
                    ],
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: changed ? () => Navigator.pop(context, picked) : null,
          child: const Text('Apply'),
        ),
      ],
    );
  }
}
