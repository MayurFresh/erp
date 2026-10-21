import '../../core/json.dart';

const List<String> itemUnits = [
  'pcs',
  'kg',
  'g',
  'ltr',
  'm',
  'sqft',
  'bag',
  'box',
  'ton',
  'nos',
];

const List<double> gstRates = [0, 0.25, 3, 5, 12, 18, 28, 40];

class Item {
  const Item({
    required this.id,
    required this.companyId,
    required this.name,
    required this.unit,
    required this.gstRate,
    required this.salePrice,
    this.sku,
    this.hsnCode,
    this.purchasePrice,
    this.trackStock = true,
    this.reorderLevel = 0,
    this.isActive = true,
    this.createdAt,
    this.updatedAt,
  });

  factory Item.fromJson(Json json) => Item(
    id: asString(json['id']),
    companyId: asString(json['companyId']),
    name: asString(json['name']),
    sku: asStringOrNull(json['sku']),
    hsnCode: asStringOrNull(json['hsnCode']),
    unit: asString(json['unit']),
    gstRate: asDouble(json['gstRate']),
    salePrice: asDouble(json['salePrice']),
    purchasePrice: asDoubleOrNull(json['purchasePrice']),
    trackStock: asBool(json['trackStock'], true),
    reorderLevel: asDouble(json['reorderLevel']),
    isActive: asBool(json['isActive'], true),
    createdAt: asDateTimeOrNull(json['createdAt']),
    updatedAt: asDateTimeOrNull(json['updatedAt']),
  );

  final String id;
  final String companyId;
  final String name;
  final String? sku;
  final String? hsnCode;
  final String unit;
  final double gstRate;
  final double salePrice;

  /// Absent from responses without `items.view_cost`.
  final double? purchasePrice;
  final bool trackStock;
  final double reorderLevel;
  final bool isActive;
  final DateTime? createdAt;
  final DateTime? updatedAt;
}

/// Editable fields of an item (create and PATCH bodies).
class ItemInput {
  const ItemInput({
    required this.name,
    required this.unit,
    required this.gstRate,
    required this.salePrice,
    this.sku,
    this.hsnCode,
    this.purchasePrice,
    this.trackStock = true,
    this.reorderLevel = 0,
    this.isActive = true,
  });

  factory ItemInput.fromItem(Item item) => ItemInput(
    name: item.name,
    sku: item.sku,
    hsnCode: item.hsnCode,
    unit: item.unit,
    gstRate: item.gstRate,
    salePrice: item.salePrice,
    purchasePrice: item.purchasePrice,
    trackStock: item.trackStock,
    reorderLevel: item.reorderLevel,
    isActive: item.isActive,
  );

  final String name;
  final String? sku;
  final String? hsnCode;
  final String unit;
  final double gstRate;
  final double salePrice;
  final double? purchasePrice;
  final bool trackStock;
  final double reorderLevel;
  final bool isActive;

  /// [includeCost] adds `purchasePrice` (only with `items.view_cost`);
  /// [includeActive] adds `isActive` (PATCH only).
  Json toJson({required bool includeCost, bool includeActive = false}) => {
    'name': name,
    'sku': sku,
    'hsnCode': hsnCode,
    'unit': unit,
    'gstRate': gstRate,
    'salePrice': salePrice,
    if (includeCost) 'purchasePrice': purchasePrice,
    'trackStock': trackStock,
    'reorderLevel': reorderLevel,
    if (includeActive) 'isActive': isActive,
  };
}
