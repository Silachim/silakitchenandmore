-- READ ONLY. Run ONLY against isolated Sila STAGING after BOTH migrations.
-- Checks structural readiness; this does not replace functional/API tests.
WITH required_functions(name,signature,anon_allowed,authenticated_allowed) AS (
 VALUES
  ('submit_customer_order_v2','public.submit_customer_order_v2(text,text,text,date,text,text,text,jsonb,jsonb)',true,true),
  ('get_order_status_v2','public.get_order_status_v2(text,text)',true,true),
  ('submit_payment_v2','public.submit_payment_v2(text,numeric,text,text,text)',true,true),
  ('verify_payment_v2','public.verify_payment_v2(uuid,text)',false,true),
  ('reject_payment_v2','public.reject_payment_v2(uuid,text)',false,true),
  ('set_order_fulfillment','public.set_order_fulfillment(uuid,text,text)',false,true),
  ('set_order_delivery_fee','public.set_order_delivery_fee(uuid,numeric)',false,true),
  ('approve_order_for_payment','public.approve_order_for_payment(uuid,integer)',false,true),
  ('decline_order_request','public.decline_order_request(uuid,text)',false,true),
  ('get_order_payment_summary','public.get_order_payment_summary(uuid)',false,true),
  ('get_order_review_history','public.get_order_review_history(uuid)',false,true)
),
fn_report AS (
 SELECT r.name, r.signature,
  to_regprocedure(r.signature) IS NOT NULL AS exists,
  CASE WHEN to_regprocedure(r.signature) IS NOT NULL
   THEN has_function_privilege('anon',to_regprocedure(r.signature),'EXECUTE')
   ELSE NULL END AS anonymous_execute,
  CASE WHEN to_regprocedure(r.signature) IS NOT NULL
   THEN has_function_privilege('authenticated',to_regprocedure(r.signature),'EXECUTE')
   ELSE NULL END AS authenticated_execute,
  r.anon_allowed AS expected_anonymous_execute,
  r.authenticated_allowed AS expected_authenticated_execute
 FROM required_functions r
),
cols AS (
 SELECT a.column_name, c.column_name IS NOT NULL AS present
 FROM (VALUES ('fulfillment_method'),('delivery_address'),('delivery_landmark'),
  ('delivery_instructions'),('recipient_name'),('recipient_phone'),
  ('is_surprise_order'),('delivery_fee'),('payment_due_at')) a(column_name)
 LEFT JOIN information_schema.columns c ON c.table_schema='public'
  AND c.table_name='orders' AND c.column_name=a.column_name
),
policies AS (
 SELECT policyname,schemaname,tablename,cmd
 FROM pg_policies WHERE
 (schemaname='public' AND tablename='payments'
  AND policyname='Sila active admins can view payments')
 OR
 (schemaname='storage' AND tablename='objects'
  AND policyname IN (
    'Sila customers can upload pending payment receipts',
    'Sila active admins can view payment receipts'))
),
bucket AS (
 SELECT name,public,file_size_limit,allowed_mime_types
 FROM storage.buckets WHERE id='payment-receipts'
)
SELECT jsonb_pretty(jsonb_build_object(
 'functions',(SELECT jsonb_agg(to_jsonb(f) ORDER BY name) FROM fn_report f),
 'added_orders_columns',(SELECT jsonb_agg(to_jsonb(c) ORDER BY column_name) FROM cols c),
 'policies',(SELECT coalesce(jsonb_agg(to_jsonb(p)),'[]'::jsonb) FROM policies p),
 'receipt_bucket',(SELECT coalesce(jsonb_agg(to_jsonb(b)),'[]'::jsonb) FROM bucket b),
 'legacy_admin_functions_restricted',(
 SELECT bool_and(
  NOT has_function_privilege('anon',p.oid,'EXECUTE')
  AND NOT has_function_privilege('authenticated',p.oid,'EXECUTE'))
 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='public' AND p.proname IN('verify_payment','reject_payment')
 ),
 'is_staging_only_check',true
)) AS staging_post_migration_report;
