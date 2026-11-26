-- SECURITY HOTFIX: immediately restrict privileged legacy payment functions.
-- Run only after verifying these signatures match your Supabase functions.
-- The existing approval RPC was already restricted separately.
-- This operation does not change orders or payment rows.
BEGIN;
REVOKE ALL ON FUNCTION public.verify_payment(uuid,text)
  FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.reject_payment(uuid,text)
  FROM PUBLIC,anon,authenticated;
COMMIT;

-- Read-only verification. Both privileges should be false for both functions.
SELECT p.proname,
  has_function_privilege('anon',p.oid,'EXECUTE') AS anon_execute,
  has_function_privilege('authenticated',p.oid,'EXECUTE') AS authenticated_execute
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public'
  AND p.proname IN ('verify_payment','reject_payment');
