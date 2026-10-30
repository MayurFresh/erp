import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/picker_field.dart';
import '../../widgets/states.dart' show showErrorSnackBar;
import '../parties/party_model.dart';
import '../parties/party_picker.dart';
import 're_models.dart';
import 're_perms.dart';
import 're_repository.dart';
import 're_widgets.dart';
import '../../widgets/busy.dart';

/// `/bookings/new`: book an available unit for a customer.
/// [unitId] pre-selects a unit (from the stacking view).
class BookingFormScreen extends ConsumerStatefulWidget {
  const BookingFormScreen({super.key, this.unitId});

  final String? unitId;

  @override
  ConsumerState<BookingFormScreen> createState() => _BookingFormScreenState();
}

class _BookingFormScreenState extends ConsumerState<BookingFormScreen>
    with ServerFieldErrors, DirtyTracking<BookingFormScreen> {
  final _formKey = GlobalKey<FormState>();
  String? _projectId;
  Unit? _unit;
  Party? _customer;
  String? _planId;
  DateTime _date = today();
  final _value = TextEditingController();
  final _gst = TextEditingController(text: '5');
  final _notes = TextEditingController();
  bool _saving = false;
  bool _preloading = false;

  @override
  void initState() {
    super.initState();
    final id = widget.unitId;
    if (id != null) {
      _preloading = true;
      ref
          .read(realEstateRepositoryProvider)
          .unit(id)
          .then((u) {
            if (!mounted) return;
            setState(() {
              _projectId = u.projectId;
              _pickUnit(u);
              _preloading = false;
            });
          })
          .catchError((Object e) {
            if (!mounted) return;
            setState(() => _preloading = false);
            showErrorSnackBar(context, e);
          });
    }
  }

  @override
  void dispose() {
    _value.dispose();
    _gst.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _pickUnit(Unit? unit) {
    _unit = unit;
    _value.text = unit == null ? '' : formatPlain(unit.listPrice);
  }

  Future<void> _save() async {
    setState(() => serverErrors = const {});
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final booking = await ref
          .read(realEstateRepositoryProvider)
          .createBooking({
            'unitId': _unit!.id,
            'customerPartyId': _customer!.id,
            'date': apiDate(_date),
            'agreementValue': parseNumber(_value.text),
            'gstPct': parseNumber(_gst.text),
            'paymentPlanId': _planId,
            'notes': trimmedOrNull(_notes.text),
          });
      ref.bumpR(const [RKind.bookings, RKind.units]);
      if (!mounted) return;
      showSuccess(context, 'Booking ${booking.number} created');
      markSaved();
      context.go('/bookings/${booking.id}');
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => track(_buildBody(context));

  Widget _buildBody(BuildContext context) {
    final theme = Theme.of(context);
    final projectId = _projectId;
    final units = projectId == null
        ? null
        : ref.watch(projectUnitsProvider(projectId));
    final plans = projectId == null
        ? null
        : ref.watch(projectPlansProvider(projectId));
    final bookable = [
      for (final u in units?.value ?? const <Unit>[])
        if (u.status.bookable || u.id == _unit?.id) u,
    ];
    final planOptions = plans?.value ?? const <PaymentPlan>[];
    if (_planId == null && planOptions.length == 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _planId == null) {
          setState(() => _planId = planOptions.single.id);
        }
      });
    }
    return CGate(
      anyOf: const [RePerm.bookingsManage],
      child: BottomBarLayout(
        maxWidth: 760,
        bar: Row(
          children: [
            Expanded(
              child: OutlinedButton(
                style: bigButton,
                onPressed: _saving ? null : () => leave('/bookings'),
                child: const Text('Cancel'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: BusyButton(
                busy: _saving,
                onPressed: _save,
                label: 'Create booking',
              ),
            ),
          ],
        ),
        child: Form(
          key: _formKey,
          onChanged: markDirty,
          child: FormPage(
            children: [
              Text('New booking', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 16),
              if (_preloading) const LinearProgressIndicator(),
              SectionCard(
                title: 'Unit',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ProjectField(
                      value: _projectId,
                      onChanged: (id) => setState(() {
                        if (id == _projectId) return;
                        _projectId = id;
                        _pickUnit(null);
                        _planId = null;
                      }),
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      key: ValueKey(
                        'unit-$projectId-${_unit?.id}-${bookable.length}',
                      ),
                      initialValue: bookable.any((u) => u.id == _unit?.id)
                          ? _unit?.id
                          : null,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: 'Unit (available or on hold)',
                        prefixIcon: const Icon(Icons.meeting_room_outlined),
                        helperText: projectId == null
                            ? 'Choose a project first'
                            : units != null &&
                                  units.hasValue &&
                                  bookable.isEmpty
                            ? 'No unit is available in this project'
                            : null,
                        errorText: serverError('unitId'),
                      ),
                      items: [
                        for (final u in bookable)
                          DropdownMenuItem(
                            value: u.id,
                            child: Text(
                              '${u.code} · ${u.unitType} · '
                              '${formatMoney(u.listPrice)}'
                              '${u.status == UnitStatus.hold ? ' (hold)' : ''}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (id) => setState(
                        () => _pickUnit(bookable.firstWhere((u) => u.id == id)),
                      ),
                      validator: (v) => v == null ? 'Choose a unit' : null,
                    ),
                  ],
                ),
              ),
              SectionCard(
                title: 'Customer and terms',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    PickerField(
                      label: 'Customer',
                      value: _customer?.name,
                      errorText: serverError('customerPartyId'),
                      validator: () =>
                          _customer == null ? 'Choose a customer' : null,
                      onTap: () async {
                        final p = await pickParty(
                          context,
                          ref,
                          type: PartyType.customer,
                        );
                        if (p != null) setState(() => _customer = p);
                      },
                    ),
                    const SizedBox(height: 16),
                    FormRow(
                      children: [
                        DateField(
                          label: 'Booking date',
                          value: _date,
                          onChanged: (d) => setState(() => _date = d),
                        ),
                        TextFormField(
                          controller: _value,
                          decoration: const InputDecoration(
                            labelText: 'Agreement value (₹)',
                          ),
                          keyboardType: decimalKeyboard,
                          inputFormatters: [decimalInput()],
                          forceErrorText: serverError('agreementValue'),
                          onChanged: (_) => clearServerError('agreementValue'),
                          validator: (v) => requiredNumber(
                            v,
                            label: 'Agreement value',
                            min: 0.01,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    FormRow(
                      children: [
                        TextFormField(
                          controller: _gst,
                          decoration: const InputDecoration(labelText: 'GST %'),
                          keyboardType: decimalKeyboard,
                          inputFormatters: [percentInput()],
                          forceErrorText: serverError('gstPct'),
                          validator: (v) => validatePercent(v, label: 'GST'),
                        ),
                        DropdownButtonFormField<String>(
                          key: ValueKey(
                            'plan-$projectId-$_planId-${planOptions.length}',
                          ),
                          initialValue: planOptions.any((p) => p.id == _planId)
                              ? _planId
                              : null,
                          isExpanded: true,
                          decoration: InputDecoration(
                            labelText: 'Payment plan',
                            helperText:
                                projectId != null &&
                                    plans != null &&
                                    plans.hasValue &&
                                    planOptions.isEmpty
                                ? 'No active plan; create one first'
                                : null,
                            errorText: serverError('paymentPlanId'),
                          ),
                          items: [
                            for (final p in planOptions)
                              DropdownMenuItem(
                                value: p.id,
                                child: Text(
                                  p.name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (id) => setState(() => _planId = id),
                          validator: (v) => v == null ? 'Choose a plan' : null,
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _notes,
                      decoration: const InputDecoration(
                        labelText: 'Notes (optional)',
                      ),
                      maxLines: 2,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
