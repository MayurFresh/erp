import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../widgets/layout.dart';
import '../../widgets/search_picker.dart';
import 'accounting_models.dart';
import 'accounting_repository.dart';

/// Searches active accounts by code or name (the chart is small, so the
/// search runs on the device).
Future<Account?> pickAccount(BuildContext context, WidgetRef ref) {
  Future<List<Account>>? chart;
  return showSearchPicker<Account>(
    context: context,
    title: 'Choose an account',
    hintText: 'Search code or name',
    emptyMessage: 'No accounts match.',
    search: (q) async {
      chart ??= ref
          .read(accountingRepositoryProvider)
          .allAccounts(activeOnly: true);
      final all = await chart!;
      return all.where((a) => a.isActive && accountMatches(a, q)).toList();
    },
    titleBuilder: (context, a) => Text(a.name),
    subtitleBuilder: (context, a) => Text(
      '${a.code} · ${accountTypeLabel(a.type)}'
      '${a.subtype == 'other' ? '' : ' · ${accountSubtypeLabel(a.subtype)}'}',
    ),
    trailingBuilder: (context, a) => a.isSystem
        ? Pill('System', color: Theme.of(context).colorScheme.tertiary)
        : const SizedBox.shrink(),
  );
}
