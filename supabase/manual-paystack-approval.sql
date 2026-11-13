-- MAISON ANNA: create the orders table if missing, then enable manual Paystack approval.
-- Run this complete file in Supabase SQL Editor.

CREATE TABLE IF NOT EXISTS public.orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  customer_name text NOT NULL,
  customer_email text,
  customer_phone text,
  country text,
  state text,
  city text,
  delivery_address text,
  postal_code text,
  cart_items jsonb NOT NULL DEFAULT '[]'::jsonb,
  total_amount numeric(14,2) NOT NULL DEFAULT 0,
  currency text NOT NULL DEFAULT 'USD',
  payment_method text,
  transaction_hash text,
  payment_network text,
  customer_notes text,
  payment_status text NOT NULL DEFAULT 'pending',
  order_status text NOT NULL DEFAULT 'pending',
  approved_amount_ngn numeric(14,2)
);

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS customer_email text,
  ADD COLUMN IF NOT EXISTS customer_phone text,
  ADD COLUMN IF NOT EXISTS country text,
  ADD COLUMN IF NOT EXISTS state text,
  ADD COLUMN IF NOT EXISTS city text,
  ADD COLUMN IF NOT EXISTS delivery_address text,
  ADD COLUMN IF NOT EXISTS postal_code text,
  ADD COLUMN IF NOT EXISTS cart_items jsonb DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS total_amount numeric(14,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS currency text DEFAULT 'USD',
  ADD COLUMN IF NOT EXISTS payment_method text,
  ADD COLUMN IF NOT EXISTS transaction_hash text,
  ADD COLUMN IF NOT EXISTS payment_network text,
  ADD COLUMN IF NOT EXISTS customer_notes text,
  ADD COLUMN IF NOT EXISTS payment_status text DEFAULT 'pending',
  ADD COLUMN IF NOT EXISTS order_status text DEFAULT 'pending',
  ADD COLUMN IF NOT EXISTS approved_amount_ngn numeric(14,2),
  ADD COLUMN IF NOT EXISTS updated_at timestamptz DEFAULT now();

CREATE OR REPLACE FUNCTION public.ma_create_manual_payment_order(p_order jsonb)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  new_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Please sign in before placing an order'; END IF;
  IF COALESCE(trim(p_order ->> 'customer_email'),'') = '' THEN RAISE EXCEPTION 'Customer email is required'; END IF;
  INSERT INTO public.orders (
    customer_name, customer_email, customer_phone, country, state, city,
    delivery_address, postal_code, cart_items, total_amount, currency,
    payment_method, payment_network, payment_status, order_status, customer_notes
  ) VALUES (
    p_order ->> 'customer_name', p_order ->> 'customer_email',
    p_order ->> 'customer_phone', p_order ->> 'country', p_order ->> 'state',
    p_order ->> 'city', p_order ->> 'delivery_address', p_order ->> 'postal_code',
    COALESCE(p_order -> 'cart_items','[]'::jsonb),
    COALESCE((p_order ->> 'total_amount')::numeric,0), 'USD',
    'paystack_manual', 'Paystack one-time payment link', 'pending', 'pending',
    p_order ->> 'customer_notes'
  ) RETURNING id INTO new_id;
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
  UPDATE public.orders SET approved_amount_ngn=round(p_amount_ngn,2), updated_at=now()
  WHERE id=p_order_id AND payment_method='paystack_manual';
  IF NOT FOUND THEN RAISE EXCEPTION 'Paystack order not found'; END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.ma_create_manual_payment_order(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ma_create_manual_payment_order(jsonb) TO authenticated;
REVOKE ALL ON FUNCTION public.ma_admin_set_paystack_amount(uuid,numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ma_admin_set_paystack_amount(uuid,numeric) TO authenticated;
