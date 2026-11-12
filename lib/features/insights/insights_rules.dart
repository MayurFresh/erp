/// Plain-language takeaways from analytics figures, by fixed rules.
/// Pure Dart: no Flutter, no network, no AI.
library;

import '../../widgets/charts/chart_format.dart';
import 'analytics_models.dart';

enum TakeawayTone { good, warning, neutral }

class Takeaway {
  const Takeaway(this.text, this.tone);
  final String text;
  final TakeawayTone tone;

  @override
  String toString() => text;
}

/// Rules run in a fixed order, so the most important lines come first.
/// [versus] names the comparison, e.g. `last month` or `the previous period`.
/// At most [limit] lines are returned.
List<Takeaway> buildTakeaways(
  Analytics a, {
  String versus = 'the previous period',
  int limit = 6,
}) {
  final out = <Takeaway>[];
  final cur = a.current, prev = a.previous;

  // Sales against the previous period.
  final salesChange = percentChange(cur.sales, prev.sales);
  if (salesChange != null && salesChange.abs() >= 1) {
    final up = salesChange > 0;
    out.add(
      Takeaway(
        'Sales are ${up ? 'up' : 'down'} ${_pct(salesChange)} on $versus, '
        '${formatCompact(prev.sales)} to ${formatCompact(cur.sales)}.',
        up ? TakeawayTone.good : TakeawayTone.warning,
      ),
    );
  } else if (cur.sales == 0 && prev.sales == 0) {
    out.add(
      const Takeaway(
        'No sales are posted in this period or the one before it.',
        TakeawayTone.neutral,
      ),
    );
  } else if (salesChange == null && cur.sales > 0) {
    out.add(
      Takeaway(
        'Sales are ${formatCompact(cur.sales)}. There were none in $versus.',
        TakeawayTone.neutral,
      ),
    );
  }

  // Customer concentration.
  if (a.topCustomers.isNotEmpty && cur.sales > 0) {
    final c = a.topCustomers.first;
    final share = c.share ?? c.amount / cur.sales * 100;
    if (share >= 50) {
      out.add(
        Takeaway(
          'More than half of sales (${share.round()}%) come from ${c.name}. '
          'Losing this customer would hurt.',
          TakeawayTone.warning,
        ),
      );
    } else if (share >= 25) {
      out.add(
        Takeaway(
          '${c.name} is ${share.round()}% of sales.',
          TakeawayTone.neutral,
        ),
      );
    }
  }

  // Profit.
  final net = cur.netProfit;
  if (net != null) {
    if (net < 0) {
      out.add(
        Takeaway(
          'The business made a loss of ${formatCompact(-net)} in this period.',
          TakeawayTone.warning,
        ),
      );
    } else if (cur.sales > 0) {
      final margin = net / cur.sales * 100;
      out.add(
        Takeaway(
          'Net profit is ${formatCompact(net)}, a margin of '
          '${margin.toStringAsFixed(margin < 10 ? 1 : 0)}% on sales.',
          margin >= 10 ? TakeawayTone.good : TakeawayTone.neutral,
        ),
      );
    }
    final pc = percentChange(net, prev.netProfit);
    if (pc != null && prev.netProfit! > 0 && pc.abs() >= 10) {
      out.add(
        Takeaway(
          'Profit is ${pc > 0 ? 'up' : 'down'} ${_pct(pc)} on $versus.',
          pc > 0 ? TakeawayTone.good : TakeawayTone.warning,
        ),
      );
    }
  }

  // Expenses growing faster than sales.
  final expChange = percentChange(cur.expenses, prev.expenses);
  if (expChange != null && expChange >= 20 && expChange > (salesChange ?? 0)) {
    out.add(
      Takeaway(
        'Expenses rose ${_pct(expChange)} on $versus, faster than sales.',
        TakeawayTone.warning,
      ),
    );
  }
  if (a.expensesByCategory.isNotEmpty && cur.expenses > 0) {
    final e = a.expensesByCategory.first;
    final share = e.amount / cur.expenses * 100;
    if (share >= 40) {
      out.add(
        Takeaway(
          '${e.name} is ${share.round()}% of expenses.',
          TakeawayTone.neutral,
        ),
      );
    }
  }

  // Money owed to the business.
  final recv = a.receivableAgeing;
  if (recv.total > 0) {
    final late = recv.over60;
    if (late > 0 && late / recv.total >= 0.2) {
      out.add(
        Takeaway(
          '${formatCompact(late)} (${(late / recv.total * 100).round()}%) of '
          'receivables is more than 60 days late. Follow up on these first.',
          TakeawayTone.warning,
        ),
      );
    } else if (recv.notDue / recv.total >= 0.8) {
      out.add(
        Takeaway(
          'Most receivables are not yet due, so collections look healthy.',
          TakeawayTone.good,
        ),
      );
    }
  }

  // Cash.
  final cash = a.cashFlow;
  if (cash != null && cash.isNotEmpty) {
    final inn = cash.fold<double>(0, (s, c) => s + c.cashIn);
    final outg = cash.fold<double>(0, (s, c) => s + c.cashOut);
    if (outg > inn && outg > 0) {
      out.add(
        Takeaway(
          'You paid out ${formatCompact(outg - inn)} more than you collected '
          'in this period.',
          TakeawayTone.warning,
        ),
      );
    } else if (inn > 0) {
      out.add(
        Takeaway(
          'You collected ${formatCompact(inn - outg)} more than you paid out.',
          TakeawayTone.good,
        ),
      );
    }
  }
  final cb = cur.cashAndBank, pay = cur.payables;
  if (cb != null && pay != null && pay > cb && pay > 0) {
    out.add(
      Takeaway(
        'Payables (${formatCompact(pay)}) are more than cash and bank '
        '(${formatCompact(cb)}).',
        TakeawayTone.warning,
      ),
    );
  }

  // Best month.
  if (a.trend.length >= 3) {
    final best = a.trend.reduce((x, y) => x.sales >= y.sales ? x : y);
    if (best.sales > 0) {
      out.add(
        Takeaway(
          'The best month for sales was ${monthLabel(best.month, withYear: true)} '
          'at ${formatCompact(best.sales)}.',
          TakeawayTone.neutral,
        ),
      );
    }
  }

  // Top item.
  if (a.topItems.isNotEmpty && cur.sales > 0) {
    final i = a.topItems.first;
    final share = i.amount / cur.sales * 100;
    if (share >= 20) {
      out.add(
        Takeaway(
          '${i.name} brings in ${share.round()}% of sales.',
          TakeawayTone.neutral,
        ),
      );
    }
  }

  return out.take(limit).toList();
}

String _pct(double v) {
  final a = v.abs();
  return '${a >= 10 ? a.round() : double.parse(a.toStringAsFixed(1))}%';
}
