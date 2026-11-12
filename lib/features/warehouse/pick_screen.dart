import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_tokens.dart';
import '../../core/money.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../construction/common/c_widgets.dart' show CGate;
import '../../core/api_exception.dart';
import '../parties/party_model.dart';
import '../parties/party_picker.dart';
import '../items/item_picker.dart';
import '../manufacturing/bom_screen.dart' show PickerFieldBox;
import '../manufacturing/mfg_widgets.dart' show MfgCard, MfgKv;
import 'wh_models.dart';
import 'wh_perms.dart';
import 'wh_repository.dart';
import 'wh_widgets.dart';

String _line(WhCandidate c) =>
    '${c.binCode ?? 'No bin'}${c.batchNo != null ? ' · batch ${c.batchNo}' : ''}'
    '${c.expiryDate != null ? ' · exp ${formatDate(c.expiryDate)}' : ''}';

/// `/warehouse/pick`: pick list with the first-expiry-first-out suggestion.
class PickScreen extends ConsumerStatefulWidget {
  const PickScreen({super.key});

  @override
  ConsumerState<PickScreen> createState() => _PickScreenState();
}

class _PickScreenState extends ConsumerState<PickScreen> {
  final _form = GlobalKey<FormState>();
  final _qty = TextEditingController();
  final _serial = TextEditingController();
  String? _itemId, _itemName, _unit;
  WhFefo? _fefo;
  bool _busy = false;
  double? _askedQty;
  String? _pickRef, _invoiceNo;

  Future<void> _suggest(String loc) async {
    if (_itemId == null) return mfgToast(context, 'Choose an item.');
    if (!_form.currentState!.validate()) return;
    final qty = parseNumber(_qty.text.trim())!;
    setState(() => _busy = true);
    try {
      final f = await ref
          .read(whRepositoryProvider)
          .fefo(loc, _itemId!, qty: qty);
      if (mounted) {
        setState(() {
          _fefo = f;
          _askedQty = qty;
        });
      }
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirm(String loc) async {
    final serials = _serial.text
        .split(RegExp(r'[\s,;]+'))
        .where((s) => s.isNotEmpty)
        .toList();
    setState(() => _busy = true);
    String? ref0;
    final ok = await whGuarded(
      context,
      () async => ref0 = await ref.read(whRepositoryProvider).pick({
        'locationId': loc,
        'lines': [
          {
            'itemId': _itemId,
            'qty': _askedQty,
            if (serials.isNotEmpty) 'serialNos': serials,
          },
        ],
      }),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      ref.bumpWh();
      mfgToast(context, 'Pick recorded.');
      setState(() {
        _fefo = null;
        _pickRef = ref0;
        _invoiceNo = null;
      });
    }
  }

  Future<void> _makeInvoice() async {
    final refId = _pickRef;
    if (refId == null) return;
    final party = await pickParty(context, ref, type: PartyType.customer);
    if (party == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final no = await ref.read(whRepositoryProvider).billPick(refId, party.id);
      if (mounted) setState(() => _invoiceNo = no);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.code == 'PICK_ALREADY_BILLED') {
        setState(() => _invoiceNo = 'already billed');
        mfgToast(context, 'This pick list is already billed.');
      } else {
        showErrorSnackBar(context, e);
      }
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(whLocationIdProvider);
    final canPick = ref.whCan(WhPerm.pick);
    final f = _fefo;
    return CGate(
      anyOf: const [WhPerm.view],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(
            title: 'Pick list',
            subtitle: 'Oldest expiry goes first',
          ),
          Expanded(
            child: loc == null
                ? const EmptyView(
                    icon: Icons.warehouse_outlined,
                    message: 'Add a location first.',
                  )
                : ListView(
                    padding: EdgeInsets.fromLTRB(
                      pageGutter(context),
                      0,
                      pageGutter(context),
                      Space.xxl,
                    ),
                    children: [
                      Align(
                        alignment: Alignment.topLeft,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 560),
                          child: Form(
                            key: _form,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                const WhLocationBar(),
                                const SizedBox(height: Space.md),
                                PickerFieldBox(
                                  label: 'Item',
                                  value: _itemName,
                                  onTap: () async {
                                    final item = await pickItem(
                                      context,
                                      ref,
                                      stockOnly: true,
                                    );
                                    if (item != null) {
                                      setState(() {
                                        _itemId = item.id;
                                        _itemName = item.name;
                                        _unit = item.unit;
                                        _fefo = null;
                                      });
                                    }
                                  },
                                ),
                                const SizedBox(height: Space.md),
                                mfgNumberField(
                                  controller: _qty,
                                  label: 'Quantity needed',
                                  suffix: _unit,
                                ),
                                const SizedBox(height: Space.md),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: FilledButton(
                                    onPressed: _busy
                                        ? null
                                        : () => _suggest(loc),
                                    child: const Text('Suggest pick'),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: Space.lg),
                      if (_pickRef != null && canPick) _billCard(),
                      if (f != null) ..._result(f, loc, canPick),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _billCard() => MfgCard(
    title: 'Pick recorded',
    child: Align(
      alignment: Alignment.centerLeft,
      child: _invoiceNo == null
          ? FilledButton(
              onPressed: _busy ? null : _makeInvoice,
              child: const Text('Make invoice'),
            )
          : Text(
              _invoiceNo == 'already billed'
                  ? 'Already billed'
                  : 'Invoice $_invoiceNo',
              style: Theme.of(context).textTheme.titleSmall,
            ),
    ),
  );

  List<Widget> _result(WhFefo f, String loc, bool canPick) {
    final theme = Theme.of(context);
    return [
      if (f.enough == false)
        MfgCard(
          title: 'Not enough stock',
          child: Text(
            f.candidates.isEmpty
                ? 'Nothing is available in bins here.'
                : 'The bins here cannot cover ${formatQty(_askedQty)}. Put away more stock or ask for less.',
          ),
        ),
      if (f.plan != null)
        MfgCard(
          title: f.fefo ? 'Take in this order' : 'Take from',
          child: Column(
            children: [
              for (final p in f.plan!)
                MfgKv(
                  _line(p),
                  '${formatQty(p.qty)} ${_unit ?? ''}'.trim(),
                  bold: true,
                ),
              if (canPick) ...[
                const SizedBox(height: Space.sm),
                TextFormField(
                  controller: _serial,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Serial numbers (serial items only)',
                  ),
                ),
                const SizedBox(height: Space.sm),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton(
                    onPressed: _busy ? null : () => _confirm(loc),
                    child: const Text('Confirm pick'),
                  ),
                ),
              ],
            ],
          ),
        ),
      MfgCard(
        title: 'Available in pick order',
        child: f.candidates.isEmpty
            ? Text('None.', style: theme.textTheme.bodyMedium)
            : Column(
                children: [
                  for (final c in f.candidates)
                    MfgKv(
                      _line(c),
                      '${formatQty(c.qty)} ${_unit ?? ''}'.trim(),
                    ),
                ],
              ),
      ),
    ];
  }
}
