-- v1.8 commerce foundation: stock move kinds shared by order-to-cash and procure-to-pay.
-- Domain tables live in 013_o2c.sql and 014_p2p.sql.

alter table stock_moves drop constraint stock_moves_ref_type_check;
alter table stock_moves add constraint stock_moves_ref_type_check check (ref_type in (
  'opening','adjustment','invoice','invoice_cancel','purchase','purchase_cancel',
  'credit_note','credit_note_cancel','transfer_out','transfer_in','transfer_cancel','issue','issue_cancel',
  'grn','grn_cancel','stock_count','write_off'));

-- Barcodes (EAN/UPC or the company's own) for scanning at pick, pack, receipt and count.
alter table items add column barcode text check (barcode is null or length(barcode) between 4 and 64);
create unique index items_barcode_uq on items (company_id, barcode) where barcode is not null;
