import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/india_states.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../compliance/tax_perms.dart';
import 'settings_models.dart';
import 'settings_repository.dart';
import '../../widgets/busy.dart';

/// `/company`: business identity, contact, bank / UPI and invoice texts.
/// Editable with `company.manage`, read-only otherwise.
class CompanyProfileScreen extends ConsumerWidget {
  const CompanyProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => AsyncValueView(
    value: ref.watch(settingsCompanyProvider),
    onRetry: () => ref.invalidate(settingsCompanyProvider),
    data: (company) =>
        CompanyProfileForm(key: ValueKey(company.id), company: company),
  );
}

class CompanyProfileForm extends ConsumerStatefulWidget {
  const CompanyProfileForm({super.key, required this.company});

  final Company company;

  @override
  ConsumerState<CompanyProfileForm> createState() => _CompanyProfileFormState();
}

class _CompanyProfileFormState extends ConsumerState<CompanyProfileForm>
    with ServerFieldErrors, DirtyTracking<CompanyProfileForm> {
  final _formKey = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _c = {
    for (final MapEntry(:key, :value) in companyFormValues(
      widget.company,
    ).entries)
      key: TextEditingController(text: value),
  };
  late Company _company = widget.company;
  late bool _einvoiceEnabled = widget.company.einvoiceEnabled;
  late String _einvoiceMode = widget.company.einvoiceMode;
  late String _gstFiling = widget.company.gstFiling;
  late String? _constitution = widget.company.constitution;
  late String? _itrForm = widget.company.itrForm;
  late String? _lockedUntil = widget.company.booksLockedUntil;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  String? _gstinError(String? value) {
    final format = validateGstin(value);
    if (format != null) return format;
    final code = stateCodeFromGstin(value);
    if (code != null && code != _company.stateCode) {
      return 'GSTIN is for ${stateName(code) ?? code}; the company is '
          'registered in ${stateName(_company.stateCode) ?? _company.stateCode}';
    }
    return null;
  }

  Future<void> _save() async {
    setState(() => serverErrors = const {});
    if (!_formKey.currentState!.validate()) return;
    final changes = companyPatch(_company, {
      for (final MapEntry(:key, :value) in _c.entries) key: value.text,
      'constitution': _constitution ?? '',
      'itrForm': _itrForm ?? '',
    });
    if (_einvoiceEnabled != _company.einvoiceEnabled) {
      changes['einvoiceEnabled'] = _einvoiceEnabled;
    }
    if (_einvoiceMode != _company.einvoiceMode) {
      changes['einvoiceMode'] = _einvoiceMode;
    }
    if (_gstFiling != _company.gstFiling) changes['gstFiling'] = _gstFiling;
    if (_lockedUntil != _company.booksLockedUntil) {
      changes['booksLockedUntil'] = _lockedUntil;
    }
    if (changes.isEmpty) {
      markSaved();
      showInfoSnackBar(context, 'No changes to save');
      return;
    }
    setState(() => _saving = true);
    try {
      final saved = await ref
          .read(settingsRepositoryProvider)
          .updateCompany(changes);
      if (!mounted) return;
      setState(() {
        _company = saved;
        _einvoiceEnabled = saved.einvoiceEnabled;
        _einvoiceMode = saved.einvoiceMode;
        _gstFiling = saved.gstFiling;
        _constitution = saved.constitution;
        _itrForm = saved.itrForm;
        _lockedUntil = saved.booksLockedUntil;
      });
      showInfoSnackBar(context, 'Company profile saved');
      ref.bump(const [DataKind.company]);
      // The shell shows the company name from /me.
      try {
        await ref.read(sessionProvider.notifier).reloadMe();
      } catch (_) {
        // The profile is saved; the name refreshes on the next sign-in.
      }
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _field(
    String key,
    String label, {
    bool enabled = true,
    String? helper,
    int maxLines = 1,
    TextInputType? keyboard,
    TextCapitalization caps = TextCapitalization.none,
    String? Function(String?)? validator,
  }) => TextFormField(
    controller: _c[key],
    enabled: enabled,
    readOnly: !enabled,
    decoration: InputDecoration(
      labelText: label,
      helperText: helper,
      helperMaxLines: 2,
      alignLabelWithHint: maxLines > 1,
    ),
    minLines: maxLines > 1 ? 3 : 1,
    maxLines: maxLines,
    keyboardType: maxLines > 1 ? TextInputType.multiline : keyboard,
    textCapitalization: caps,
    forceErrorText: serverError(key),
    onChanged: (_) {
      clearServerError(key);
      if (key == 'gstin' || key == 'pan') setState(() {});
    },
    validator: validator,
  );

  @override
  Widget build(BuildContext context) => track(_buildBody(context));

  Widget _buildBody(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    final canEdit = perms.can(Perm.companyManage);
    final canLock = perms.can(TaxPerm.booksLock);
    final theme = Theme.of(context);
    final gstPan = panFromGstin(_c['gstin']!.text);
    final pan = _c['pan']!.text.trim().toUpperCase();
    final panHint = gstPan != null && pan.isNotEmpty && pan != gstPan
        ? 'Does not match the PAN in the GSTIN ($gstPan)'
        : null;
    final upper = TextCapitalization.characters;

    return Form(
      key: _formKey,
      onChanged: markDirty,
      child: FormPage(
        maxWidth: 960,
        children: [
          Text('Company profile', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text(
            'Printed on invoices and other documents.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          if (!canEdit)
            Card(
              margin: const EdgeInsets.only(bottom: 16),
              color: theme.colorScheme.secondaryContainer,
              child: const ListTile(
                leading: Icon(Icons.lock_outline),
                title: Text('Read only'),
                subtitle: Text(
                  'Ask an owner or administrator to change these details.',
                ),
              ),
            ),
          SectionCard(
            title: 'Business',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FormRow(
                  children: [
                    _field(
                      'name',
                      'Business name',
                      enabled: canEdit,
                      caps: TextCapitalization.words,
                      validator: (v) {
                        final t = v?.trim() ?? '';
                        if (t.isEmpty) return 'Business name is required';
                        return t.length < 2
                            ? 'Use at least 2 characters'
                            : null;
                      },
                    ),
                    _field(
                      'legalName',
                      'Legal name (optional)',
                      enabled: canEdit,
                      caps: TextCapitalization.words,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                FormRow(
                  children: [
                    _field(
                      'gstin',
                      'GSTIN (optional)',
                      enabled: canEdit,
                      caps: upper,
                      helper: 'State: ${stateLabel(_company.stateCode)}',
                      validator: _gstinError,
                    ),
                    _field(
                      'pan',
                      'PAN (optional)',
                      enabled: canEdit,
                      caps: upper,
                      helper: panHint,
                      validator: validatePan,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _field(
                  'address',
                  'Address',
                  enabled: canEdit,
                  maxLines: 4,
                  caps: TextCapitalization.sentences,
                ),
                const SizedBox(height: 16),
                FormRow(
                  children: [
                    _field(
                      'pincode',
                      'PIN code',
                      enabled: canEdit,
                      keyboard: TextInputType.number,
                      helper: 'Needed for e-invoices',
                      validator: validatePincode,
                    ),
                    const SizedBox.shrink(),
                  ],
                ),
              ],
            ),
          ),
          SectionCard(
            title: 'Contact',
            child: Column(
              children: [
                FormRow(
                  children: [
                    _field(
                      'phone',
                      'Phone',
                      enabled: canEdit,
                      keyboard: TextInputType.phone,
                    ),
                    _field(
                      'email',
                      'Email',
                      enabled: canEdit,
                      keyboard: TextInputType.emailAddress,
                      validator: (v) => validateEmail(v, required: false),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _field(
                  'website',
                  'Website',
                  enabled: canEdit,
                  keyboard: TextInputType.url,
                ),
              ],
            ),
          ),
          SectionCard(
            title: 'Bank & UPI',
            child: Column(
              children: [
                FormRow(
                  children: [
                    _field('bankName', 'Bank and branch', enabled: canEdit),
                    _field(
                      'bankAccountNo',
                      'Account number',
                      enabled: canEdit,
                      keyboard: TextInputType.number,
                      validator: validateBankAccount,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                FormRow(
                  children: [
                    _field(
                      'bankIfsc',
                      'IFSC',
                      enabled: canEdit,
                      caps: upper,
                      validator: validateIfsc,
                    ),
                    _field(
                      'upiId',
                      'UPI ID',
                      enabled: canEdit,
                      helper: 'Shown as a QR code on invoices',
                      validator: validateUpi,
                    ),
                  ],
                ),
              ],
            ),
          ),
          SectionCard(
            title: 'Statutory',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FormRow(
                  children: [
                    _field(
                      'tan',
                      'TAN (optional)',
                      enabled: canEdit,
                      caps: upper,
                      helper: 'Needed for TDS statements',
                      validator: validateTan,
                    ),
                    _field(
                      'msmeBankRate',
                      'RBI bank rate for MSME interest (optional)',
                      enabled: canEdit,
                      keyboard: decimalKeyboard,
                      helper: '% per year; interest is charged at 3 times this',
                      validator: (v) => optionalNumber(v, min: 0, max: 100),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text('GST return filing', style: theme.textTheme.labelLarge),
                const SizedBox(height: 8),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'monthly', label: Text('Monthly')),
                    ButtonSegment(value: 'quarterly', label: Text('Quarterly')),
                  ],
                  selected: {_gstFiling},
                  onSelectionChanged: canEdit
                      ? (s) => setState(() => _gstFiling = s.first)
                      : null,
                ),
                const SizedBox(height: 16),
                Text('Books lock', style: theme.textTheme.labelLarge),
                const SizedBox(height: 4),
                Text(
                  _lockedUntil == null
                      ? 'Not locked. Documents can be posted on any date.'
                      : 'No posting, editing or cancelling on or before '
                            '${formatDate(_lockedUntil)}.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                if (canLock)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate:
                                DateTime.tryParse(_lockedUntil ?? '') ??
                                DateTime.now(),
                            firstDate: DateTime(2017),
                            lastDate: DateTime(2100),
                            helpText: 'Lock books up to and including',
                          );
                          if (picked != null) {
                            setState(() => _lockedUntil = apiDate(picked));
                          }
                        },
                        icon: const Icon(Icons.lock_outline),
                        label: const Text('Set lock date'),
                      ),
                      if (_lockedUntil != null)
                        TextButton(
                          onPressed: () => setState(() => _lockedUntil = null),
                          child: const Text('Clear lock'),
                        ),
                    ],
                  )
                else
                  Text(
                    'Only users with the "lock books" permission can change this.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          SectionCard(
            title: 'Tax filing',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FormRow(
                  children: [
                    DropdownButtonFormField<String?>(
                      initialValue: _constitution,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Constitution (optional)',
                        helperText: 'Decides the tax rates and who needs a CA',
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: null,
                          child: Text('Not set'),
                        ),
                        for (final e in constitutionLabels.entries)
                          DropdownMenuItem(value: e.key, child: Text(e.value)),
                      ],
                      onChanged: canEdit
                          ? (v) => setState(() {
                              _constitution = v;
                              markDirty();
                            })
                          : null,
                    ),
                    DropdownButtonFormField<String?>(
                      initialValue: _itrForm,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Income-tax return form (optional)',
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: null,
                          child: Text('Not set'),
                        ),
                        for (final e in itrFormLabels.entries)
                          DropdownMenuItem(value: e.key, child: Text(e.value)),
                      ],
                      onChanged: canEdit
                          ? (v) => setState(() {
                              _itrForm = v;
                              markDirty();
                            })
                          : null,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  'Responsible person for TDS statements',
                  style: theme.textTheme.labelLarge,
                ),
                const SizedBox(height: 8),
                FormRow(
                  children: [
                    _field(
                      'rpName',
                      'Name (optional)',
                      enabled: canEdit,
                      caps: TextCapitalization.words,
                      validator: (v) =>
                          (v ?? '').trim().isEmpty ? null : validateName(v),
                    ),
                    _field(
                      'rpDesignation',
                      'Designation (optional)',
                      enabled: canEdit,
                      caps: TextCapitalization.words,
                      validator: (v) => maxLength(v, 80, 'Designation'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                FormRow(
                  children: [
                    _field(
                      'rpPan',
                      'PAN (optional)',
                      enabled: canEdit,
                      caps: upper,
                      validator: validatePan,
                    ),
                    _field(
                      'rpMobile',
                      'Mobile (optional)',
                      enabled: canEdit,
                      keyboard: TextInputType.phone,
                      validator: validateMobile,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _field(
                  'rpEmail',
                  'Email (optional)',
                  enabled: canEdit,
                  keyboard: TextInputType.emailAddress,
                  validator: (v) => validateEmail(v, required: false),
                ),
              ],
            ),
          ),
          SectionCard(
            title: 'Invoice',
            child: Column(
              children: [
                _field(
                  'invoiceTerms',
                  'Terms & conditions',
                  enabled: canEdit,
                  maxLines: 8,
                  caps: TextCapitalization.sentences,
                  helper: 'One term per line',
                ),
                const SizedBox(height: 16),
                _field(
                  'invoiceFooter',
                  'Footer',
                  enabled: canEdit,
                  caps: TextCapitalization.sentences,
                ),
              ],
            ),
          ),
          SectionCard(
            title: 'E-invoice',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Enable GST e-invoicing'),
                  subtitle: const Text(
                    'Lets users generate an IRN and e-way bill on invoices.',
                  ),
                  value: _einvoiceEnabled,
                  onChanged: canEdit
                      ? (v) => setState(() => _einvoiceEnabled = v)
                      : null,
                ),
                const SizedBox(height: 8),
                Text('Mode', style: theme.textTheme.labelLarge),
                const SizedBox(height: 8),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'manual', label: Text('Manual')),
                    ButtonSegment(value: 'sandbox', label: Text('Sandbox')),
                  ],
                  selected: {_einvoiceMode},
                  onSelectionChanged: canEdit
                      ? (s) => setState(() => _einvoiceMode = s.first)
                      : null,
                ),
                const SizedBox(height: 8),
                Text(
                  _einvoiceMode == 'sandbox'
                      ? 'Sandbox makes test IRNs for demos and training. '
                            'They are never valid for GST filing.'
                      : 'Manual: download the IRP JSON, upload it on the IRP '
                            'portal, then record the IRN it returns.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (canEdit || canLock)
            Align(
              alignment: Alignment.centerRight,
              child: BusyButton(
                busy: _saving,
                onPressed: _save,
                label: 'Save changes',
              ),
            ),
        ],
      ),
    );
  }
}
