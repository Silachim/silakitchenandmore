-- READ ONLY: Sila coordinated checkout migration preflight.
-- Returns one structured result. Contains NO customer rows or secrets.
WITH required_columns(table_name,column_name) AS (
  VALUES
    ('admin_users','user_id'), ('admin_users','is_active'),
    ('orders','id'), ('orders','order_code'), ('orders','status'),
    ('orders','subtotal'), ('orders','payment_percent'),
    ('orders','amount_due'), ('orders','confirmation_code'),
    ('order_items','order_id'), ('order_items','item_name'),
    ('order_items','quantity'), ('order_items','unit_price'),
    ('order_items','line_total'), ('order_items','metadata'),
    ('payments','id'), ('payments','order_id'),
    ('payments','payment_code'), ('payments','amount_expected'),
    ('payments','amount_paid'), ('payments','payment_status'),
    ('payments','payment_method'), ('payments','transaction_reference'),
    ('payments','payment_date'), ('payments','customer_note'),
    ('payments','admin_note'),
    ('order_status_history','order_id'),
    ('order_status_history','old_status'),
    ('order_status_history','new_status'),
    ('order_status_history','note'),
    ('order_status_history','changed_by')
),
missing AS (
  SELECT r.table_name,r.column_name
  FROM required_columns r
  LEFT JOIN information_schema.columns c ON
    c.table_schema='public' AND c.table_name=r.table_name
    AND c.column_name=r.column_name
  WHERE c.column_name IS NULL
),
tables AS (
  SELECT c.relname AS name,c.relrowsecurity AS rls_enabled,
    c.relforcerowsecurity AS force_rls
  FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='public' AND c.relkind IN ('r','p')
    AND c.relname IN ('orders','order_items','payments',
     'admin_users','order_status_history','payment_receipts')
),
functions AS (
  SELECT p.proname AS name,
    pg_get_function_identity_arguments(p.oid) AS arguments,
    p.prosecdef AS security_definer,
    has_function_privilege('anon',p.oid,'EXECUTE') AS anon_execute,
    has_function_privilege('authenticated',p.oid,'EXECUTE') AS authenticated_execute
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname IN
   ('approve_order_for_payment','verify_payment','reject_payment',
    'submit_payment','get_order_status','generate_payment_code',
    'generate_confirmation_code','submit_customer_order')
),
constraints AS (
  SELECT c.conrelid::regclass::text AS table_name,
    c.conname AS name,c.contype AS type,
    pg_get_constraintdef(c.oid) AS definition
  FROM pg_constraint c
  WHERE c.conrelid IN
   ('public.orders'::regclass,'public.payments'::regclass,
    'public.order_items'::regclass,'public.order_status_history'::regclass)
),
triggers AS (
 SELECT t.tgrelid::regclass::text AS table_name,t.tgname AS name,
    pg_get_triggerdef(t.oid) AS definition
 FROM pg_trigger t WHERE NOT t.tgisinternal
    AND t.tgrelid IN ('public.orders'::regclass,'public.payments'::regclass)
)
SELECT jsonb_pretty(jsonb_build_object(
  'missing_required_columns',(SELECT coalesce(jsonb_agg(to_jsonb(m)), '[]'::jsonb) FROM missing m),
  'table_rls',(SELECT coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) FROM tables t),
  'legacy_function_permissions',(SELECT coalesce(jsonb_agg(to_jsonb(f)),'[]'::jsonb) FROM functions f),
  'table_constraints',(SELECT coalesce(jsonb_agg(to_jsonb(c)),'[]'::jsonb) FROM constraints c),
  'triggers',(SELECT coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) FROM triggers t),
  'payment_status_enum',(SELECT coalesce(jsonb_agg(e.enumlabel ORDER BY e.enumsortorder),'[]'::jsonb)
   FROM pg_attribute a JOIN pg_enum e ON e.enumtypid=a.atttypid
   WHERE a.attrelid='public.payments'::regclass AND a.attname='payment_status')
)) AS staging_preflight_report;
