import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'api_exception.dart';
import 'config.dart';
import 'json.dart';
import 'token_store.dart';

/// HTTP client for the Progen API.
///
/// Adds `Authorization` and `X-Company-Id`, refreshes the access token once
/// on `401 TOKEN_EXPIRED` (concurrent refreshes share one call) and maps
/// error bodies to [ApiException].
class ApiClient {
  ApiClient({
    required String baseUrl,
    required TokenStore tokenStore,
    Duration timeout = AppConfig.requestTimeout,
    HttpClientAdapter? httpClientAdapter,
  }) : _store = tokenStore,
       _dio = Dio(_options(baseUrl, timeout)),
       _refreshDio = Dio(_options(baseUrl, timeout)) {
    if (httpClientAdapter != null) {
      _dio.httpClientAdapter = httpClientAdapter;
      _refreshDio.httpClientAdapter = httpClientAdapter;
    }
    _dio.interceptors.add(
      InterceptorsWrapper(onRequest: _onRequest, onError: _onError),
    );
  }

  static BaseOptions _options(String baseUrl, Duration timeout) => BaseOptions(
    baseUrl: baseUrl,
    connectTimeout: timeout,
    receiveTimeout: timeout,
    // On web a send timeout installs an upload listener and logs warnings.
    sendTimeout: kIsWeb ? null : timeout,
    contentType: Headers.jsonContentType,
    responseType: ResponseType.json,
  );

  static const _publicPaths = {'/auth/signup', '/auth/login', '/auth/refresh'};
  static const _retriedKey = 'progen.retried';
  static const _sentTokenKey = 'progen.sentToken';

  final TokenStore _store;
  final Dio _dio;
  final Dio _refreshDio;
  final _sessionExpired = StreamController<void>.broadcast();

  String? _accessToken;
  String? _refreshToken;
  Future<Json>? _refreshing;

  /// Sent as `X-Company-Id` on company-scoped endpoints.
  String? companyId;

  String get baseUrl => _dio.options.baseUrl;
  String? get refreshToken => _refreshToken;

  /// Emits when the session can no longer be used (refresh failed or a
  /// non-expiry 401). Tokens are already cleared at that point.
  Stream<void> get sessionExpired => _sessionExpired.stream;

  /// Loads the persisted refresh token; returns whether one exists.
  Future<bool> restore() async {
    _refreshToken = await _store.readRefreshToken();
    companyId = await _store.readCompanyId();
    return _refreshToken != null;
  }

  Future<void> setTokens(AuthTokens tokens) async {
    _accessToken = tokens.accessToken;
    _refreshToken = tokens.refreshToken;
    await _store.writeRefreshToken(tokens.refreshToken);
  }

  Future<void> setCompany(String? id) async {
    companyId = id;
    await _store.writeCompanyId(id);
  }

  /// Forgets tokens and the active company locally.
  Future<void> clearSession() async {
    _accessToken = null;
    _refreshToken = null;
    companyId = null;
    await _store.clear();
  }

  /// Rotates tokens via `POST /auth/refresh` and returns the AuthResult body.
  /// Concurrent callers share the same request.
  Future<Json> refreshTokens() {
    final inFlight = _refreshing;
    if (inFlight != null) return inFlight;
    final future = _doRefresh();
    _refreshing = future;
    future.whenComplete(() {
      if (identical(_refreshing, future)) _refreshing = null;
    }).ignore();
    return future;
  }

  Future<Json> _doRefresh() async {
    final token = _refreshToken;
    if (token == null) {
      throw const ApiException(
        401,
        ApiException.unauthorized,
        'Not signed in.',
      );
    }
    try {
      final response = await _refreshDio.post<dynamic>(
        '/auth/refresh',
        data: {'refreshToken': token},
      );
      final body = asJson(response.data);
      await setTokens(AuthTokens.fromJson(body));
      return body;
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  Future<void> _expire() async {
    await clearSession();
    _sessionExpired.add(null);
  }

  void _onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final path = options.path;
    final token = _accessToken;
    if (!_publicPaths.contains(path) && token != null) {
      options.headers['Authorization'] = 'Bearer $token';
      options.extra[_sentTokenKey] = token;
    }
    final company = companyId;
    if (company != null && !path.startsWith('/auth/') && path != '/me') {
      options.headers['X-Company-Id'] = company;
    }
    handler.next(options);
  }

  Future<void> _onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final options = err.requestOptions;
    final response = err.response;
    if (response?.statusCode != 401 || _publicPaths.contains(options.path)) {
      handler.next(err);
      return;
    }
    final code = asJsonOrNull(asJsonOrNull(response!.data)?['error'])?['code'];
    if (code != ApiException.tokenExpired ||
        options.extra[_retriedKey] == true) {
      if (_refreshToken != null || _accessToken != null) await _expire();
      handler.next(err);
      return;
    }

    try {
      // Skip the refresh if another request already rotated the token.
      if (_accessToken == null ||
          options.extra[_sentTokenKey] == _accessToken) {
        await refreshTokens();
      }
    } on ApiException catch (e) {
      // Only an answer from the server means the session is gone; after a
      // network failure the tokens are kept so the user can retry.
      if (!e.isNetworkError) await _expire();
      handler.next(err);
      return;
    }

    options.extra[_retriedKey] = true;
    try {
      handler.resolve(await _dio.fetch<dynamic>(options));
    } on DioException catch (e) {
      handler.next(e);
    }
  }

  Future<dynamic> _send(Future<Response<dynamic>> Function() call) async {
    try {
      final response = await call();
      return response.data;
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  static Map<String, dynamic>? _query(Map<String, dynamic>? query) {
    if (query == null) return null;
    final result = <String, dynamic>{};
    query.forEach((key, value) {
      if (value == null || (value is String && value.isEmpty)) return;
      result[key] = value is bool ? value.toString() : value;
    });
    return result;
  }

  Future<dynamic> get(String path, {Map<String, dynamic>? query}) =>
      _send(() => _dio.get<dynamic>(path, queryParameters: _query(query)));

  /// A missing [body] is sent as `{}`: the server rejects an empty body
  /// with a JSON content type (e.g. `POST /transfers/:id/receive`).
  Future<dynamic> post(String path, {Object? body}) => _send(
    () => _dio.post<dynamic>(path, data: body ?? const <String, dynamic>{}),
  );

  Future<dynamic> patch(String path, {Object? body}) =>
      _send(() => _dio.patch<dynamic>(path, data: body));

  Future<Json> getJson(String path, {Map<String, dynamic>? query}) async =>
      asJson(await get(path, query: query));

  Future<Json> postJson(String path, {Object? body}) async =>
      asJson(await post(path, body: body));

  Future<Json> patchJson(String path, {Object? body}) async =>
      asJson(await patch(path, body: body));

  /// Fetches a list endpoint (`{data, total}`).
  Future<Paged<T>> getPage<T>(
    String path,
    T Function(Json) fromJson, {
    Map<String, dynamic>? query,
  }) async => Paged.fromJson(await getJson(path, query: query), fromJson);

  void close() {
    _dio.close(force: true);
    _refreshDio.close(force: true);
    _sessionExpired.close();
  }
}
