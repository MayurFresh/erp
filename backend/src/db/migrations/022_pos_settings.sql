-- Counter billing: per-company choice between tax-inclusive (MRP) and tax-exclusive prices.
-- null means "use the default for the business type" (inclusive for the shop types that have the pos module).
alter table companies add column if not exists pos_prices_include_tax boolean;
