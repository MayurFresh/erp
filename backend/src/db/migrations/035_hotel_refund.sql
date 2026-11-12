-- A refund of an advance on cancel or no-show is a folio payment of kind 'refund'.
alter table hotel_folio_payments drop constraint if exists hotel_folio_payments_kind_check;
alter table hotel_folio_payments add constraint hotel_folio_payments_kind_check check (kind in ('advance','payment','refund'));
