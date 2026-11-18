import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/core/permissions.dart';
import 'package:onematrix/core/theme.dart';
import 'package:onematrix/features/auth/session.dart';
import 'package:onematrix/features/compliance/compliance_repository.dart';
import 'package:onematrix/features/compliance/tax_perms.dart';
import 'package:onematrix/features/fixed_assets/fa_depreciation_tab.dart';
import 'package:onematrix/features/fixed_assets/fa_detail_screen.dart';
import 'package:onematrix/features/fixed_assets/fa_form_screen.dart';
import 'package:onematrix/features/fixed_assets/fa_models.dart';
import 'package:onematrix/features/fixed_assets/fa_register_screen.dart';
import 'package:onematrix/features/fixed_assets/fa_repository.dart';
import 'package:onematrix/features/locations/locations_repository.dart';

const assetJson = <String, dynamic>{
  'id': 'a1',
  'number': 'FA-0001',
  'name': 'Concrete mixer',
  'blockCode': 'plant',
  'blockName': 'Plant and machinery',
  'bookMethod': 'slm',
  'usefulLifeYears': 8,
  'residualPct': 5,
  'cost': 100000,
  'gstItc': 18000,
  'purchaseDate': '2026-04-10',
  'putToUseDate': '2026-04-12',
  'openingAccDep': 0,
  'accumulatedDep': 5000,
  'bookValue': 95000,
  'status': 'active',
  'history': [],
};

class FakeFa implements FixedAssetRepository {
  Map<String, dynamic>? disposeBody;
  final calls = <String>[];

  @override
  Future<List<ItBlock>> blocks() async => const [];

  @override
  Future<AssetPage> list({
    String? status,
    String? blockCode,
    String? q,
    int offset = 0,
    int limit = 50,
  }) async => AssetPage(
    data: [FixedAsset.fromJson(assetJson)],
    total: 1,
    totals: const AssetTotals(
      cost: 100000,
      accumulatedDep: 5000,
      bookValue: 95000,
    ),
  );

  @override
  Future<FixedAsset> asset(String id) async => FixedAsset.fromJson(assetJson);

  @override
  Future<FixedAsset> dispose(String id, Map<String, dynamic> body) async {
    disposeBody = body;
    return FixedAsset.fromJson(assetJson);
  }

  @override
  Future<DepRun> runDepreciation({
    required String toDate,
    List<String>? assetIds,
    bool preview = false,
  }) async {
    calls.add(preview ? 'preview' : 'post');
    return DepRun(
      toDate: toDate,
      total: 5000,
      id: preview ? null : 'r1',
      number: preview ? '' : 'DEP-0001',
      lines: const [
        DepLine(
          assetId: 'a1',
          number: 'FA-0001',
          name: 'Concrete mixer',
          from: '2026-04-12',
          to: '2026-09-30',
          days: 172,
          amount: 5000,
        ),
      ],
    );
  }

  @override
  Future<List<DepRun>> runs(String fy) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

Future<void> pumpFa(
  WidgetTester tester,
  Widget child, {
  FakeFa? repo,
  Size size = const Size(800, 1000),
  double scale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        fixedAssetRepositoryProvider.overrideWithValue(repo ?? FakeFa()),
        permissionsProvider.overrideWithValue(
          const PermissionSet({TaxPerm.assetsView, TaxPerm.assetsManage}),
        ),
        locationsLookupProvider.overrideWith((ref) async => []),
        accountOptionsProvider.overrideWith((ref) async => []),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class OpenDialog extends StatelessWidget {
  const OpenDialog(this.dialog, {super.key});

  final Widget dialog;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () => showDialog<void>(context: context, builder: (_) => dialog),
    child: const Text('open'),
  );
}

void main() {
  testWidgets('depreciation: preview then confirm posts', (tester) async {
    final repo = FakeFa();
    await pumpFa(tester, const OpenDialog(DepreciationRunDialog()), repo: repo);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    expect(repo.calls, ['preview']);
    expect(find.textContaining('Concrete mixer'), findsWidgets);
    await tester.tap(find.text('Confirm and post'));
    await tester.pumpAndSettle();
    expect(repo.calls, ['preview', 'post']);
  });

  test('depreciation error messages', () {
    expect(depreciationErrorMessage(StateError('x')), isNotEmpty);
  });

  testWidgets('dispose form requires a received-in account for a sale', (
    tester,
  ) async {
    final repo = FakeFa();
    await pumpFa(
      tester,
      OpenDialog(DisposeAssetDialog(asset: FixedAsset.fromJson(assetJson))),
      repo: repo,
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Sale value'),
      '50000',
    );
    await tester.tap(find.text('Dispose').last);
    await tester.pumpAndSettle();
    expect(repo.disposeBody, isNull);
    expect(find.textContaining('Choose'), findsWidgets);
  });

  testWidgets('fixed-asset screens fit 320 px at text scale 1.3', (
    tester,
  ) async {
    final failures = <String>[];
    final orig = FlutterError.onError;
    FlutterError.onError = (d) =>
        failures.add(d.toString().split("\n").take(14).join("\n"));
    final screens = <String, Widget>{
      'register': const FixedAssetsScreen(),
      'detail': const FixedAssetDetailScreen(id: 'a1'),
      'new': const FixedAssetFormScreen(),
      'dep dialog': const OpenDialog(DepreciationRunDialog()),
      'dispose': OpenDialog(
        DisposeAssetDialog(asset: FixedAsset.fromJson(assetJson)),
      ),
    };
    for (final e in screens.entries) {
      await pumpFa(tester, e.value, size: const Size(320, 640), scale: 1.3);
      if (e.value is OpenDialog) {
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
      }
      tester.takeException();
      if (failures.isNotEmpty) failures.add('^ ${e.key}');
    }
    FlutterError.onError = orig;
    expect(failures.where((f) => f.contains('overflow')), isEmpty);
  });
}
