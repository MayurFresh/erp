import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:progen_erp/core/api_exception.dart';

import '../support/app_harness.dart';
import '../support/fake_backend.dart';

/// A backend whose `POST /payments` fails in a chosen way, [failures] times.
class FlakyBackend extends FakeBackend {
  FlakyBackend(this.failure, {this.failures = 1});

  final Object failure;
  int failures;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method == 'POST' &&
        options.path == '/payments' &&
        failures > 0) {
      failures--;
      requests.add(options);
      final f = failure;
      if (f is DioExceptionType) {
        throw DioException(requestOptions: options, type: f);
      }
      overrides['POST /payments'] = f as (int, Object?);
      final r = await super.fetch(options, requestStream, cancelFuture);
      overrides.remove('POST /payments');
      requests.removeLast();
      return r;
    }
    return super.fetch(options, requestStream, cancelFuture);
  }
}

/// Saving a receipt while the session expires or the network fails: the form
/// keeps what was typed and the message is plain.
void main() {
  const desktop = Size(1440, 900);

  Future<(AppHarness, Finder)> openReceipt(
    WidgetTester tester,
    FakeBackend backend,
  ) async {
    final app = await bootApp(tester, desktop, backend: backend);
    await app.go('/invoices/inv1');
    await tester.tap(find.text('Record receipt'));
    await tester.pumpAndSettle();
    final amount = find.widgetWithText(TextFormField, 'Amount received');
    await tester.enterText(amount, '321');
    await tester.pumpAndSettle();
    return (app, amount);
  }

  String text(WidgetTester t, Finder f) =>
      t.widget<TextFormField>(f).controller!.text;

  testWidgets('401 on save: one refresh, one replay, then saved', (t) async {
    final backend = FlakyBackend(
      FakeBackend.error(401, 'TOKEN_EXPIRED', 'Token expired'),
    );
    final (app, _) = await openReceipt(t, backend);
    final refreshesBefore = backend.count('POST', '/auth/refresh');
    await t.tap(find.text('Save receipt'));
    await t.pumpAndSettle();
    expect(backend.count('POST', '/payments'), 2);
    expect(backend.count('POST', '/auth/refresh'), refreshesBefore + 1);
    expect(app.router.state.uri.path, '/receipts/pay1');
    await t.pump(const Duration(milliseconds: 1));
    await t.pumpAndSettle();
  });

  testWidgets('offline on save: plain message, form intact, retry works', (
    t,
  ) async {
    final backend = FlakyBackend(DioExceptionType.connectionError);
    final (app, amount) = await openReceipt(t, backend);
    await t.tap(find.text('Save receipt'));
    await t.pumpAndSettle();
    expect(find.textContaining(ApiException.offlineMessage), findsWidgets);
    expect(find.textContaining('Dio'), findsNothing);
    expect(text(t, amount), '321');
    expect(app.router.state.uri.path, isNot('/receipts/pay1'));
    await t.pump(const Duration(seconds: 10)); // let the message go away
    await t.pumpAndSettle();
    await t.ensureVisible(find.text('Save receipt'));
    await t.tap(find.text('Save receipt'));
    await t.pumpAndSettle();
    expect(app.router.state.uri.path, '/receipts/pay1');
    // The retry reuses the key, so the server can de-duplicate it.
    final keys = backend.requests
        .where((r) => r.method == 'POST' && r.path == '/payments')
        .map((r) => r.headers['Idempotency-Key'])
        .toSet();
    expect(keys.length, 1);
    await t.pump(const Duration(milliseconds: 1));
    await t.pumpAndSettle();
  });

  testWidgets('timeout on save reads as offline and keeps the form', (t) async {
    final backend = FlakyBackend(DioExceptionType.receiveTimeout);
    final (_, amount) = await openReceipt(t, backend);
    await t.tap(find.text('Save receipt'));
    await t.pumpAndSettle();
    expect(find.textContaining(ApiException.offlineMessage), findsWidgets);
    expect(text(t, amount), '321');
  });

  testWidgets('500 on save: plain message without server detail', (t) async {
    final backend = FlakyBackend(
      FakeBackend.error(500, 'INTERNAL', 'stack trace at line 42'),
    );
    final (app, amount) = await openReceipt(t, backend);
    await t.tap(find.text('Save receipt'));
    await t.pumpAndSettle();
    expect(find.textContaining('stack trace'), findsNothing);
    expect(find.textContaining('went wrong'), findsWidgets);
    expect(text(t, amount), '321');
    expect(app.router.state.uri.path, isNot('/receipts/pay1'));
  });
}
