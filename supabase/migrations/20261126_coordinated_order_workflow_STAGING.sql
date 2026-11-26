-- Sila's Kitchen and More: coordinated checkout, fulfillment, approval and decline.
-- REVIEW / STAGING ONLY. Not applied to production by this GitHub commit.
-- Apply atomically after backing up and validating table/RLS permissions.
-- Requires existing tables: orders, order_items, payments, admin_users,
-- order_status_history; status check supports 'cancelled', 'awaiting_payment'.
BEGIN;

-- Additive, non-destructive. Existing orders retain NULL in new columns.
ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS fulfillment_method text,
  ADD COLUMN IF NOT EXISTS delivery_address text,
  ADD COLUMN IF NOT EXISTS delivery_landmark text,
  ADD COLUMN IF NOT EXISTS delivery_instructions text,
  ADD COLUMN IF NOT EXISTS recipient_name text,
  ADD COLUMN IF NOT EXISTS recipient_phone text,
  ADD COLUMN IF NOT EXISTS is_surprise_order boolean,
  ADD COLUMN IF NOT EXISTS delivery_fee numeric(12,2),
  ADD COLUMN IF NOT EXISTS payment_due_at timestamptz;

DO $block$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
    WHERE conrelid='public.orders'::regclass AND conname='orders_fulfillment_method_check') THEN
    ALTER TABLE public.orders ADD CONSTRAINT orders_fulfillment_method_check
      CHECK (fulfillment_method IS NULL OR fulfillment_method IN ('delivery','pickup'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
    WHERE conrelid='public.orders'::regclass AND conname='orders_delivery_fee_nonnegative_check') THEN
    ALTER TABLE public.orders ADD CONSTRAINT orders_delivery_fee_nonnegative_check
      CHECK (delivery_fee IS NULL OR delivery_fee >= 0);
  END IF;
END $block$;

-- A versioned checkout RPC leaves the existing 8-argument endpoint untouched.
-- It accepts structured fulfillment and no longer duplicates the address
-- within free-text notes. Existing checkout clients continue to work.
CREATE OR REPLACE FUNCTION public.submit_customer_order_v2(
  p_customer_name text,
  p_customer_phone text,
  p_customer_email text,
  p_desired_date date,
  p_delivery_address text,
  p_event_type text,
  p_customer_notes text,
  p_items jsonb,
  p_fulfillment jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_id uuid;
  v_code text;
  v_total numeric(12,2) := 0;
  v_percent numeric(5,2);
  v_type text;
  v_item jsonb;
  v_name text;
  v_qty integer;
  v_price numeric(12,2);
  v_method text := p_fulfillment->>'method';
  v_address text := nullif(btrim(coalesce(p_fulfillment->>'delivery_address',p_delivery_address,'')),'');
  v_recipient text := nullif(btrim(coalesce(p_fulfillment->>'recipient_name','')),'');
  v_recipient_phone text := nullif(btrim(coalesce(p_fulfillment->>'recipient_phone','')),'');
  v_surprise boolean := coalesce((p_fulfillment->>'is_surprise_order')::boolean,false);
  v_note text := nullif(btrim(coalesce(p_customer_notes,'')),'');
BEGIN
  IF nullif(btrim(coalesce(p_customer_name,'')),'') IS NULL OR
     nullif(btrim(coalesce(p_customer_phone,'')),'') IS NULL THEN
    RAISE EXCEPTION 'Buyer name and phone are required';
  END IF;
  IF length(p_customer_name)>160 OR length(p_customer_phone)>40 THEN
    RAISE EXCEPTION 'Buyer contact information is too long';
  END IF;
  IF p_desired_date IS NULL OR p_desired_date < current_date+4 THEN
    RAISE EXCEPTION 'Orders require at least 4 days advance notice';
  END IF;
  IF p_fulfillment IS NULL OR jsonb_typeof(p_fulfillment)<>'object' OR
     (v_method IS NULL OR v_method NOT IN ('delivery','pickup')) THEN
    RAISE EXCEPTION 'Select delivery or pickup';
  END IF;
  IF v_method='delivery' AND v_address IS NULL THEN
    RAISE EXCEPTION 'Delivery address is required';
  END IF;
  IF v_method='pickup' THEN v_address := NULL; END IF;
  IF v_recipient IS NULL THEN v_surprise := false; END IF;
  IF (v_recipient IS NULL) <> (v_recipient_phone IS NULL) THEN
    RAISE EXCEPTION 'Recipient name and phone must be provided together';
  END IF;
  IF length(coalesce(v_address,''))>800 OR
     length(coalesce(v_recipient,''))>160 OR
     length(coalesce(v_recipient_phone,''))>40 OR
     length(coalesce(p_fulfillment->>'delivery_landmark',''))>200 OR
     length(coalesce(p_fulfillment->>'delivery_instructions',''))>500 OR
     length(coalesce(v_note,''))>2000 THEN
    RAISE EXCEPTION 'Order detail exceeds maximum allowed length';
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items)<>'array' OR
     jsonb_array_length(p_items)=0 OR jsonb_array_length(p_items)>100 THEN
    RAISE EXCEPTION 'Cart must contain between 1 and 100 items';
  END IF;

  -- Preserve these legacy optional inputs without conflating them with address.
  IF nullif(btrim(coalesce(p_customer_email,'')),'') IS NOT NULL THEN
    v_note := concat_ws(E'\n',v_note,'Customer email: '||btrim(p_customer_email));
  END IF;
  IF nullif(btrim(coalesce(p_event_type,'')),'') IS NOT NULL THEN
    v_note := concat_ws(E'\n',v_note,'Event type: '||btrim(p_event_type));
  END IF;

  v_code := 'SILA-'||to_char(current_date,'YYYYMMDD')||'-'||
    upper(substr(replace(gen_random_uuid()::text,'-',''),1,6));
  INSERT INTO public.orders
    (order_code,customer_name,customer_phone,desired_date,notes,
     payment_type,payment_percent,amount_due,status,fulfillment_method,
     delivery_address,delivery_landmark,delivery_instructions,
     recipient_name,recipient_phone,is_surprise_order,delivery_fee)
  VALUES
    (v_code,btrim(p_customer_name),btrim(p_customer_phone),p_desired_date,v_note,
     'full',100,0,'pending_review',v_method,v_address,
     nullif(btrim(coalesce(p_fulfillment->>'delivery_landmark','')),''),
     nullif(btrim(coalesce(p_fulfillment->>'delivery_instructions','')),''),
     v_recipient,v_recipient_phone,v_surprise,
     CASE WHEN v_method='pickup' THEN 0 ELSE NULL END)
  RETURNING id INTO v_id;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    v_name := coalesce(nullif(btrim(v_item->>'item_name'),''),
                       nullif(btrim(v_item->>'name'),''),
                       nullif(btrim(v_item->>'product_name'),''));
    IF v_name IS NULL OR length(v_name)>300 THEN
      RAISE EXCEPTION 'Each item requires a valid name';
    END IF;
    v_qty := coalesce((v_item->>'quantity')::integer,1);
    v_price := coalesce((v_item->>'unit_price')::numeric,0);
    IF v_qty<1 OR v_qty>1000 OR v_price<0 OR v_price>100000000 THEN
      RAISE EXCEPTION 'Invalid item quantity or price';
    END IF;
    INSERT INTO public.order_items
      (order_id,item_name,quantity,unit_price,line_total,metadata)
    VALUES (v_id,v_name,v_qty,v_price,round(v_qty*v_price,2),
            coalesce(v_item->'metadata','{}'::jsonb));
    v_total := v_total+round(v_qty*v_price,2);
  END LOOP;
  v_type := CASE WHEN v_total>50000 THEN 'deposit' ELSE 'full' END;
  v_percent := CASE WHEN v_total>50000 THEN 85 ELSE 100 END;
  UPDATE public.orders SET subtotal=v_total,payment_type=v_type,
    payment_percent=v_percent,
    amount_due=round(v_total*v_percent/100,2)
  WHERE id=v_id;
  INSERT INTO public.order_status_history
    (order_id,old_status,new_status,note,changed_by)
  VALUES (v_id,NULL,'pending_review',
    'Customer submitted order request through the website.','customer');
  RETURN jsonb_build_object(
    'success',true,'order_id',v_id,'order_code',v_code,'order_number',v_code,
    'subtotal',v_total,'total_amount',v_total,'payment_type',v_type,
    'payment_percent',v_percent,
    'amount_due',round(v_total*v_percent/100,2),
    'delivery_fee_status',CASE WHEN v_method='delivery' THEN 'pending_quote' ELSE 'not_required' END,
    'status','pending_review');
END;
$function$;

REVOKE ALL ON FUNCTION public.submit_customer_order_v2(
  text,text,text,date,text,text,text,jsonb,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.submit_customer_order_v2(
  text,text,text,date,text,text,text,jsonb,jsonb) TO anon,authenticated;

-- Legacy pending orders can be classified explicitly by an active seller.
-- Existing notes are preserved; address must be confirmed before delivery.
CREATE OR REPLACE FUNCTION public.set_order_fulfillment(
  p_order_id uuid,p_method text,p_address text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $function$
DECLARE v_order public.orders%rowtype;
  v_address text := nullif(btrim(coalesce(p_address,'')),'');
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.admin_users
    WHERE user_id=auth.uid() AND is_active IS TRUE
  ) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_method IS NULL OR p_method NOT IN ('delivery','pickup') THEN
    RAISE EXCEPTION 'Select delivery or pickup';
  END IF;
  IF p_method='delivery' AND v_address IS NULL THEN
    RAISE EXCEPTION 'Confirm the delivery address first';
  END IF;
  IF length(coalesce(v_address,''))>800 THEN
    RAISE EXCEPTION 'Delivery address exceeds maximum length';
  END IF;
  SELECT * INTO v_order FROM public.orders WHERE id=p_order_id FOR UPDATE;
  IF NOT FOUND OR v_order.status<>'pending_review' THEN
    RAISE EXCEPTION 'Only pending-review orders may be classified';
  END IF;
  IF EXISTS (SELECT 1 FROM public.payments WHERE order_id=p_order_id) THEN
    RAISE EXCEPTION 'Order has payment activity';
  END IF;
  IF v_order.fulfillment_method IS NOT NULL THEN
    RAISE EXCEPTION 'Fulfillment already selected; use a separate change-review process';
  END IF;
  UPDATE public.orders
  SET fulfillment_method=p_method,
    delivery_address=CASE WHEN p_method='delivery' THEN v_address ELSE NULL END,
    delivery_fee=CASE WHEN p_method='pickup' THEN 0 ELSE NULL END
  WHERE id=p_order_id;
  INSERT INTO public.order_status_history
    (order_id,old_status,new_status,note,changed_by)
  VALUES (p_order_id,'pending_review','pending_review',
    'Seller confirmed legacy fulfillment: '||p_method||
    CASE WHEN p_method='delivery' THEN '; address: '||v_address ELSE '' END,
    auth.uid()::text);
  RETURN jsonb_build_object('success',true,'fulfillment_method',p_method);
END;
$function$;
REVOKE ALL ON FUNCTION public.set_order_fulfillment(uuid,text,text)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.set_order_fulfillment(uuid,text,text)
  TO authenticated;

-- Phone-and-order-code-scoped customer status endpoint. This avoids relying
-- on the legacy function, whose implementation must be reviewed separately.
CREATE OR REPLACE FUNCTION public.get_order_status_v2(
  p_order_number text,p_customer_phone text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $function$
DECLARE v_order public.orders%rowtype; v_payment_status text; v_paid numeric;
BEGIN
  IF nullif(btrim(coalesce(p_order_number,'')),'') IS NULL OR
     nullif(btrim(coalesce(p_customer_phone,'')),'') IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT * INTO v_order FROM public.orders
  WHERE order_code=btrim(p_order_number)
    AND regexp_replace(customer_phone,'\D','','g') =
        regexp_replace(btrim(p_customer_phone),'\D','','g');
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT p.payment_status::text,p.amount_paid
    INTO v_payment_status,v_paid
  FROM public.payments p WHERE p.order_id=v_order.id
  ORDER BY p.created_at DESC LIMIT 1;
  RETURN jsonb_build_object(
    'order_code',v_order.order_code,'order_number',v_order.order_code,
    'status',v_order.status,
    'payment_status',coalesce(v_payment_status,'not_required'),
    'payment_code',CASE WHEN v_order.status IN
       ('awaiting_payment','payment_submitted','payment_verified','confirmed',
        'preparing','ready','completed')
       THEN v_order.confirmation_code ELSE NULL END,
    'amount_due',CASE WHEN v_order.status IN ('awaiting_payment','payment_submitted')
      THEN v_order.amount_due ELSE NULL END,
    'payment_percent',v_order.payment_percent,
    'delivery_fee',v_order.delivery_fee,
    'delivery_fee_status',CASE WHEN v_order.fulfillment_method='delivery' AND
       v_order.delivery_fee IS NULL THEN 'pending_quote' ELSE 'confirmed' END,
    'amount_paid',CASE WHEN v_payment_status='verified' THEN v_paid ELSE NULL END,
    'payment_due_at',v_order.payment_due_at
  );
END;
$function$;
REVOKE ALL ON FUNCTION public.get_order_status_v2(text,text)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.get_order_status_v2(text,text)
  TO anon,authenticated;

-- Active admins may quote (or revise) fees only on unapproved unpaid orders.
CREATE OR REPLACE FUNCTION public.set_order_delivery_fee(
  p_order_id uuid, p_delivery_fee numeric
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $function$
DECLARE v_order public.orders%rowtype; v_due numeric(12,2);
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS(
    SELECT 1 FROM public.admin_users
    WHERE user_id=auth.uid() AND is_active IS TRUE) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF p_delivery_fee IS NULL OR p_delivery_fee<0 OR p_delivery_fee>100000000 THEN
    RAISE EXCEPTION 'A nonnegative delivery fee is required';
  END IF;
  SELECT * INTO v_order FROM public.orders WHERE id=p_order_id FOR UPDATE;
  IF NOT FOUND OR v_order.status<>'pending_review' THEN
    RAISE EXCEPTION 'Only pending-review orders can be quoted';
  END IF;
  IF EXISTS (SELECT 1 FROM public.payments WHERE order_id=p_order_id) THEN
    RAISE EXCEPTION 'Order has payment activity and cannot be repriced';
  END IF;
  IF v_order.fulfillment_method='pickup' AND p_delivery_fee<>0 THEN
    RAISE EXCEPTION 'Pickup has no delivery fee';
  END IF;
  IF v_order.fulfillment_method IS NULL AND p_delivery_fee<>0 THEN
    RAISE EXCEPTION 'Legacy order: verify fulfillment before setting a fee';
  END IF;
  v_due := round(v_order.subtotal*v_order.payment_percent/100,2)+p_delivery_fee;
  UPDATE public.orders SET delivery_fee=p_delivery_fee,amount_due=v_due
  WHERE id=p_order_id;
  INSERT INTO public.order_status_history
    (order_id,old_status,new_status,note,changed_by)
  VALUES (p_order_id,'pending_review','pending_review',
    'Seller confirmed delivery fee: '||p_delivery_fee::text,
    auth.uid()::text);
  RETURN jsonb_build_object('success',true,'delivery_fee',p_delivery_fee,
    'amount_due',v_due);
END;
$function$;
REVOKE ALL ON FUNCTION public.set_order_delivery_fee(uuid,numeric)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.set_order_delivery_fee(uuid,numeric)
  TO authenticated;

-- Replace the vulnerable legacy implementation while keeping its signature
-- and its existing public grant revoked for anon (separately verified by user).
CREATE OR REPLACE FUNCTION public.approve_order_for_payment(
  p_order_id uuid,p_payment_due_hours integer DEFAULT 24
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $function$
DECLARE
  v_order public.orders%rowtype;
  v_code text;
  v_payment_id uuid;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.admin_users
    WHERE user_id=auth.uid() AND is_active IS TRUE) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF p_payment_due_hours IS NULL OR
     p_payment_due_hours<1 OR p_payment_due_hours>720 THEN
    RAISE EXCEPTION 'Payment due hours must be from 1 to 720';
  END IF;
  SELECT * INTO v_order FROM public.orders WHERE id=p_order_id FOR UPDATE;
  IF NOT FOUND OR v_order.status<>'pending_review' THEN
    RAISE EXCEPTION 'Only pending-review orders can be approved';
  END IF;
  IF v_order.fulfillment_method IS NULL THEN
    RAISE EXCEPTION 'Confirm pickup or delivery before approval';
  END IF;
  IF v_order.fulfillment_method='delivery' AND
     v_order.delivery_fee IS NULL THEN
    RAISE EXCEPTION 'Confirm the delivery fee before approval';
  END IF;
  IF EXISTS (SELECT 1 FROM public.payments WHERE order_id=p_order_id) THEN
    RAISE EXCEPTION 'Payment already exists for this order';
  END IF;
  v_code := public.generate_payment_code();
  UPDATE public.orders
  SET status='awaiting_payment',confirmation_code=v_code,
      payment_due_at=now()+make_interval(hours=>p_payment_due_hours)
  WHERE id=p_order_id;
  INSERT INTO public.payments
    (order_id,payment_code,amount_expected,payment_status)
  VALUES (p_order_id,v_code,v_order.amount_due,'awaiting_payment')
  RETURNING id INTO v_payment_id;
  INSERT INTO public.order_status_history
    (order_id,old_status,new_status,note,changed_by)
  VALUES (p_order_id,'pending_review','awaiting_payment',
    'Administrator approved the order and generated payment instructions.',
    auth.uid()::text);
  RETURN jsonb_build_object('success',true,'order_code',v_order.order_code,
    'payment_code',v_code,'payment_id',v_payment_id,
    'amount_required',v_order.amount_due,
    'payment_due_at',now()+make_interval(hours=>p_payment_due_hours));
END;
$function$;
REVOKE ALL ON FUNCTION public.approve_order_for_payment(uuid,integer)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.approve_order_for_payment(uuid,integer)
  TO authenticated;

-- No ordinary decline if payment processing has begun.
CREATE OR REPLACE FUNCTION public.decline_order_request(
  p_order_id uuid,p_reason text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $function$
DECLARE v_order public.orders%rowtype; v_reason text := nullif(btrim(p_reason),'');
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS(
    SELECT 1 FROM public.admin_users
    WHERE user_id=auth.uid() AND is_active IS TRUE) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF v_reason IS NULL OR length(v_reason)<5 OR length(v_reason)>1000 THEN
    RAISE EXCEPTION 'Reason must be 5 to 1000 characters';
  END IF;
  SELECT * INTO v_order FROM public.orders WHERE id=p_order_id FOR UPDATE;
  IF NOT FOUND OR v_order.status<>'pending_review' THEN
    RAISE EXCEPTION 'Only pending-review orders may be declined';
  END IF;
  IF EXISTS (SELECT 1 FROM public.payments WHERE order_id=p_order_id) THEN
    RAISE EXCEPTION 'Payment activity exists; manual review is required';
  END IF;
  UPDATE public.orders SET status='cancelled' WHERE id=p_order_id;
  INSERT INTO public.order_status_history
    (order_id,old_status,new_status,note,changed_by)
  VALUES (p_order_id,'pending_review','cancelled',
    'Declined by seller: '||v_reason,auth.uid()::text);
  RETURN jsonb_build_object('success',true,'status','cancelled',
    'order_code',v_order.order_code,'reason',v_reason);
END;
$function$;
REVOKE ALL ON FUNCTION public.decline_order_request(uuid,text)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.decline_order_request(uuid,text)
  TO authenticated;

-- Read-only history endpoint for active administrators; avoids giving general
-- authenticated users direct access to the history table.
CREATE OR REPLACE FUNCTION public.get_order_review_history(p_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $function$
DECLARE v_result jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.admin_users
    WHERE user_id=auth.uid() AND is_active IS TRUE
  ) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.orders WHERE id=p_order_id) THEN
    RAISE EXCEPTION 'Order not found';
  END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'old_status',h.old_status,'new_status',h.new_status,'note',h.note,
    'changed_by',h.changed_by,'created_at',h.created_at)
    ORDER BY h.created_at DESC),'[]'::jsonb)
  INTO v_result
  FROM public.order_status_history h WHERE h.order_id=p_order_id;
  RETURN v_result;
END;
$function$;
REVOKE ALL ON FUNCTION public.get_order_review_history(uuid)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.get_order_review_history(uuid)
  TO authenticated;

COMMIT;

-- SECURITY REVIEW CHECKS (READ ONLY)
-- SELECT proname,prosecdef,has_function_privilege('anon',oid,'EXECUTE') anon_exec,
--   has_function_privilege('authenticated',oid,'EXECUTE') auth_exec
-- FROM pg_proc WHERE oid IN (
--  'public.approve_order_for_payment(uuid,integer)'::regprocedure,
--  'public.decline_order_request(uuid,text)'::regprocedure,
--  'public.set_order_delivery_fee(uuid,numeric)'::regprocedure
-- );
-- Test in staging as anon, nonadmin authenticated, admin, and with simultaneous
-- requests. Test pickup, delivery-unquoted, delivery-quoted, paid, and cancelled.
-- Verify payment records and status-history writes are exactly once.
