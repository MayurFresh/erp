import type { OrderCsvField, SettlementKind } from './types.ts';

/** Generic column names of the order file. A channel maps its own headers onto these. */
export const GENERIC_ORDER_COLUMNS: Record<OrderCsvField, string> = {
  orderId: 'order_id', orderDate: 'order_date', sku: 'sku', title: 'title', qty: 'qty', unitPrice: 'unit_price',
  lineTotal: 'line_total', discount: 'discount', buyerName: 'buyer_name', shipState: 'ship_state', status: 'status',
};

/** Settlement labels (lower case) that map to a line kind. Channels add their own in `settlement_aliases`. Check against each report. */
export const GENERIC_SETTLEMENT_ALIASES: Record<string, SettlementKind> = {
  sale: 'sale', sales: 'sale', principal: 'sale', 'item price': 'sale', 'order amount': 'sale',
  refund: 'refund', return: 'refund', 'customer refund': 'refund', chargeback: 'refund',
  commission: 'commission', 'referral fee': 'commission', 'marketplace fee': 'commission',
  fee: 'fee', 'closing fee': 'fee', 'fixed fee': 'fee', 'collection fee': 'fee', 'payment fee': 'fee',
  shipping: 'shipping', 'shipping fee': 'shipping', 'shipping charges': 'shipping', 'weight handling fee': 'shipping',
  'gst on fees': 'gst_on_fees', 'igst on fees': 'gst_on_fees', 'service tax': 'gst_on_fees',
  tcs: 'tcs', 'gst tcs': 'tcs', 'tcs igst': 'tcs', 'tcs cgst': 'tcs', 'tcs sgst': 'tcs',
  tds: 'tds', 'tds 194-o': 'tds', 'income tax tds': 'tds',
  reserve: 'reserve', 'reserve held': 'reserve', 'reserve release': 'reserve_release', 'reserve released': 'reserve_release',
  adjustment: 'adjustment', 'other adjustment': 'adjustment',
};
