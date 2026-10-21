import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 'company_model.dart';

final companyRepositoryProvider = Provider<CompanyRepository>(
  (ref) => CompanyRepository(ref.watch(apiClientProvider)),
);

/// The active company's profile.
final companyProfileProvider = FutureProvider.autoDispose<Company>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(revisionProvider(DataKind.company));
  return ref.watch(companyRepositoryProvider).get();
});

class CompanyRepository {
  CompanyRepository(this._api);

  final ApiClient _api;

  Future<Company> get() async =>
      Company.fromJson(await _api.getJson('/company'));
}
