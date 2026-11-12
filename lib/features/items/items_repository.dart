import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import '../controls/custom_fields_section.dart' show customPatch;
import 'item_model.dart';

final itemsRepositoryProvider = Provider<ItemsRepository>(
  (ref) => ItemsRepository(ref.watch(apiClientProvider)),
);

final itemProvider = FutureProvider.autoDispose.family<Item, String>((ref, id) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(revisionProvider(DataKind.items));
  return ref.watch(itemsRepositoryProvider).get(id);
});

class ItemsRepository {
  ItemsRepository(this._api);

  final ApiClient _api;

  Future<Paged<Item>> list({
    String? q,
    bool activeOnly = false,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/items',
    Item.fromJson,
    query: {
      'q': q,
      if (activeOnly) 'activeOnly': true,
      'offset': offset,
      'limit': limit,
    },
  );

  Future<Item> get(String id) async =>
      Item.fromJson(await _api.getJson('/items/$id'));

  Future<Item> create(ItemInput input, {required bool includeCost}) async {
    final body = withoutNulls(input.toJson(includeCost: includeCost));
    if (input.custom.isNotEmpty) body['custom'] = input.custom;
    return Item.fromJson(await _api.postJson('/items', body: body));
  }

  /// Sends only the fields that changed from [original].
  Future<Item> update(
    Item original,
    ItemInput input, {
    required bool includeCost,
  }) async {
    final before = ItemInput.fromItem(
      original,
    ).toJson(includeCost: includeCost, includeActive: true);
    final after = input.toJson(includeCost: includeCost, includeActive: true);
    final body = changedFields(before, after);
    if (jsonEncode(original.custom) != jsonEncode(input.custom)) {
      body['custom'] = customPatch(original.custom, input.custom);
    }
    if (body.isEmpty) return original;
    final stamp = original.updatedAt;
    return Item.fromJson(
      await _api.patchJson(
        '/items/${original.id}',
        body: {
          ...body,
          if (stamp != null)
            'expectedUpdatedAt': stamp.toUtc().toIso8601String(),
        },
      ),
    );
  }
}
