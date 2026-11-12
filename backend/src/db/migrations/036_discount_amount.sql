-- A fixed-amount discount on a restaurant bill is kept as typed, so the printed bill and the invoice show the same paise.
alter table restaurant_orders add column if not exists discount_amount numeric(14,2) check (discount_amount is null or discount_amount > 0);
