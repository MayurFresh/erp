import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:progen_erp/core/api_client.dart';
import 'package:progen_erp/core/api_exception.dart';
import 'package:progen_erp/core/token_store.dart';

typedef Handler = FutureOr<ResponseBody> Function(RequestOptions options);

class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.handler);

  Handler handler;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody jsonBody(int status, Object body) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

ResponseBody errorBody(
  int status,
  String code, [
  Map<String, Object>? details,
]) => jsonBody(status, {
  'error': {'code': code, 'message': 'msg $code', 'details': details ?? {}},
});

Map<String, Object> authResult(String access, String refresh) => {
  'accessToken': access,
  'refreshToken': refresh,
  'expiresIn': 900,
  'user': {'id': 'u1', 'name': 'A', 'email': 'a@b.in', 'phone': null},
};

void main() {
  late InMemoryTokenStore store;
  late FakeAdapter adapter;
  late ApiClient api;

  setUp(() async {
    store = InMemoryTokenStore();
    adapter = FakeAdapter((_) => jsonBody(200, {}));
    api = ApiClient(
      baseUrl: 'http://api.test/api/v1',
      tokenStore: store,
      httpClientAdapter: adapter,
    );
    await api.setTokens(
      const AuthTokens(accessToken: 'old', refreshToken: 'r1'),
    );
    await api.setCompany('c1');
  });

  tearDown(() => api.close());

  test('adds Authorization and X-Company-Id (not on /me or /auth)', () async {
    await api.get('/items');
    await api.get('/me');
    await api.post('/auth/login', body: {'email': 'x', 'password': 'y'});

    final items = adapter.requests[0];
    expect(items.uri.toString(), 'http://api.test/api/v1/items');
    expect(items.headers['Authorization'], 'Bearer old');
    expect(items.headers['X-Company-Id'], 'c1');

    final me = adapter.requests[1];
    expect(me.headers['Authorization'], 'Bearer old');
    expect(me.headers.containsKey('X-Company-Id'), isFalse);

    final login = adapter.requests[2];
    expect(login.headers.containsKey('Authorization'), isFalse);
    expect(login.headers.containsKey('X-Company-Id'), isFalse);
  });

  test('drops empty query values and stringifies bools', () async {
    await api.get(
      '/items',
      query: {'q': '', 'activeOnly': true, 'limit': 50, 'type': null},
    );
    expect(adapter.requests.single.uri.query, 'activeOnly=true&limit=50');
  });

  test('maps error bodies to ApiException', () async {
    adapter.handler = (_) =>
        errorBody(400, 'VALIDATION_ERROR', {'name': 'Required'});
    await expectLater(
      api.post('/items', body: {}),
      throwsA(
        isA<ApiException>()
            .having((e) => e.statusCode, 'status', 400)
            .having((e) => e.code, 'code', 'VALIDATION_ERROR')
            .having((e) => e.message, 'message', 'msg VALIDATION_ERROR')
            .having((e) => e.fieldErrors, 'fields', {'name': 'Required'}),
      ),
    );
  });

  test('refreshes once on TOKEN_EXPIRED and retries', () async {
    var refreshes = 0;
    adapter.handler = (o) {
      if (o.path == '/auth/refresh') {
        refreshes++;
        expect(o.data, {'refreshToken': 'r1'});
        return jsonBody(200, authResult('new', 'r2'));
      }
      if (o.headers['Authorization'] == 'Bearer old') {
        return errorBody(401, 'TOKEN_EXPIRED');
      }
      return jsonBody(200, {'data': [], 'total': 0, 'path': o.path});
    };

    final results = await Future.wait([
      api.getJson('/items'),
      api.getJson('/parties'),
      api.getJson('/stock'),
    ]);

    expect(refreshes, 1);
    expect(results.map((r) => r['path']), ['/items', '/parties', '/stock']);
    expect(api.refreshToken, 'r2');
    expect(await store.readRefreshToken(), 'r2');
  });

  test('clears the session when refresh fails', () async {
    final expired = expectLater(api.sessionExpired, emits(null));
    adapter.handler = (o) => o.path == '/auth/refresh'
        ? errorBody(401, 'UNAUTHORIZED')
        : errorBody(401, 'TOKEN_EXPIRED');

    await expectLater(
      api.get('/items'),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'TOKEN_EXPIRED'),
      ),
    );
    await expired;
    expect(api.refreshToken, isNull);
    expect(await store.readRefreshToken(), isNull);
  });

  test('logs out on other 401s', () async {
    final expired = expectLater(api.sessionExpired, emits(null));
    adapter.handler = (_) => errorBody(401, 'UNAUTHORIZED');
    await expectLater(api.get('/items'), throwsA(isA<ApiException>()));
    await expired;
    expect(api.refreshToken, isNull);
  });

  test('network failures become NETWORK_ERROR', () async {
    adapter.handler = (o) => throw DioException.connectionError(
      requestOptions: o,
      reason: 'refused',
    );
    await expectLater(
      api.get('/items'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.code, 'code', ApiException.networkError)
            .having((e) => e.isNetworkError, 'network', isTrue),
      ),
    );
    expect(api.refreshToken, 'r1');
  });
}
