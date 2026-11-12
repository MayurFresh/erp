import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:progen_erp/core/theme.dart';
import 'package:progen_erp/widgets/activity_timeline.dart';
import 'package:progen_erp/widgets/illustrations.dart';
import 'package:progen_erp/widgets/key_value_list.dart';
import 'package:progen_erp/widgets/kpi_tile.dart';
import 'package:progen_erp/widgets/money_text.dart';
import 'package:progen_erp/widgets/skeleton.dart';
import 'package:progen_erp/widgets/states.dart';
import 'package:progen_erp/widgets/status_chip.dart';

import '../support/app_harness.dart';

Widget _host(Widget child, {double width = 320, ThemeData? theme}) =>
    MaterialApp(
      theme: theme ?? AppTheme.light,
      home: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(width: width, child: child),
        ),
      ),
    );

void main() {
  test('status words map to tones', () {
    expect(toneForStatus('Posted'), StatusTone.success);
    expect(toneForStatus('partially_paid'), StatusTone.warning);
    expect(toneForStatus('overdue'), StatusTone.danger);
    expect(toneForStatus('draft'), StatusTone.neutral);
  });

  testWidgets('StatusChip shows its label in light and dark', (t) async {
    for (final theme in [AppTheme.light, AppTheme.dark]) {
      await t.pumpWidget(_host(const StatusChip('overdue'), theme: theme));
      expect(find.byType(StatusChip), findsOneWidget);
      expect(t.takeException(), isNull);
    }
    await t.pumpWidget(_host(const StatusChip('x', label: 'Custom')));
    expect(find.text('Custom'), findsOneWidget);
  });

  testWidgets('MoneyText groups in the Indian style', (t) async {
    await t.pumpWidget(_host(const MoneyText(1234567.5)));
    expect(find.textContaining('12,34,567.50'), findsOneWidget);
    await t.pumpWidget(_host(const MoneyText(-500)));
    expect(find.textContaining('−₹500'), findsOneWidget);
    await t.pumpWidget(_host(const MoneyText(25000000, compact: true)));
    expect(find.textContaining('crore'), findsOneWidget);
  });

  testWidgets('KpiTile shows label, value, hint and handles taps', (t) async {
    var taps = 0;
    await t.pumpWidget(
      _host(
        KpiTile(
          label: 'Sales this month',
          value: 'Rs 1,000',
          hint: '3 invoices',
          onTap: () => taps++,
        ),
      ),
    );
    expect(find.text('Sales this month'), findsOneWidget);
    expect(find.text('3 invoices'), findsOneWidget);
    await t.tap(find.text('Rs 1,000'));
    expect(taps, 1);
  });

  testWidgets('KeyValueList renders every pair', (t) async {
    await t.pumpWidget(
      _host(
        const KeyValueList(
          items: [
            KeyValue('GSTIN', '27ABCDE1234F1Z5'),
            KeyValue('State', 'MH'),
          ],
        ),
      ),
    );
    expect(find.text('GSTIN'), findsOneWidget);
    expect(find.text('MH'), findsOneWidget);
  });

  testWidgets('ActivityTimeline renders events', (t) async {
    await t.pumpWidget(
      _host(
        const ActivityTimeline(
          events: [
            TimelineEvent(title: 'Posted', detail: 'By Asha', when: 'Today'),
            TimelineEvent(title: 'Created'),
          ],
        ),
      ),
    );
    expect(find.text('Posted'), findsOneWidget);
    expect(find.text('By Asha'), findsOneWidget);
    expect(find.text('Created'), findsOneWidget);
  });

  testWidgets('Skeleton animates without errors', (t) async {
    await t.pumpWidget(_host(const SkeletonList(rows: 3)));
    await t.pump(const Duration(milliseconds: 600));
    expect(find.byType(Skeleton), findsWidgets);
    expect(t.takeException(), isNull);
  });

  testWidgets('every illustration paints at 320 px', (t) async {
    for (final k in IllustrationKind.values) {
      await t.pumpWidget(_host(Illustration(k)));
      expect(t.takeException(), isNull, reason: '$k');
    }
    await t.pumpWidget(
      _host(
        const EmptyView(
          message: 'No items yet. Add your first item.',
          illustration: IllustrationKind.stock,
        ),
      ),
    );
    expect(find.textContaining('No items yet'), findsOneWidget);
  });

  for (final w in [320.0, 1440.0]) {
    testWidgets('sign-in fits at ${w.toInt()} px', (t) async {
      final h = await bootApp(t, Size(w, 800), restore: false);
      expect(find.text('Progen'), findsWidgets);
      expect(find.byType(TextField), findsWidgets);
      h.expectClean('sign-in $w');
    });

    testWidgets('dashboard fits at ${w.toInt()} px', (t) async {
      final h = await bootApp(t, Size(w, 800));
      await h.go('/');
      expect(find.text('Sales and purchases by month'), findsOneWidget);
      h.expectClean('dashboard $w');
    });
  }
}
