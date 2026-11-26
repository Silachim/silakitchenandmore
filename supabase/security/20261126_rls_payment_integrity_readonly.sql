-- READ ONLY: RLS/privilege and payment-integrity release gate.
-- Aggregated counts and schema metadata only, no customer names or order codes.
WITH policy_rows AS (
 SELECT schemaname,tablename,policyname,roles,cmd,qual,with_check
 FROM pg_policies
 WHERE schemaname='public' AND tablename IN
  ('admin_users','orders','order_items','payments','payment_receipts','order_status_history')
),
table_grants AS (
 SELECT table_name,grantee,privilege_type
 FROM information_schema.role_table_grants
 WHERE table_schema='public' AND table_name IN
  ('admin_users','orders','order_items','payments','payment_receipts','order_status_history')
 AND grantee IN ('anon','authenticated','PUBLIC')
),
payment_duplicates AS (
 SELECT
   (SELECT count(*) FROM (SELECT payment_code FROM public.payments
    GROUP BY payment_code HAVING count(*)>1) t) AS duplicated_payment_codes,
   (SELECT count(*) FROM (SELECT order_id FROM public.payments
    GROUP BY order_id HAVING count(*)>1) t) AS orders_with_multiple_payment_rows,
   (SELECT count(*) FROM public.payments WHERE order_id IS NULL) AS orphaned_null_order_ids,
   (SELECT count(*) FROM public.payments p LEFT JOIN public.orders o ON o.id=p.order_id
      WHERE o.id IS NULL) AS payment_rows_without_orders,
   (SELECT count(*) FROM public.orders
      WHERE status='cancelled' AND confirmation_code IS NOT NULL) AS cancelled_orders_with_codes
),
function_owners AS (
 SELECT p.proname,pg_get_function_identity_arguments(p.oid) AS arguments,
    pg_get_userbyid(p.proowner) AS owner,
    p.prosecdef AS security_definer,
    p.proconfig AS function_settings
 FROM pg_proc p JOIN pg_namespace n ON p.pronamespace=n.oid
 WHERE n.nspname='public' AND p.proname IN (
   'submit_customer_order','approve_order_for_payment','submit_payment',
   'verify_payment','reject_payment','get_order_status')
),
receipt_buckets AS (
 SELECT id,name,public,file_size_limit,allowed_mime_types
 FROM storage.buckets WHERE id IN ('payment-receipts','receipts','receipt-uploads')
)
SELECT jsonb_pretty(jsonb_build_object(
 'policies',(SELECT coalesce(jsonb_agg(to_jsonb(p)),'[]'::jsonb) FROM policy_rows p),
 'api_table_grants',(SELECT coalesce(jsonb_agg(to_jsonb(g)),'[]'::jsonb) FROM table_grants g),
 'payment_integrity',(SELECT to_jsonb(d) FROM payment_duplicates d),
 'definer_owners',(SELECT coalesce(jsonb_agg(to_jsonb(f)),'[]'::jsonb) FROM function_owners f),
 'receipt_buckets',(SELECT coalesce(jsonb_agg(to_jsonb(b)),'[]'::jsonb) FROM receipt_buckets b)
)) AS security_release_report;
