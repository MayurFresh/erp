import '../../core/json.dart';

/// A marketplace or web store the business sells on.
class Channel {
  const Channel({
    required this.id,
    required this.provider,
    required this.name,
    required this.status,
    required this.locationId,
    required this.locationName,
    required this.pricesIncludeTax,
    required this.orderStatus,
    required this.tcsRate,
    required this.tdsRate,
    required this.listingCount,
    required this.unmappedCount,
    required this.orderCounts,
    required this.stage,
    required this.note,
    this.lastImportAt,
    this.updatedAt,
  });

  factory Channel.fromJson(Json j) {
    final connector = asJson(j['connector']);
    return Channel(
      id: asString(j['id']),
      provider: asString(j['provider']),
      name: asString(j['name']),
      status: asString(j['status']),
      locationId: asString(j['locationId']),
      locationName: asString(j['locationName']),
      pricesIncludeTax: asBool(j['pricesIncludeTax'], true),
      orderStatus: asString(j['orderStatus'], 'confirmed'),
      tcsRate: asDouble(j['tcsRate']),
      tdsRate: asDouble(j['tdsRate']),
      listingCount: asInt(j['listingCount']),
      unmappedCount: asInt(j['unmappedCount']),
      orderCounts: {
        for (final e in asJson(j['orderCounts']).entries) e.key: asInt(e.value),
      },
      stage: asString(connector['stage']),
      note: asString(connector['note']),
      lastImportAt: asDateTimeOrNull(j['lastImportAt']),
      updatedAt: asString(j['updatedAt']),
    );
  }

  final String id;
  final String provider;
  final String name;
  final String status;
  final String locationId;
  final String locationName;
  final bool pricesIncludeTax;
  final String orderStatus;
  final double tcsRate;
  final double tdsRate;
  final int listingCount;
  final int unmappedCount;
  final Map<String, int> orderCounts;
  final String stage;
  final String note;
  final DateTime? lastImportAt;
  final String? updatedAt;

  int get failedCount => orderCounts['failed'] ?? 0;

  bool get isFileOnly => provider != 'manual' && provider != 'other';
}

class ListingComponent {
  const ListingComponent({
    required this.itemId,
    required this.itemName,
    required this.qty,
    this.itemSku,
  });

  factory ListingComponent.fromJson(Json j) => ListingComponent(
    itemId: asString(j['itemId']),
    itemName: asString(j['itemName']),
    itemSku: asStringOrNull(j['itemSku']),
    qty: asDouble(j['qty'], 1),
  );

  final String itemId;
  final String itemName;
  final String? itemSku;
  final double qty;
}

class Listing {
  const Listing({
    required this.id,
    required this.channelSku,
    required this.components,
    this.title,
  });

  factory Listing.fromJson(Json j) => Listing(
    id: asString(j['id']),
    channelSku: asString(j['channelSku']),
    title: asStringOrNull(j['title']),
    components: asJsonList(
      j['components'],
    ).map(ListingComponent.fromJson).toList(),
  );

  final String id;
  final String channelSku;
  final String? title;
  final List<ListingComponent> components;

  bool get isBundle =>
      components.length > 1 ||
      (components.isNotEmpty && components.first.qty != 1);
}

class UnmappedSku {
  const UnmappedSku({
    required this.channelSku,
    required this.seenCount,
    this.title,
  });

  factory UnmappedSku.fromJson(Json j) => UnmappedSku(
    channelSku: asString(j['channelSku']),
    title: asStringOrNull(j['title']),
    seenCount: asInt(j['seenCount'], 1),
  );

  final String channelSku;
  final String? title;
  final int seenCount;
}

class InboxOrder {
  const InboxOrder({
    required this.id,
    required this.connectionName,
    required this.externalRef,
    required this.status,
    required this.lines,
    this.error,
    this.errorCode,
    this.salesOrderId,
    this.salesOrderNumber,
    this.salesOrderStatus,
    this.orderDate,
    this.total,
  });

  factory InboxOrder.fromJson(Json j) => InboxOrder(
    id: asString(j['id']),
    connectionName: asString(j['connectionName']),
    externalRef: asString(j['externalRef']),
    status: asString(j['status']),
    error: asStringOrNull(j['error']),
    errorCode: asStringOrNull(j['errorCode']),
    salesOrderId: asStringOrNull(j['salesOrderId']),
    salesOrderNumber: asStringOrNull(j['salesOrderNumber']),
    salesOrderStatus: asStringOrNull(j['salesOrderStatus']),
    orderDate: asStringOrNull(j['orderDate']),
    total: asDoubleOrNull(j['total']),
    lines: asJsonList(
      j['lines'],
    ).map((l) => '${asString(l['sku'])} x ${asString(l['qty'])}').toList(),
  );

