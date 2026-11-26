-- Sila's Kitchen and More
-- DRAFT: secure prepayment order-decline RPC.
-- DO NOT APPLY TO PRODUCTION UNTIL PRE-FLIGHT CHECKS AND TESTS PASS.
--
-- Pre-flight (read only):
-- SELECT tgname, pg_get_triggerdef(oid)
-- FROM pg_trigger
-- WHERE tgrelid IN ('public.orders'::regclass,
--                   'public.order_status_history'::regclass)
--   AND NOT tgisinternal;
-- Confirm whether an orders trigger already writes to order_status_history.
-- If so, remove the explicit history INSERT below to avoid duplicate entries.
--
-- SELECT proname, pg_get_functiondef(p.oid)
-- FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
-- WHERE n.nspname='public'
--   AND proname IN ('approve_order_for_payment', 'generate_payment_code');
-- Confirm these functions reject cancelled orders before production rollout.
--
-- This function rejects ANY existing payment row for the order, regardless of
-- payment_status. That is intentionally conservative: no decline after any
-- payment activity until a separate cancellation/refund process is designed.
-- Keep this deployment in one transaction so function permissions are atomic.

BEGIN;

CREATE FUNCTION public.decline_order_request(
  p_order_id uuid,
  p_reason text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_admin uuid := auth.uid();
  v_status text;
  v_reason text := btrim(p_reason);
BEGIN
  IF v_admin IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.admin_users a
    WHERE a.user_id=v_admin AND a.is_active IS TRUE
  ) THEN
    RAISE EXCEPTION 'Not authorized to decline orders';
  END IF;

  IF p_order_id IS NULL OR v_reason IS NULL OR
     length(v_reason) < 5 OR length(v_reason) > 1000 THEN
    RAISE EXCEPTION 'A decline reason of 5 to 1000 characters is required';
  END IF;

  -- Serializes updates to this order while the payment check is performed.
  SELECT o.status INTO v_status
  FROM public.orders o WHERE o.id=p_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order not found';
  END IF;

  IF v_status <> 'pending_review' THEN
    RAISE EXCEPTION 'Only pending-review orders may be declined';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.payments p WHERE p.order_id=p_order_id
  ) THEN
    RAISE EXCEPTION 'Order has payment activity; use manual review';
  END IF;

  UPDATE public.orders
  SET status='cancelled', updated_at=now()
  WHERE id=p_order_id AND status='pending_review';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order status changed; decline was not saved';
  END IF;

  -- Disable this explicit insert if an existing trigger automatically
  -- creates order_status_history records for status changes.
  INSERT INTO public.order_status_history
    (id, order_id, old_status, new_status, note, changed_by, created_at)
  VALUES
    (gen_random_uuid(), p_order_id, 'pending_review',
     'cancelled', 'Declined by seller: ' || v_reason,
     v_admin::text, now());
END;
$function$;

REVOKE ALL ON FUNCTION public.decline_order_request(uuid,text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.decline_order_request(uuid,text)
  TO authenticated;

COMMIT;

-- Post-deployment verification (read-only):
-- SELECT proname, prosecdef FROM pg_proc
-- WHERE oid = 'public.decline_order_request(uuid,text)'::regprocedure;
-- SELECT has_function_privilege('anon',
--    'public.decline_order_request(uuid,text)', 'EXECUTE') AS anon_exec,
--   has_function_privilege('authenticated',
--    'public.decline_order_request(uuid,text)', 'EXECUTE') AS auth_exec;
--
-- Test in a nonproduction project: unauthenticated, nonadmin, paid order,
-- already-cancelled order, invalid reason, and one pending/unpaid test order.
-- Confirm history recorded once and no payment code issued.
