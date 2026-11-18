import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'api_exception.dart';
import 'config.dart';
import 'dirty_registry.dart';
import 'json.dart';
import 'token_store.dart';

/// HTTP client for the OneMatrix API.
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
  static const _retriedKey = 'onematrix.retried';
  static const _sentTokenKey = 'onematrix.sentToken';

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

  /// Why the session ended (e.g. `SESSION_REVOKED`); shown once on sign-in.
  String? sessionNotice;

  Future<void> _expire([String? notice]) async {
    sessionNotice = notice;
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
      if (_refreshToken != null || _accessToken != null) {
        await _expire(
          code == ApiException.sessionRevoked
              ? ApiException.friendlyMessage(code as String, 401, '')
              : null,
        );
      }
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
      if (!e.isNetworkError) {
        await _expire(e.code == ApiException.sessionRevoked ? e.message : null);
      }
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
      final data = response.data;
      if (response.requestOptions.method != 'GET') {
        DirtyRegistry.instance.noteSaved();
      }
      if (response.statusCode == 202 &&
          data is Map &&
          data['approvalRequest'] is Map) {
        throw ApprovalPendingException.fromBody(asJson(data));
      }
      return data;
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
  ///
  /// Every call sends an `Idempotency-Key` (except `/auth/*`). The same key
  /// is reused by internal retries (token refresh) because it lives in the
  /// request options. Pass [idempotencyKey] to keep one key across several
  /// attempts of the same user submit.
  Future<dynamic> post(String path, {Object? body, String? idempotencyKey}) {
    final isAuth = path.startsWith('/auth/');
    final signature = _signature('POST', path, body);
    return _dedupe(signature, () async {
      // A submit that failed without an answer (offline, timeout, 5xx) is
      // retried with the key it first used, so the server cannot post twice.
      final key =
          idempotencyKey ?? _retryKeys[signature] ?? newIdempotencyKey();
      try {
        final result = await _send(
          () => _dio.post<dynamic>(
            path,
            data: body ?? const <String, dynamic>{},
            options: isAuth ? null : Options(headers: {'Idempotency-Key': key}),
          ),
        );
        _retryKeys.remove(signature);
        return result;
      } on ApiException catch (e) {
        if (e.statusCode == 0 || e.statusCode >= 500) {
          if (_retryKeys.length > 50) _retryKeys.remove(_retryKeys.keys.first);
          _retryKeys[signature] = key;
        } else {
          _retryKeys.remove(signature);
        }
        rethrow;
      }
    });
  }

  final _inFlight = <String, Future<dynamic>>{};
  final _retryKeys = <String, String>{};

  static String _signature(String method, String path, Object? body) {
    String encoded;
    try {
      encoded = jsonEncode(body);
    } catch (_) {
      encoded = '${body.hashCode}';
    }
    return '$method $path $encoded';
  }

  /// A second identical mutation (same method, path and body) while one is
  /// running shares the running request instead of sending another.
  Future<dynamic> _dedupe(String signature, Future<dynamic> Function() run) {
    final running = _inFlight[signature];
    if (running != null) return running;
    final future = run();
    _inFlight[signature] = future;
    future.whenComplete(() {
      if (identical(_inFlight[signature], future)) _inFlight.remove(signature);
    }).ignore();
    return future;
  }

  static final _random = Random.secure();
  static const _keyChars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

  /// 32 random characters from `[A-Za-z0-9]`.
  static String newIdempotencyKey() => String.fromCharCodes(
    List.generate(
      32,
      (_) => _keyChars.codeUnitAt(_random.nextInt(_keyChars.length)),
    ),
  );

  Future<dynamic> patch(String path, {Object? body}) => _dedupe(
    _signature('PATCH', path, body),
    () => _send(() => _dio.patch<dynamic>(path, data: body)),
  );

  /// Fetches a text body such as CSV (`GET /export/:dataset`).
  Future<String> getText(String path, {Map<String, dynamic>? query}) async =>
      (await _send(
            () => _dio.get<dynamic>(
              path,
              queryParameters: _query(query),
              options: Options(responseType: ResponseType.plain),
            ),
          ))
          as String;

  /// Fetches a binary body such as an uploaded image (`GET /files/:id`).
  Future<Uint8List> getBytes(String path) async {
    try {
      final response = await _dio.get<List<int>>(
        path,
        options: Options(responseType: ResponseType.bytes),
      );
      return Uint8List.fromList(response.data ?? const []);
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  Future<dynamic> delete(String path) => _dedupe(
    _signature('DELETE', path, null),
    () => _send(() => _dio.delete<dynamic>(path)),
  );

  Future<Json> getJson(String path, {Map<String, dynamic>? query}) async =>
      asJson(await get(path, query: query));

  Future<Json> postJson(
    String path, {
    Object? body,
    String? idempotencyKey,
  }) async =>
      asJson(await post(path, body: body, idempotencyKey: idempotencyKey));

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
