import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:onematrix/core/api_client.dart';
import 'package:onematrix/core/providers.dart';
import 'package:onematrix/core/theme.dart';
import 'package:onematrix/core/token_store.dart';

import '../support/fake_backend.dart';

typedef Handler = (int, Object?)? Function(RequestOptions o);

/// Answers the routes a test registers and sends the rest to the shared fake.
class HdBackend implements HttpClientAdapter {
  HdBackend(Set<String> permissions, this.handler)
    : _core = FakeBackend(permissions: permissions);

  final FakeBackend _core;
  final Handler handler;
  final List<RequestOptions> calls = [];

  RequestOptions? last(String method, String path) {
    final hits = calls.where((r) => r.method == method && r.path == path);
    return hits.isEmpty ? null : hits.last;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add(options);
    final hit = handler(options);
    if (hit == null) return _core.fetch(options, requestStream, cancelFuture);
    return ResponseBody.fromString(
      jsonEncode(hit.$2),
      hit.$1,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<HdBackend> bootHd(
  WidgetTester tester,
  Size size, {
  required List<RouteBase> routes,
  required String initial,
  required Set<String> extraPermissions,
  required Handler handler,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final backend = HdBackend({
    ...FakeBackend.allPermissions,
    ...extraPermissions,
  }, handler);
  final store = InMemoryTokenStore();
  await store.writeRefreshToken('refresh-1');
  final api = ApiClient(
    baseUrl: 'http://fake/api/v1',
    tokenStore: store,
    httpClientAdapter: backend,
  );
  final router = GoRouter(
    initialLocation: initial,
    routes: [
      ShellRoute(
        builder: (context, state, child) => Scaffold(
          appBar: AppBar(title: const Text('OneMatrix')),
          body: child,
        ),
        routes: [
          ...routes,
          GoRoute(path: '/parties/:id', builder: (_, _) => const Text('Party')),
        ],
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        tokenStoreProvider.overrideWithValue(store),
        apiClientProvider.overrideWithValue(api),
      ],
      child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return backend;
}
