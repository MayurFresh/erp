import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:progen_erp/core/theme.dart';
import 'package:progen_erp/features/controls/controls_models.dart';
import 'package:progen_erp/features/controls/controls_repository.dart';
import 'package:progen_erp/features/controls/cost_centre_widgets.dart';
import 'package:progen_erp/widgets/picker_field.dart';

Future<void> _pump(WidgetTester tester, ThemeData theme) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Expanded(
              child: TextField(decoration: InputDecoration(labelText: 'Name')),
            ),
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: 'a',
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Kind'),
                items: const [DropdownMenuItem(value: 'a', child: Text('A'))],
                onChanged: (_) {},
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

double _height(WidgetTester tester, Type type) => tester
    .getSize(
      find.descendant(
        of: find.byType(type),
        matching: find.byType(InputDecorator),
      ),
    )
    .height;

void main() {
  testWidgets('a text field and a dropdown in a row are the same height', (
    tester,
  ) async {
    for (final theme in [AppTheme.light, AppTheme.dense(AppTheme.light)]) {
      await _pump(tester, theme);
      expect(
        _height(tester, TextField),
        _height(tester, DropdownButtonFormField<String>),
      );
    }
  });

  testWidgets('the document form fields share one height', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          costCentresProvider(false).overrideWith(
            (ref) async => const [CostCentre(id: 'a', code: 'A', name: 'A')],
          ),
          costCentreRequiredProvider.overrideWith((ref) async => false),
        ],
        child: MaterialApp(
          theme: AppTheme.dense(AppTheme.light),
          home: Scaffold(
            body: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Expanded(
                  child: TextField(
                    decoration: InputDecoration(labelText: 'Notes'),
                  ),
                ),
                Expanded(
                  child: CostCentreField(value: null, onChanged: (_) {}),
                ),
                Expanded(
                  child: PickerField(
                    label: 'Date',
                    value: '04 Nov 2026',
                    onTap: () {},
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final text = _height(tester, TextField);
    expect(_height(tester, CostCentreField), text);
    expect(_height(tester, PickerField), text);
  });
}