  final String id;
  final String connectionName;
  final String externalRef;
  final String status;
  final String? error;
  final String? errorCode;
  final String? salesOrderId;
  final String? salesOrderNumber;
  final String? salesOrderStatus;
  final String? orderDate;
  final double? total;
  final List<String> lines;

  bool get canRetry => status == 'failed';
}

class InboxPage {
  const InboxPage(this.data, this.total, this.counts);
  final List<InboxOrder> data;
  final int total;
  final Map<String, int> counts;
}

/// One order in an import preview.
class PreviewOrder {
  const PreviewOrder({
    required this.externalRef,
    required this.action,
    required this.unmappedSkus,
    required this.lines,
    this.reason,
    this.total,
    this.orderDate,
  });

  factory PreviewOrder.fromJson(Json j) => PreviewOrder(
    externalRef: asString(j['externalRef']),
    action: asString(j['action']),
    reason: asStringOrNull(j['reason']),
    orderDate: asStringOrNull(j['orderDate']),
    unmappedSkus: asStringList(j['unmappedSkus']),
    total: asDoubleOrNull(asJson(j['estimate'])['total']),
    lines: asJsonList(j['lines'])
        .map(
          (l) => '${asString(l['itemName'])} x ${formatNumberText(l['qty'])}',
        )
        .toList(),
  );

  final String externalRef;
  final String action;
  final String? reason;
  final String? orderDate;
  final List<String> unmappedSkus;
  final List<String> lines;
  final double? total;
}

String formatNumberText(Object? v) {
  final d = asDouble(v);
  return d == d.roundToDouble() ? d.toInt().toString() : d.toString();
}

class ImportPreview {
  const ImportPreview({
    required this.orders,
    required this.issues,
    required this.summary,
  });

  factory ImportPreview.fromJson(Json j) => ImportPreview(
    orders: asJsonList(j['orders']).map(PreviewOrder.fromJson).toList(),
    issues: asJsonList(j['issues'])
        .map((i) => 'Row ${asString(i['row'])}: ${asString(i['message'])}')
        .toList(),
    summary: {
      for (final e in asJson(j['summary']).entries) e.key: asInt(e.value),
    },
  );

  final List<PreviewOrder> orders;
  final List<String> issues;
  final Map<String, int> summary;
}

class ImportResult {
  const ImportResult({required this.issues, required this.summary});

  factory ImportResult.fromJson(Json j) => ImportResult(
    issues: asJsonList(j['issues'])
        .map((i) => 'Row ${asString(i['row'])}: ${asString(i['message'])}')
        .toList(),
    summary: {
      for (final e in asJson(j['summary']).entries) e.key: asInt(e.value),
    },
  );

  final List<String> issues;
  final Map<String, int> summary;
}

class SettlementPreviewItem {
  const SettlementPreviewItem({
    required this.ref,
    required this.payoutDate,
    required this.payout,
    required this.linesTotal,
    required this.difference,
    required this.status,
    required this.duplicate,
    required this.unmatched,
  });

  factory SettlementPreviewItem.fromJson(Json j) => SettlementPreviewItem(
    ref: asString(j['settlementRef']),
    payoutDate: asString(j['payoutDate']),
    payout: asDouble(j['payout']),
    linesTotal: asDouble(j['linesTotal']),
    difference: asDouble(j['difference']),
    status: asString(j['status']),
    duplicate: asBool(j['duplicate']),
    unmatched: asStringList(j['unmatchedOrderRefs']),
  );

  final String ref;
  final String payoutDate;
  final double payout;
  final double linesTotal;
  final double difference;
  final String status;
  final bool duplicate;
  final List<String> unmatched;
}

class SettlementPreview {
  const SettlementPreview({required this.items, required this.issues});

  factory SettlementPreview.fromJson(Json j) => SettlementPreview(
    items: asJsonList(
      j['settlements'],
    ).map(SettlementPreviewItem.fromJson).toList(),
    issues: asJsonList(j['issues'])
        .map((i) => 'Row ${asString(i['row'])}: ${asString(i['message'])}')
        .toList(),
  );

  final List<SettlementPreviewItem> items;
  final List<String> issues;
}

class Settlement {
  const Settlement({
    required this.id,
    required this.connectionName,
    required this.ref,
    required this.payoutDate,
    required this.payout,
    required this.linesTotal,
    required this.difference,
    required this.status,
    this.orders = const [],
    this.totals = const {},
    this.tcs,
    this.tds,
    this.note = '',
    this.unmatchedOrders = 0,
  });

