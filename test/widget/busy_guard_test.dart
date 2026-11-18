import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:onematrix/core/dirty_registry.dart';
import 'package:onematrix/widgets/busy.dart';
import 'package:onematrix/widgets/layout.dart';

void main() {
  testWidgets('BusyButton disables and shows progress while running', (
    tester,
  ) async {
    final done = Completer<void>();
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BusyButton(
            label: 'Save',
            onPressed: () {
              calls++;
              return done.future;
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.byType(FilledButton), warnIfMissed: false);
    await tester.pump();
    expect(calls, 1);
    done.complete();
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(calls, 2);
  });

  testWidgets('UnsavedChangesGuard confirms before leaving when dirty', (
    tester,
  ) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(
            body: Builder(
              builder: (c) => TextButton(
                onPressed: () => c.push('/form'),
                child: const Text('open'),
              ),
            ),
          ),
        ),
        GoRoute(path: '/form', builder: (_, _) => const _Form()),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Clean: back leaves without a prompt.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsNothing);
    expect(find.text('open'), findsOneWidget);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'x');
    await tester.pump();

    // Dirty: back asks first; Keep editing stays.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);

    // Discard leaves.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('UnsavedChangesGuard registers dirty state for the router', (
    tester,
  ) async {
    Widget app(bool dirty) => MaterialApp(
      home: UnsavedChangesGuard(dirty: dirty, child: const SizedBox()),
    );
    await tester.pumpWidget(app(true));
    expect(DirtyRegistry.instance.isDirty, isTrue);
    await tester.pumpWidget(app(false));
    expect(DirtyRegistry.instance.isDirty, isFalse);
    await tester.pumpWidget(app(true));
    DirtyRegistry.instance.noteSaved();
    expect(DirtyRegistry.instance.isDirty, isFalse);
    await tester.pumpWidget(const SizedBox());
    DirtyRegistry.instance.clear();
    expect(DirtyRegistry.instance.isDirty, isFalse);
  });

}

class _Form extends StatefulWidget {
  const _Form();

  @override
  State<_Form> createState() => _FormState();
}

class _FormState extends State<_Form> {
  bool _dirty = false;

  @override
  Widget build(BuildContext context) => UnsavedChangesGuard(
    dirty: _dirty,
    child: Scaffold(
      body: TextField(onChanged: (_) => setState(() => _dirty = true)),
    ),
  );
}
