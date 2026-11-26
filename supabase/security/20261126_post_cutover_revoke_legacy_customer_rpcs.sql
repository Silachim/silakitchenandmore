-- POST-CUTOVER ONLY, after the public website is confirmed to use
-- submit_payment_v2 and get_order_status_v2 and no other clients depend
-- on these legacy functions. Do not run before frontend verification.
BEGIN;
REVOKE ALL ON FUNCTION public.submit_payment(text,numeric,text,text,text)
  FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.get_order_status(text,text)
  FROM PUBLIC,anon,authenticated;
COMMIT;

SELECT p.proname,
  has_function_privilege('anon',p.oid,'EXECUTE') AS anon_execute,
  has_function_privilege('authenticated',p.oid,'EXECUTE') AS authenticated_execute
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public'
  AND p.proname IN ('submit_payment','get_order_status');