  factory Settlement.fromJson(Json j) {
    final st = asJson(j['statutory']);
    return Settlement(
      id: asString(j['id']),
      connectionName: asString(j['connectionName']),
      ref: asString(j['settlementRef']),
      payoutDate: asString(j['payoutDate']),
      payout: asDouble(j['payout']),
      linesTotal: asDouble(j['linesTotal']),
      difference: asDouble(j['difference']),
      status: asString(j['status']),
      orders: asJsonList(j['orders']).map(OrderRecon.fromJson).toList(),
      totals: {
        for (final e in asJson(j['totals']).entries) e.key: asDouble(e.value),
      },
      tcs: st['tcs'] == null ? null : StatutoryLine.fromJson(asJson(st['tcs'])),
      tds: st['tds'] == null ? null : StatutoryLine.fromJson(asJson(st['tds'])),
      note: asString(st['note']),
      unmatchedOrders: asInt(j['unmatchedOrders']),
    );
  }

  final String id;
  final String connectionName;
  final String ref;
  final String payoutDate;
  final double payout;
  final double linesTotal;
  final double difference;
  final String status;
  final List<OrderRecon> orders;
  final Map<String, double> totals;
  final StatutoryLine? tcs;
  final StatutoryLine? tds;
  final String note;
  final int unmatchedOrders;

  bool get canPost => status == 'imported' || status == 'matched';
}

class OrderRecon {
  const OrderRecon({
    required this.orderRef,
    required this.received,
    required this.fees,
    required this.matched,
    this.orderNumber,
    this.expected,
    this.difference,
  });

  factory OrderRecon.fromJson(Json j) => OrderRecon(
    orderRef: asString(j['orderRef']),
    orderNumber: asStringOrNull(j['orderNumber']),
    expected: asDoubleOrNull(j['expected']),
    received: asDouble(j['received']),
    difference: asDoubleOrNull(j['difference']),
    fees: asDouble(j['fees']),
    matched: asBool(j['matched']),
  );

  final String orderRef;
  final String? orderNumber;
  final double? expected;
  final double received;
  final double? difference;
  final double fees;
  final bool matched;
}

class StatutoryLine {
  const StatutoryLine({
    required this.rate,
    required this.expected,
    required this.received,
    required this.difference,
  });

  factory StatutoryLine.fromJson(Json j) => StatutoryLine(
    rate: asDouble(j['rate']),
    expected: asDouble(j['expected']),
    received: asDouble(j['received']),
    difference: asDouble(j['difference']),
  );

  final double rate;
  final double expected;
  final double received;
  final double difference;
}

/// One credential field of a live channel. The value is never sent back.
class CredentialField {
  const CredentialField({
    required this.key,
    required this.label,
    required this.secret,
    required this.isSet,
  });

  factory CredentialField.fromJson(Json j) => CredentialField(
    key: asString(j['key']),
    label: asString(j['label']),
    secret: asBool(j['secret'], true),
    isSet: asBool(j['set']),
  );

  final String key;
  final String label;
  final bool secret;
  final bool isSet;
}

/// `GET /channels/:id/health` (API v1.9 phase 2).
class ChannelHealth {
  const ChannelHealth({
    required this.id,
    required this.provider,
    required this.status,
    required this.statusReason,
    required this.live,
    required this.hasCredentials,
    required this.credentials,
    required this.pushStock,
    required this.webhookRejects,
    required this.received,
    required this.failed,
    required this.dead,
    required this.unmapped,
    required this.pushErrors,
    required this.queuedJobs,
    this.lastCheckAt,
    this.lastSuccessAt,
    this.lastError,
    this.lastErrorAt,
  });

  factory ChannelHealth.fromJson(Json j) {
    final inbox = asJson(j['inbox']);
    return ChannelHealth(
      id: asString(j['id']),
      provider: asString(j['provider']),
      status: asString(j['status']),
      statusReason: asString(j['statusReason']),
      live: asBool(j['live']),
      hasCredentials: asBool(j['hasCredentials']),
      credentials: asJsonList(
        j['credentials'],
      ).map(CredentialField.fromJson).toList(),
      pushStock: asBool(j['pushStock']),
      webhookRejects: asInt(j['webhookRejects']),
      received: asInt(inbox['received']),
      failed: asInt(inbox['failed']),
      dead: asInt(inbox['dead']),
      unmapped: asInt(j['unmapped']),
      pushErrors: asInt(j['pushErrors']),
      queuedJobs: asInt(j['queuedJobs']),
      lastCheckAt: asDateTimeOrNull(j['lastCheckAt']),
      lastSuccessAt: asDateTimeOrNull(j['lastSuccessAt']),
      lastError: j['lastError'] == null ? null : asString(j['lastError']),
      lastErrorAt: asDateTimeOrNull(j['lastErrorAt']),
    );
  }

  final String id;
  final String provider;
  final String status;
  final String statusReason;
  final bool live;
  final bool hasCredentials;
  final List<CredentialField> credentials;
  final bool pushStock;
  final int webhookRejects;
  final int received;
  final int failed;
  final int dead;
  final int unmapped;
  final int pushErrors;
  final int queuedJobs;
  final DateTime? lastCheckAt;
  final DateTime? lastSuccessAt;
  final String? lastError;
  final DateTime? lastErrorAt;
}
