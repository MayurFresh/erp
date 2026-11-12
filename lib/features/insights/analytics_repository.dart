import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../auth/session.dart';
import '../reports/report_period.dart';
import 'analytics_models.dart';

/// Analytics for a period; needs `reports.view` on the server.
final analyticsProvider = FutureProvider.autoDispose
    .family<Analytics, DateRange>((ref, range) {
      ref.watch(activeCompanyIdProvider);
      ref.watchRevisions(const [
        ...moneyKinds,
        DataKind.stock,
        DataKind.expenses,
      ]);
      return ref
          .watch(apiClientProvider)
          .getJson(
            '/analytics/overview',
            query: {'from': range.apiFrom, 'to': range.apiTo},
          )
          .then(Analytics.fromJson);
    });
