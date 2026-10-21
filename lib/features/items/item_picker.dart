import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../widgets/search_picker.dart';
import 'item_model.dart';
import 'items_repository.dart';

/// Searches active items; [stockOnly] hides items that do not track stock.
Future<Item?> pickItem(
  BuildContext context,
  WidgetRef ref, {
  bool stockOnly = false,
}) {
  final repo = ref.read(itemsRepositoryProvider);
  return showSearchPicker<Item>(
    context: context,
    title: 'Choose an item',
    hintText: 'Search name, SKU or HSN',
    emptyMessage: 'No active items match.',
    search: (q) async {
      final page = await repo.list(q: q, activeOnly: true, limit: 50);
      return stockOnly
          ? page.data.where((i) => i.trackStock).toList()
          : page.data;
    },
    titleBuilder: (context, item) => Text(item.name),
    subtitleBuilder: (context, item) => Text(
      [
        if (item.sku != null) item.sku!,
        if (item.hsnCode != null) 'HSN ${item.hsnCode}',
        item.unit,
        'GST ${formatPercent(item.gstRate)}',
      ].join(' · '),
    ),
    trailingBuilder: (context, item) => Text(formatMoney(item.salePrice)),
  );
}
