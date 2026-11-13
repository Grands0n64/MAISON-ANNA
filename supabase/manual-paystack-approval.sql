-- MAISON ANNA: manual Paystack payment approval
-- Run this once in Supabase SQL Editor. Existing orders and payment methods are preserved.

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS approved_amount_ngn numeric(14,2);

CREATE OR REPLACE FUNCTION public.ma_create_manual_payment_order(p_order jsonb)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  new_id uuid;
  payload jsonb;
  insert_columns text;
  select_columns text;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Please sign in before placing an order'; END IF;
  IF COALESCE(trim(p_order ->> 'customer_email'),'') = '' THEN RAISE EXCEPTION 'Customer email is required'; END IF;
  payload := jsonb_build_object(
    'customer_name', p_order ->> 'customer_name',
    'customer_email', p_order ->> 'customer_email',
    'email', p_order ->> 'customer_email',
    'customer_phone', p_order ->> 'customer_phone',
    'phone', p_order ->> 'customer_phone',
    'country', p_order ->> 'country',
    'state', p_order ->> 'state',
    'city', p_order ->> 'city',
    'delivery_address', p_order ->> 'delivery_address',
    'postal_code', p_order ->> 'postal_code',
    'cart_items', COALESCE(p_order -> 'cart_items', '[]'::jsonb),
    'items', COALESCE(p_order -> 'cart_items', '[]'::jsonb),
    'total_amount', (p_order ->> 'total_amount')::numeric,
    'currency', 'USD',
    'payment_method', 'paystack_manual',
    'payment_network', 'Paystack one-time payment link',
    'payment_status', 'pending',
    'order_status', 'pending',
    'customer_notes', p_order ->> 'customer_notes',
    'updated_at', now()
  );
  SELECT string_agg(format('%I', c.column_name), ', ' ORDER BY c.ordinal_position),
         string_agg(format('(r).%I', c.column_name), ', ' ORDER BY c.ordinal_position)
  INTO insert_columns, select_columns
  FROM information_schema.columns c
  WHERE c.table_schema='public' AND c.table_name='orders'
    AND c.column_name = ANY (ARRAY[
      'customer_name','customer_email','email','customer_phone','phone','country','state','city',
      'delivery_address','postal_code','cart_items','items','total_amount','currency',
      'payment_method','payment_network','payment_status','order_status','customer_notes','updated_at'
    ]);
  IF insert_columns IS NULL THEN RAISE EXCEPTION 'Orders table is missing checkout columns'; END IF;
  EXECUTE format(
    'INSERT INTO public.orders (%s) SELECT %s FROM jsonb_populate_record(NULL::public.orders, $1) AS r RETURNING id',
    insert_columns, select_columns
  ) USING payload INTO new_id;
  RETURN new_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.ma_admin_set_paystack_amount(p_order_id uuid, p_amount_ngn numeric)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.ma_is_admin() THEN RAISE EXCEPTION 'Admin access required'; END IF;
  IF p_amount_ngn IS NULL OR p_amount_ngn <= 0 THEN RAISE EXCEPTION 'Enter a valid amount in NGN'; END IF;
  UPDATE public.orders
  SET approved_amount_ngn = round(p_amount_ngn,2), updated_at=now()
  WHERE id=p_order_id AND payment_method='paystack_manual';
  IF NOT FOUND THEN RAISE EXCEPTION 'Paystack order not found'; END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.ma_create_manual_payment_order(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ma_create_manual_payment_order(jsonb) TO authenticated;
REVOKE ALL ON FUNCTION public.ma_admin_set_paystack_amount(uuid,numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ma_admin_set_paystack_amount(uuid,numeric) TO authenticated;
