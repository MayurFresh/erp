import 'package:flutter_test/flutter_test.dart';

import 'support/construction_harness.dart';

/// Opens every construction screen at phone, tablet, laptop and desktop
/// widths, failing on overflow, layout or runtime errors.
void main() {
  // Route → a text that only appears once the screen has its data.
  const routes = {
    '/projects': 'Tower Heights Residency',
    '/projects/new': 'Create project',
    '/projects/pr1': 'Quick actions',
    '/projects/pr1?tab=boq': 'Excavation in ordinary soil',
    '/projects/pr1?tab=costs': 'Over budget by',
    '/projects/pr1?tab=dprs': 'Site A — Tower 1',
    '/projects/pr1?tab=indents': 'IND/26-27/00001',
    '/projects/pr1/edit': 'Save changes',
    '/dprs': '27 Oct 2026',
    '/dprs/new?locationId=l2': 'Copy yesterday',
    '/dprs/dpr1': 'Cement delivery late',
    '/dprs/dpr2': 'Approve',
    '/dprs/dpr1/edit': 'Excavation in ordinary soil',
    '/attendance?siteId=l2&date=2026-10-27': 'Ramesh Kumar',
    '/indents': 'IND/26-27/00002',
    '/indents/new': 'Add material',
    '/indents/ind1': 'Requested 200 bag',
    '/indents/ind2/edit': 'Portland Cement 53 Grade 50kg',
    '/issues': 'ISS/26-27/00001',
    '/issues/new': 'Post issue',
    '/issues/iss1': 'Foundation PCC',
    '/workers': 'Ramesh Kumar',
    '/workers/new': 'Statutory details',
    '/workers/w1': 'Ramesh Kumar',
    '/workers/w1/edit': 'KA/BOCW/2026/0042',
    '/wage-sheets': 'WG/26-27/00001',
    '/wage-sheets/new': 'Create draft',
    '/wage-sheets/wg1': 'Ramesh Kumar',
  };

  for (final size in constructionTestWidths) {
    testWidgets('construction screens render at ${size.width.toInt()} px', (
      tester,
    ) async {
      final app = await bootConstruction(tester, size);
      for (final MapEntry(key: route, value: marker) in routes.entries) {
        await app.go(route);
        expect(
          find.textContaining(marker),
          findsWidgets,
          reason: '$route should show "$marker" at $size',
        );
        app.expectClean('$route at $size');
      }
    });
  }

  testWidgets('screens show a lock without the view permission', (
    tester,
  ) async {
    final app = await bootConstruction(
      tester,
      constructionTestWidths.first,
      permissions: {'dashboard.view'},
    );
    for (final route in ['/projects', '/dprs', '/attendance', '/wage-sheets']) {
      await app.go(route);
      expect(
        find.textContaining('You do not have access'),
        findsOneWidget,
        reason: route,
      );
      app.expectClean(route);
    }
  });
}
