import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/core/money.dart';
import 'package:onematrix/widgets/charts/charts.dart';

Widget host(
  Widget child, {
  double width = 320,
  ThemeMode mode = ThemeMode.light,
}) {
  return MaterialApp(
    themeMode: mode,
    theme: ThemeData(useMaterial3: true),
    darkTheme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
    home: Scaffold(
      body: SingleChildScrollView(
        child: SizedBox(width: width, child: child),
      ),
    ),
  );
}

void main() {
  tearDown(() => configureMoney());

  group('formatCompact', () {
    test('INR uses K, L and Cr', () {
      configureMoney();
      expect(formatCompact(950), '₹950');
      expect(formatCompact(12500), '₹12.5K');
      expect(formatCompact(250000), '₹2.5 L');
      expect(formatCompact(31000000), '₹3.1 Cr');
      expect(formatCompact(-120000, currency: false), '-1.2 L');
    });
    test('other currencies use K, M, B', () {
      configureMoney(currency: 'USD', locale: 'en_US');
      expect(formatCompact(2500000), r'$2.5M');
      expect(formatCompact(1200), r'$1.2K');
    });
    test('delta and change', () {
      expect(percentChange(112, 100), closeTo(12, 0.001));
      expect(percentChange(5, 0), isNull);
      expect(formatDeltaPercent(12.04), '+12%');
      expect(formatDeltaPercent(-4.5), '-4.5%');
      expect(niceCeil(83000), 100000);
    });
  });

  testWidgets('all charts render at 320 px in light and dark', (t) async {
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      await t.pumpWidget(
        host(
          Column(
            children: [
              TrendChart(
                labels: const ['Apr', 'May', 'Jun'],
                series: const [
                  ChartSeries('Sales', [1, 5e5, 3e5]),
                  ChartSeries('Purchases', [2, 1e5, 2e5]),
                ],
              ),
              GroupedBarChart(
                labels: const ['Apr', 'May', 'Jun'],
                series: const [
                  ChartSeries('In', [1, 5e5, 3e5]),
                  ChartSeries('Out', [2, 1e5, 2e5]),
                ],
              ),
              DonutChart(
                slices: const [
                  DonutSlice('Not due', 100),
                  DonutSlice('1-30 days', 50),
                ],
                centerLabel: 'Total',
              ),
              RankedBarChart(
                bars: const [
                  RankedBar(
                    'Mumbai Infra Projects LLP with a very long name',
                    900,
                    caption: '31%',
                  ),
                  RankedBar('Shree', 100),
                ],
              ),
              const StatTile(
                label: 'Sales',
                value: '₹4.2 L',
                deltaPercent: 12,
                spark: [1, 3, 2, 5],
              ),
              const StatTile(
                label: 'Expenses',
                value: '₹1 L',
                deltaPercent: 8,
                upIsGood: false,
              ),
            ],
          ),
          mode: mode,
        ),
      );
      await t.pumpAndSettle();
      expect(tester(t), isNull);
      expect(find.text('+12%'), findsOneWidget);
      expect(find.text('31%'), findsOneWidget);
    }
  });

  testWidgets('ChartCard shows the empty state and export button', (t) async {
    var exported = 0;
    await t.pumpWidget(
      host(
        const ChartCard(
          title: 'Sales by month',
          isEmpty: true,
          child: SizedBox(),
        ),
      ),
    );
    expect(find.text('No data for this period.'), findsOneWidget);
    expect(find.byIcon(Icons.download_outlined), findsNothing);
    await t.pumpWidget(
      host(
        ChartCard(
          title: 'Sales by month',
          onExport: () => exported++,
          child: const SizedBox(height: 10),
        ),
      ),
    );
    await t.tap(find.byIcon(Icons.download_outlined));
    expect(exported, 1);
  });

  testWidgets('ranked bars sort and limit rows', (t) async {
    await t.pumpWidget(
      host(
        RankedBarChart(
          maxRows: 2,
          bars: const [RankedBar('a', 1), RankedBar('b', 9), RankedBar('c', 5)],
        ),
      ),
    );
    expect(find.text('b'), findsOneWidget);
    expect(find.text('c'), findsOneWidget);
    expect(find.text('a'), findsNothing);
  });

  test('palette cycles', () {
    expect(
      const ChartPalette(
        series: [Colors.red, Colors.blue],
        grid: Colors.grey,
        label: Colors.grey,
        surface: Colors.white,
        tooltipBg: Colors.black,
        tooltipText: Colors.white,
        good: Colors.green,
        bad: Colors.red,
      ).at(3),
      Colors.blue,
    );
  });
}

Object? tester(WidgetTester t) => t.takeException();
