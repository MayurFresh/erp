import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:progen_erp/widgets/form_support.dart';

void main() {
  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showFormDialog<void>(
              context: context,
              builder: (_) => AlertDialog(
                content: TextField(
                  controller: TextEditingController(text: 'loaded'),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets('closing an untouched dialog needs no confirmation', (t) async {
    await open(t);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('typed content asks first on Cancel, Esc and scrim tap', (
    t,
  ) async {
    await open(t);
    await t.enterText(find.byType(TextField), 'typed');
    await t.pumpAndSettle();

    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    await t.tap(find.text('Keep editing'));
    await t.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);

    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    await t.tap(find.text('Keep editing'));
    await t.pumpAndSettle();

    await t.tapAt(const Offset(5, 5));
    await t.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    await t.tap(find.text('Discard'));
    await t.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });
}
