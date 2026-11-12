import 'dart:typed_data';

import 'package:dio/dio.dart' show DioMediaType, FormData, MultipartFile;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/json.dart';
import '../../core/providers.dart';
import '../company/company_model.dart';
import 'business_models.dart';

/// `GET /business-types` (public); empty when it cannot be loaded.
final businessCatalogueProvider = FutureProvider<BusinessCatalogue>((
  ref,
) async {
  try {
    final body = await ref.watch(apiClientProvider).get('/business-types');
    return BusinessCatalogue.fromJson(asJson(body));
  } catch (_) {
    return BusinessCatalogue.empty;
  }
});

class BusinessRepository {
  BusinessRepository(this._ref);

  final Ref _ref;

  /// `POST /company/business-profile`; returns how many roles were added.
  Future<int> apply(Json body) async {
    final result = asJson(
      await _ref
          .read(apiClientProvider)
          .postJson('/company/business-profile', body: body),
    );
    return asInt(result['rolesCreated']);
  }

  /// Uploads [bytes] with `POST /files`, then sets it as the company logo.
  Future<Company> uploadLogo(Uint8List bytes, String name, String mime) async {
    final api = _ref.read(apiClientProvider);
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(
        bytes,
        filename: name,
        contentType: DioMediaType.parse(mime),
      ),
    });
    final file = asJson(await api.post('/files', body: form));
    return Company.fromJson(
      await api.patchJson('/company', body: {'logoFileId': file['id']}),
    );
  }

  Future<Company> patchCompany(Json body) async => Company.fromJson(
    await _ref.read(apiClientProvider).patchJson('/company', body: body),
  );
}

final businessRepositoryProvider = Provider<BusinessRepository>(
  BusinessRepository.new,
);
