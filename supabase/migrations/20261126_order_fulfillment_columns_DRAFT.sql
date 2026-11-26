-- DRAFT / REVIEW ONLY: Sila order fulfillment data model.
-- Not applied to Supabase. Apply only after a backup and coordinated
-- checkout/RPC/admin deployment have been tested on a staging project.
--
-- Existing orders remain valid; no data is deleted or rewritten.
-- Old free-text notes remain authoritative for historical orders.
BEGIN;
ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS fulfillment_method text,
  ADD COLUMN IF NOT EXISTS delivery_address text,
  ADD COLUMN IF NOT EXISTS delivery_landmark text,
  ADD COLUMN IF NOT EXISTS delivery_instructions text,
  ADD COLUMN IF NOT EXISTS recipient_name text,
  ADD COLUMN IF NOT EXISTS recipient_phone text,
  ADD COLUMN IF NOT EXISTS is_surprise_order boolean,
  ADD COLUMN IF NOT EXISTS delivery_fee numeric(12,2);
-- No default delivery fee is assumed: NULL means not yet quoted.
-- Pickup fees and order totals must be handled by an admin-only quote flow.
-- NOTE: do not change amount_due here. Its original meaning is
-- required product payment based on payment_percent.
ALTER TABLE public.orders
  ADD CONSTRAINT orders_fulfillment_method_check
  CHECK (fulfillment_method IS NULL OR fulfillment_method IN ('delivery','pickup'));
ALTER TABLE public.orders
  ADD CONSTRAINT orders_delivery_fee_nonnegative_check
  CHECK (delivery_fee IS NULL OR delivery_fee >= 0);
COMMIT;

-- Migration design notes:
-- 1. Do not execute unchanged on a database where either named constraint
--    already exists. Inspect pg_constraint first.
-- 2. Existing submit_customer_order takes p_delivery_address and appends it
--    to orders.notes, without a dedicated column.
-- 3. A subsequent compatible RPC revision should populate these columns
--    and avoid duplicating the delivery address in notes. Never silently
--    parse arbitrary free-text customer notes as trusted structured data.
-- 4. Add separate buyer/recipient fields to the customer submission contract
--    through a carefully versioned function, not positional assumptions.
-- 5. Existing orders may retain NULLs; do not fabricate historical data.
-- 6. Do not expose recipient and delivery PII through public RLS policies.
