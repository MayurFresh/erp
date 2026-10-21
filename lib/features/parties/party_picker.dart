import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/india_states.dart';
import '../../widgets/search_picker.dart';
import 'parties_repository.dart';
import 'party_model.dart';

/// Searches customers ([PartyType.customer]) or vendors
/// ([PartyType.vendor]); parties of type `both` appear in either.
Future<Party?> pickParty(
  BuildContext context,
  WidgetRef ref, {
  required PartyType type,
}) {
  final repo = ref.read(partiesRepositoryProvider);
  final vendor = type == PartyType.vendor;
  return showSearchPicker<Party>(
    context: context,
    title: vendor ? 'Choose a vendor' : 'Choose a customer',
    hintText: 'Search name, GSTIN or phone',
    emptyMessage: vendor ? 'No vendors match.' : 'No customers match.',
    search: (q) async {
      final page = await repo.list(q: q, type: type, limit: 50);
      return page.data
          .where((p) => vendor ? p.isVendor : p.isCustomer)
          .toList();
    },
    titleBuilder: (context, p) => Text(p.name),
    subtitleBuilder: (context, p) => Text(
      [
        if (p.gstin != null) p.gstin!,
        if (p.stateCode != null) stateLabel(p.stateCode),
      ].join(' · '),
    ),
  );
}

/// One line under a party field: GSTIN and state.
String partySummary(Party party) => [
  if (party.gstin != null) 'GSTIN ${party.gstin}',
  if (party.stateCode != null) 'State ${stateLabel(party.stateCode)}',
  if (party.creditDays > 0) '${party.creditDays} days credit',
].join(' · ');
