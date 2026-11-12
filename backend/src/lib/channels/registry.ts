import { GENERIC_ORDER_COLUMNS, GENERIC_SETTLEMENT_ALIASES } from './registry-generic.ts';
import { shopifyConnector } from './shopify.ts';
import type { ChannelCapability, ChannelConnector, ConnectorStage, SettlementKind } from './types.ts';
import { wooConnector } from './woocommerce.ts';

/*
 * Connector registry. No marketplace credentials or network calls exist yet, so every provider works in file-import
 * mode: order and settlement CSV files. A live API client is added later as an adapter that implements ChannelConnector
 * (pullOrders, normaliseOrder, pushStock). Nothing here claims a verified endpoint or report layout.
 * Report column names for Amazon, Flipkart and Meesho: to verify with the marketplace's current docs.
 * Until then those providers use the generic column names below, and each channel can remap them.
 */

export { GENERIC_ORDER_COLUMNS, GENERIC_SETTLEMENT_ALIASES };

const csvOnly: ReadonlySet<ChannelCapability> = new Set(['orders_csv', 'settlements_csv']);

const mk = (id: string, name: string, stage: ConnectorStage): ChannelConnector => ({
  id, version: '1', name, stage, auth: id === 'manual' ? 'none' : 'oauth2', capabilities: csvOnly, credentialFields: [],
  csvColumns: GENERIC_ORDER_COLUMNS, settlementAliases: GENERIC_SETTLEMENT_ALIASES as Record<string, SettlementKind>,
});

export const CONNECTORS: readonly ChannelConnector[] = [
  mk('manual', 'File import (CSV)', 'production_enabled'),
  mk('amazon', 'Amazon', 'access_requested'),
  mk('flipkart', 'Flipkart', 'access_requested'),
  mk('meesho', 'Meesho', 'access_requested'),
  shopifyConnector,
  wooConnector,
  mk('other', 'Other channel', 'production_enabled'),
];

export const connectorById = (id: string) => CONNECTORS.find((c) => c.id === id);

export function connectorJson(c: ChannelConnector) {
  return {
    id: c.id, name: c.name, stage: c.stage, version: c.version, auth: c.auth, capabilities: [...c.capabilities],
    liveApi: c.capabilities.has('orders_pull'), importMode: 'csv',
    credentialFields: c.credentialFields,
    note: c.id === 'manual' || c.id === 'other' ? 'Orders and settlements come from CSV files.'
      : c.capabilities.has('orders_pull') ? 'Orders arrive by webhook and scheduled pull; stock can be pushed. CSV import still works.'
      : 'No live connection yet. Import the channel\'s order and settlement reports as CSV. Report layouts: to verify with the marketplace\'s current docs.',
  };
}
