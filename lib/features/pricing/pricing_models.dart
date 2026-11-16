import '../../core/json.dart';

class PriceList {
  const PriceList({
    required this.id,
    required this.name,
    required this.mode,
    this.adjustPct = 0,
    this.validFrom,
    this.validTo,
    this.isActive = true,
    this.notes,
    this.itemCount = 0,
    this.partyCount = 0,
    this.items = const [],
  });

  factory PriceList.fromJson(Json j) => PriceList(
    id: asString(j['id']),
    name: asString(j['name']),
    mode: asString(j['mode'], 'fixed'),
    adjustPct: asDouble(j['adjustPct']),
    validFrom: asStringOrNull(j['validFrom']),
    validTo: asStringOrNull(j['validTo']),
    isActive: asBool(j['isActive'], true),
    notes: asStringOrNull(j['notes']),
    itemCount: asInt(j['itemCount']),
    partyCount: asInt(j['partyCount']),
    items: [for (final i in asJsonList(j['items'])) PriceRow.fromJson(i)],
  );

  final String id;
  final String name;
  final String mode;
  final double adjustPct;
  final String? validFrom;
  final String? validTo;
  final bool isActive;
  final String? notes;
  final int itemCount;
  final int partyCount;
  final List<PriceRow> items;

  bool get isPercent => mode == 'percent';
}

/// One item rate with an optional quantity slab, on a price list or for a customer.
class PriceRow {
  const PriceRow({
    required this.itemId,
    required this.itemName,
    required this.rate,
    this.minQty = 1,
    this.validFrom,
    this.validTo,
  });

  factory PriceRow.fromJson(Json j) => PriceRow(
    itemId: asString(j['itemId']),
    itemName: asString(j['itemName']),
    rate: asDouble(j['rate']),
    minQty: asDouble(j['minQty'], 1),
    validFrom: asStringOrNull(j['validFrom']),
    validTo: asStringOrNull(j['validTo']),
  );

  final String itemId;
  final String itemName;
  final double rate;
  final double minQty;
  final String? validFrom;
  final String? validTo;

  Json toJson() => withoutNulls({
    'itemId': itemId,
    'minQty': minQty,
    'rate': rate,
    'validFrom': validFrom,
    'validTo': validTo,
  });
}

class PriceScheme {
  const PriceScheme({
    required this.id,
    required this.name,
    required this.kind,
    required this.itemId,
    this.itemName = '',
    this.buyQty,
    this.freeQty,
    this.freeItemId,
    this.minQty,
    this.discountPct,
    this.validFrom,
    this.validTo,
    this.isActive = true,
  });

  factory PriceScheme.fromJson(Json j) => PriceScheme(
    id: asString(j['id']),
    name: asString(j['name']),
    kind: asString(j['kind']),
    itemId: asString(j['itemId']),
    itemName: asString(j['itemName']),
    buyQty: asDoubleOrNull(j['buyQty']),
    freeQty: asDoubleOrNull(j['freeQty']),
    freeItemId: asStringOrNull(j['freeItemId']),
    minQty: asDoubleOrNull(j['minQty']),
    discountPct: asDoubleOrNull(j['discountPct']),
    validFrom: asStringOrNull(j['validFrom']),
    validTo: asStringOrNull(j['validTo']),
    isActive: asBool(j['isActive'], true),
  );

  final String id;
  final String name;
  final String kind;
  final String itemId;
  final String itemName;
  final double? buyQty;
  final double? freeQty;
  final String? freeItemId;
  final double? minQty;
  final double? discountPct;
  final String? validFrom;
  final String? validTo;
  final bool isActive;

  bool get isFree => kind == 'free_qty';
}

/// Answer of `/prices/resolve` for one line.
class ResolvedPrice {
  const ResolvedPrice({
    required this.itemId,
    required this.rate,
    this.discountPct = 0,
    this.source = 'item',
    this.priceListName,
    this.freeQty = 0,
    this.freeItemId,
  });

  factory ResolvedPrice.fromJson(Json j) => ResolvedPrice(
    itemId: asString(j['itemId']),
    rate: asDouble(j['rate']),
    discountPct: asDouble(j['discountPct']),
    source: asString(j['source'], 'item'),
    priceListName: asStringOrNull(j['priceListName']),
    freeQty: asDouble(j['freeQty']),
    freeItemId: asStringOrNull(j['freeItemId']),
  );

  final String itemId;
  final double rate;
  final double discountPct;
  final String source;
  final String? priceListName;
  final double freeQty;
  final String? freeItemId;
}
