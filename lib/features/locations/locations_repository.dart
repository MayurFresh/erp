import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 'location_model.dart';

final locationsRepositoryProvider = Provider<LocationsRepository>(
  (ref) => LocationsRepository(ref.watch(apiClientProvider)),
);

/// All locations in the user's scope (for dropdowns and name lookups).
final locationsLookupProvider = FutureProvider.autoDispose<List<Location>>((
  ref,
) async {
  ref.watch(activeCompanyIdProvider);
  ref.watch(revisionProvider(DataKind.locations));
  final page = await ref.watch(locationsRepositoryProvider).list(limit: 200);
  return page.data;
});

class LocationsRepository {
  LocationsRepository(this._api);

  final ApiClient _api;

  Future<Paged<Location>> list({String? q, int offset = 0, int limit = 50}) =>
      _api.getPage(
        '/locations',
        Location.fromJson,
        query: {'q': q, 'offset': offset, 'limit': limit},
      );

  /// [body]: `{ type, name, code?, stateCode?, address?, parentId? }`.
  Future<Location> create(Json body) async {
    final createBody = withoutNulls(Map.of(body)..remove('isActive'));
    return Location.fromJson(
      await _api.postJson('/locations', body: createBody),
    );
  }

  /// Sends only the fields that changed from [original].
  Future<Location> update(Location original, Json body) async {
    final changes = changedFields(original.toInputJson(), body);
    if (changes.isEmpty) return original;
    return Location.fromJson(
      await _api.patchJson('/locations/${original.id}', body: changes),
    );
  }
}
