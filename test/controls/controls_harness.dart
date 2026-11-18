import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/core/api_client.dart';
import 'package:onematrix/core/permissions.dart';
import 'package:onematrix/core/providers.dart';
import 'package:onematrix/core/token_store.dart';
import 'package:onematrix/features/auth/session.dart';
import 'package:onematrix/features/controls/controls_perms.dart';

const phone = Size(360, 740);
const desktop = Size(1280, 900);

typedef Handler = (int, Object?) Function(RequestOptions o);

/// Fake HTTP backend: `'METHOD /path'` → handler, plus a request log.
class FakeControlsBackend implements HttpClientAdapter {
  final Map<String, Handler> routes = {};
  final List<RequestOptions> requests = [];

  void on(String key, Object? body, {int status = 200}) =>
      routes[key] = (_) => (status, body);

  RequestOptions? last(String method, String path) =>
      requests.where((r) => r.method == method && r.path == path).lastOrNull;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final h = routes['${options.method} ${options.path}'];
    final (status, body) = h == null
        ? (
            404,
            {
              'error': {
                'code': 'NOT_FOUND',
                'message': 'No fake for ${options.method} ${options.path}',
              },
            },
          )
        : h(options);
    return ResponseBody.fromString(
      body is String ? body : jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [
          body is String ? 'text/csv' : Headers.jsonContentType,
        ],
      },
    );
  }
}

Map<String, Object?> pageOf(List<Object?> data) => {
  'data': data,
  'total': data.length,
};

ApiClient fakeApi(FakeControlsBackend b) => ApiClient(
  baseUrl: 'http://fake/api/v1',
  tokenStore: InMemoryTokenStore(),
  httpClientAdapter: b,
);

/// Pumps [child] in a Scaffold with the session providers stubbed (no
/// AppShell), at [size].
Future<void> pumpControls(
  WidgetTester tester,
  Widget child,
  FakeControlsBackend backend, {
  Size size = desktop,
  Set<String> permissions = const {
    'approvals.view',
    'approvals.manage',
    'accounts.view',
    'accounts.manage',
    'company.manage',
    'imports.run',
  },
  String userId = 'u1',
  Widget Function(Widget)? wrap,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final api = fakeApi(backend);
  Widget app = MaterialApp(home: Scaffold(body: child));
  if (wrap != null) app = wrap(app);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        permissionsProvider.overrideWithValue(PermissionSet(permissions)),
        activeCompanyIdProvider.overrideWithValue('c1'),
        currentUserIdProvider.overrideWithValue(userId),
        tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
      ],
      child: app,
    ),
  );
  await tester.pumpAndSettle();
}

Map<String, Object?> approvalJson({
  String id = 'a1',
  String status = 'pending',
  bool canAct = true,
  String requesterId = 'u2',
}) => {
  'id': id,
  'number': 'APR/0001',
  'docType': 'purchase',
  'status': status,
  'amount': 125000,
  'summary': {'partyName': 'Acme Steel', 'date': '2026-11-01'},
  'requestedBy': {'id': requesterId, 'name': 'Rita'},
  'payload': {'total': 125000},
  'ruleName': 'Big purchases',
  'levels': [
    {'level': 1, 'approverRoleId': 'r1', 'label': 'Admin'},
  ],
  'currentLevel': 1,
  'totalLevels': 1,
  'requestedAt': '2026-11-01T10:00:00Z',
  'canAct': canAct,
  'actions': <Object?>[],
};
