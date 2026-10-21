import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api_client.dart';
import '../../../core/api_exception.dart';
import '../../../core/config.dart';
import '../../../core/json.dart';
import '../../../core/providers.dart';

/// The HTTP calls the construction pack needs that [ApiClient] does not
/// offer yet: `PUT /attendance`, `DELETE /boq/:id` and raw bytes for
/// `GET /files/:id`.
///
/// Everything else (including the multipart `POST /files`) goes through
/// [ApiClient]. Once `ApiClient` gains `put`, `delete` and `getBytes`, swap
/// [constructionHttpProvider] for a pass-through and delete
/// [BridgedConstructionHttp].
abstract class ConstructionHttp {
  Future<Json> putJson(String path, {Object? body});

  Future<void> delete(String path);

  /// The response body as bytes (e.g. an uploaded photo).
  Future<Uint8List> getBytes(String path);

  void close() {}
}

final constructionHttpProvider = Provider<ConstructionHttp>((ref) {
  final http = BridgedConstructionHttp(ref.watch(apiClientProvider));
  ref.onDispose(http.close);
  return http;
});

/// A small Dio client that shares the [ApiClient]'s session.
///
/// It sends the active company and an access token obtained through
/// [ApiClient.refreshTokens] (single-flight; it stores the rotated tokens in
/// the [ApiClient], so both clients keep using the same session). On
/// `401 TOKEN_EXPIRED` it refreshes once and retries, like [ApiClient].
class BridgedConstructionHttp implements ConstructionHttp {
  BridgedConstructionHttp(
    this._api, {
    HttpClientAdapter? httpClientAdapter,
    Duration timeout = AppConfig.requestTimeout,
  }) : _dio = Dio(
         BaseOptions(
           baseUrl: _api.baseUrl,
           connectTimeout: timeout,
           receiveTimeout: timeout,
           sendTimeout: kIsWeb ? null : timeout,
           contentType: Headers.jsonContentType,
           responseType: ResponseType.json,
         ),
       ) {
    if (httpClientAdapter != null) _dio.httpClientAdapter = httpClientAdapter;
  }

  final ApiClient _api;
  final Dio _dio;
  String? _accessToken;
  Future<String>? _tokenRequest;

  Future<String> _token({bool fresh = false}) {
    final current = _accessToken;
    if (!fresh && current != null) return Future.value(current);
    return _tokenRequest ??= _api
        .refreshTokens()
        .then((body) {
          final token = asString(body['accessToken']);
          _accessToken = token;
          return token;
        })
        .whenComplete(() => _tokenRequest = null);
  }

  Future<Response<dynamic>> _send(
    String method,
    String path, {
    Object? data,
    ResponseType responseType = ResponseType.json,
  }) async {
    Future<Response<dynamic>> call(String token) => _dio.request<dynamic>(
      path,
      data: data,
      options: Options(
        method: method,
        responseType: responseType,
        headers: {
          'Authorization': 'Bearer $token',
          if (_api.companyId != null) 'X-Company-Id': _api.companyId,
        },
      ),
    );

    try {
      final token = await _token();
      try {
        return await call(token);
      } on DioException catch (e) {
        if (_errorCode(e) != ApiException.tokenExpired) rethrow;
        return await call(await _token(fresh: true));
      }
    } on DioException catch (e) {
      throw ApiException.fromDio(_withJsonError(e));
    }
  }

  /// Error bodies of byte requests arrive as bytes; decode them as JSON so
  /// [ApiException.fromDio] can read `error.code`.
  static DioException _withJsonError(DioException e) {
    final response = e.response;
    final data = response?.data;
    if (response == null || data is! List<int>) return e;
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(data));
    } catch (_) {
      return e;
    }
    return e.copyWith(
      response: Response<dynamic>(
        requestOptions: response.requestOptions,
        data: decoded,
        statusCode: response.statusCode,
        statusMessage: response.statusMessage,
        headers: response.headers,
      ),
    );
  }

  static String? _errorCode(DioException e) {
    if (e.response?.statusCode != 401) return null;
    final data = _withJsonError(e).response?.data;
    return asJsonOrNull(asJsonOrNull(data)?['error'])?['code']?.toString();
  }

  @override
  Future<Json> putJson(String path, {Object? body}) async =>
      asJson((await _send('PUT', path, data: body)).data);

  @override
  Future<void> delete(String path) async {
    await _send('DELETE', path);
  }

  @override
  Future<Uint8List> getBytes(String path) async {
    final response = await _send('GET', path, responseType: ResponseType.bytes);
    final data = response.data;
    if (data is Uint8List) return data;
    if (data is List<int>) return Uint8List.fromList(data);
    return Uint8List(0);
  }

  @override
  void close() => _dio.close(force: true);
}
