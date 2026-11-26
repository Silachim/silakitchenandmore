-- STAGING ONLY: admin Payments SELECT + tightly scoped private receipt uploads.
-- This is a separate coordinated migration, applied after the main workflow SQL.
-- Keep the payment-receipts bucket PRIVATE. Never grant public SELECT.
BEGIN;

DO $policies$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public'
     AND tablename='payments' AND policyname='Sila active admins can view payments') THEN
    CREATE POLICY "Sila active admins can view payments"
      ON public.payments FOR SELECT TO authenticated
      USING (EXISTS (
        SELECT 1 FROM public.admin_users a
        WHERE a.user_id=(SELECT auth.uid()) AND a.is_active IS TRUE
      ));
  END IF;
END $policies$;
GRANT SELECT ON public.payments TO authenticated;

-- No current checkout workflow queries public.payment_receipts directly;
-- all ordinary API grants on this legacy receipt table are unnecessary.
-- RLS already denies access, but revoke privileges for defense in depth.
REVOKE ALL ON TABLE public.payment_receipts FROM anon, authenticated;

-- Customer receipt path must include BOTH the order code and its
-- valid payment code, and only an awaiting-payment order may accept uploads.
-- Storage bucket enforces maximum file size and allowed content types.
CREATE OR REPLACE FUNCTION public.sila_valid_payment_receipt_upload_path(
  p_path text
) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=''
AS $uploadcheck$
  SELECT
    p_path IS NOT NULL AND length(p_path) BETWEEN 30 AND 450
    AND split_part(p_path,'/',1) ~ '^SILA-[0-9]{8}-[A-Z0-9]{6}$'
    AND split_part(p_path,'/',2) ~ '^PAY-[A-F0-9]{8}$'
    AND split_part(p_path,'/',3) ~ '^[0-9a-fA-F-]{36}-[A-Za-z0-9._-]{1,120}$'
    AND split_part(p_path,'/',4)=''
    AND EXISTS (
      SELECT 1 FROM public.orders o
      JOIN public.payments p ON p.order_id=o.id
      WHERE o.order_code=split_part(p_path,'/',1)
        AND o.status='awaiting_payment'
        AND o.confirmation_code=split_part(p_path,'/',2)
        AND p.payment_code=split_part(p_path,'/',2)
        AND p.payment_status='awaiting_payment'
        AND (o.payment_due_at IS NULL OR o.payment_due_at>=now())
    );
$uploadcheck$;
REVOKE ALL ON FUNCTION public.sila_valid_payment_receipt_upload_path(text)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.sila_valid_payment_receipt_upload_path(text)
  TO anon,authenticated;

DO $storagepolicies$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='storage'
    AND tablename='objects'
    AND policyname='Sila customers can upload pending payment receipts') THEN
    CREATE POLICY "Sila customers can upload pending payment receipts"
      ON storage.objects FOR INSERT TO anon,authenticated
      WITH CHECK (
        bucket_id='payment-receipts'
        AND public.sila_valid_payment_receipt_upload_path(name)
      );
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='storage'
    AND tablename='objects'
    AND policyname='Sila active admins can view payment receipts') THEN
    CREATE POLICY "Sila active admins can view payment receipts"
      ON storage.objects FOR SELECT TO authenticated
      USING (
        bucket_id='payment-receipts'
        AND EXISTS (
          SELECT 1 FROM public.admin_users a
          WHERE a.user_id=(SELECT auth.uid()) AND a.is_active IS TRUE
        )
      );
  END IF;
END $storagepolicies$;
COMMIT;

-- Caveat: anyone possessing a valid order/payment code can attempt receipt
-- uploads. Enforce Storage/API rate limits and monitor abuse before rollout.
-- Do not grant UPDATE, DELETE or ordinary customer SELECT on these receipts.
