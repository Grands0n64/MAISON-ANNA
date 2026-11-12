-- MAISON ANNA: ALL-IN-ONE DATABASE SETUP
-- Run this entire file once in Supabase SQL Editor.
-- Safe migration: adds missing fields without dropping existing columns or records.

BEGIN;

-- 1) Make sure the existing orders table has the fields used by checkout/admin.
ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS customer_email text,
  ADD COLUMN IF NOT EXISTS customer_phone text,
  ADD COLUMN IF NOT EXISTS country text,
  ADD COLUMN IF NOT EXISTS state text,
  ADD COLUMN IF NOT EXISTS city text,
  ADD COLUMN IF NOT EXISTS postal_code text,
  ADD COLUMN IF NOT EXISTS cart_items jsonb,
  ADD COLUMN IF NOT EXISTS currency text DEFAULT 'USD',
  ADD COLUMN IF NOT EXISTS payment_method text,
  ADD COLUMN IF NOT EXISTS transaction_hash text,
  ADD COLUMN IF NOT EXISTS payment_network text,
  ADD COLUMN IF NOT EXISTS customer_notes text,
  ADD COLUMN IF NOT EXISTS updated_at timestamptz DEFAULT now();

-- Preserve values in the original checkout columns where they exist.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema='public' AND table_name='orders' AND column_name='email') THEN
    EXECUTE 'UPDATE public.orders SET customer_email = email WHERE customer_email IS NULL';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema='public' AND table_name='orders' AND column_name='phone') THEN
    EXECUTE 'UPDATE public.orders SET customer_phone = phone WHERE customer_phone IS NULL';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema='public' AND table_name='orders' AND column_name='items') THEN
    EXECUTE 'UPDATE public.orders SET cart_items = to_jsonb(items) WHERE cart_items IS NULL';
  END IF;
END $$;

-- 2) Make sure gift-card review fields exist. Existing card records are preserved.
ALTER TABLE public.gift_card_submissions
  ADD COLUMN IF NOT EXISTS photo_paths text[] DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS review_status text NOT NULL DEFAULT 'pending',
  ADD COLUMN IF NOT EXISTS admin_notes text,
  ADD COLUMN IF NOT EXISTS reviewed_at timestamptz,
  ADD COLUMN IF NOT EXISTS created_at timestamptz DEFAULT now();

-- 3) Keep gift-card evidence private.
INSERT INTO storage.buckets (id, name, public)
VALUES ('gift-card-evidence', 'gift-card-evidence', false)
ON CONFLICT (id) DO UPDATE SET public = false;

-- 4) Admin identity check uses protected app_metadata, not editable user_metadata.
CREATE OR REPLACE FUNCTION public.ma_is_admin()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin', false);
$$;

REVOKE ALL ON FUNCTION public.ma_is_admin() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ma_is_admin() TO authenticated;

-- 5) Admin read functions.
CREATE OR REPLACE FUNCTION public.ma_admin_list_orders()
RETURNS SETOF jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.ma_is_admin() THEN RAISE EXCEPTION 'Admin access required'; END IF;
  RETURN QUERY SELECT to_jsonb(o) FROM public.orders o ORDER BY o.created_at DESC LIMIT 500;
END;
$$;

CREATE OR REPLACE FUNCTION public.ma_admin_list_gift_cards()
RETURNS SETOF jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.ma_is_admin() THEN RAISE EXCEPTION 'Admin access required'; END IF;
  RETURN QUERY SELECT to_jsonb(g) FROM public.gift_card_submissions g ORDER BY g.created_at DESC LIMIT 500;
END;
$$;

-- 6) Admin status updates. Confirmation is always a manual admin action.
CREATE OR REPLACE FUNCTION public.ma_admin_set_order_status(p_order_id uuid, p_status text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.ma_is_admin() THEN RAISE EXCEPTION 'Admin access required'; END IF;
  IF p_status NOT IN ('confirmed','rejected','under_review','pending') THEN
    RAISE EXCEPTION 'Invalid payment status';
  END IF;
  UPDATE public.orders
  SET payment_status = p_status,
      order_status = CASE WHEN p_status = 'confirmed' THEN 'processing' ELSE order_status END,
      updated_at = now()
  WHERE id = p_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found'; END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.ma_admin_set_gift_status(p_submission_id uuid, p_status text, p_note text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.ma_is_admin() THEN RAISE EXCEPTION 'Admin access required'; END IF;
  IF p_status NOT IN ('approved','rejected','under_review','pending') THEN
    RAISE EXCEPTION 'Invalid gift card status';
  END IF;
  UPDATE public.gift_card_submissions
  SET review_status = p_status,
      admin_notes = p_note,
      reviewed_at = CASE WHEN p_status IN ('approved','rejected') THEN now() ELSE NULL END
  WHERE submission_id = p_submission_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Gift card submission not found'; END IF;
END;
$$;

-- 7) Customer status lookups require both the unguessable UUID and checkout email.
CREATE OR REPLACE FUNCTION public.ma_customer_order_status(p_order_id uuid, p_email text)
RETURNS TABLE(reference_id uuid, payment_status text, payment_method text, total_amount numeric, currency text, created_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT o.id, o.payment_status::text, o.payment_method, o.total_amount, o.currency, o.created_at
  FROM public.orders o
  WHERE o.id = p_order_id AND lower(o.customer_email) = lower(trim(p_email))
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.ma_customer_gift_status(p_submission_id uuid, p_email text)
RETURNS TABLE(reference_id uuid, review_status text, card_count bigint, created_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT g.submission_id,
         CASE
           WHEN bool_and(g.review_status = 'approved') THEN 'approved'
           WHEN bool_or(g.review_status = 'rejected') THEN 'rejected'
           WHEN bool_or(g.review_status = 'under_review') THEN 'under_review'
           ELSE 'pending'
         END::text,
         count(*),
         min(g.created_at)
  FROM public.gift_card_submissions g
  WHERE g.submission_id = p_submission_id
    AND lower(g.customer_email) = lower(trim(p_email))
  GROUP BY g.submission_id;
$$;

-- 8) Customer account history: only the authenticated user's own email records are returned.
CREATE OR REPLACE FUNCTION public.ma_customer_list_orders()
RETURNS SETOF jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $ma_customer_history$
  SELECT to_jsonb(o)
  FROM public.orders o
  WHERE auth.uid() IS NOT NULL
    AND lower(COALESCE(NULLIF(o.customer_email,''), o.email)) = lower(auth.jwt() ->> 'email')
  ORDER BY o.created_at DESC
  LIMIT 100;
$ma_customer_history$;

CREATE OR REPLACE FUNCTION public.ma_customer_list_gift_cards()
RETURNS SETOF jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $ma_customer_history$
  SELECT to_jsonb(g)
  FROM public.gift_card_submissions g
  WHERE auth.uid() IS NOT NULL
    AND lower(g.customer_email) = lower(auth.jwt() ->> 'email')
  ORDER BY g.created_at DESC
  LIMIT 100;
$ma_customer_history$;

-- 9) Create crypto orders while supporting both the original and upgraded orders columns.
CREATE OR REPLACE FUNCTION public.ma_create_crypto_order(p_order jsonb)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  new_id uuid;
  method text := p_order ->> 'payment_method';
  payload jsonb;
  insert_columns text;
  select_columns text;
BEGIN
  IF method NOT IN ('bitcoin','usdt_bep20') THEN
    RAISE EXCEPTION 'Unsupported payment method';
  END IF;

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
    'currency', COALESCE(p_order ->> 'currency','USD'),
    'payment_method', method,
    'transaction_hash', p_order ->> 'transaction_hash',
    'payment_network', p_order ->> 'payment_network',
    'payment_status', 'pending',
    'order_status', 'pending',
    'customer_notes', p_order ->> 'customer_notes',
    'updated_at', now()
  );

  SELECT string_agg(format('%I', c.column_name), ', ' ORDER BY c.ordinal_position),
         string_agg(format('(r).%I', c.column_name), ', ' ORDER BY c.ordinal_position)
  INTO insert_columns, select_columns
  FROM information_schema.columns c
  WHERE c.table_schema = 'public'
    AND c.table_name = 'orders'
    AND c.column_name = ANY (ARRAY[
      'customer_name','customer_email','email','customer_phone','phone',
      'country','state','city','delivery_address','postal_code',
      'cart_items','items','total_amount','currency','payment_method',
      'transaction_hash','payment_network','payment_status','order_status',
      'customer_notes','updated_at'
    ]);

  IF insert_columns IS NULL THEN RAISE EXCEPTION 'Orders table is missing required checkout columns'; END IF;

  EXECUTE format(
    'INSERT INTO public.orders (%s) SELECT %s FROM jsonb_populate_record(NULL::public.orders, $1) AS r RETURNING id',
    insert_columns, select_columns
  ) USING payload INTO new_id;

  RETURN new_id;
END;
$$;

-- 10) Lock down RPC permissions.
REVOKE ALL ON FUNCTION public.ma_admin_list_orders() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.ma_admin_list_gift_cards() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.ma_admin_set_order_status(uuid,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.ma_admin_set_gift_status(uuid,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ma_admin_list_orders() TO authenticated;
GRANT EXECUTE ON FUNCTION public.ma_admin_list_gift_cards() TO authenticated;
GRANT EXECUTE ON FUNCTION public.ma_admin_set_order_status(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.ma_admin_set_gift_status(uuid,text,text) TO authenticated;

REVOKE ALL ON FUNCTION public.ma_customer_list_orders() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.ma_customer_list_gift_cards() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ma_customer_list_orders() TO authenticated;
GRANT EXECUTE ON FUNCTION public.ma_customer_list_gift_cards() TO authenticated;

REVOKE ALL ON FUNCTION public.ma_customer_order_status(uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.ma_customer_gift_status(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ma_customer_order_status(uuid,text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ma_customer_gift_status(uuid,text) TO anon, authenticated;

REVOKE ALL ON FUNCTION public.ma_create_crypto_order(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ma_create_crypto_order(jsonb) TO anon, authenticated;

-- Private evidence is visible only to the administrator.
DROP POLICY IF EXISTS "Admin can view gift card evidence" ON storage.objects;
CREATE POLICY "Admin can view gift card evidence"
ON storage.objects FOR SELECT TO authenticated
USING (bucket_id = 'gift-card-evidence' AND public.ma_is_admin());

-- 11) Assign admin role to the exact account supplied by the owner.
UPDATE auth.users
SET raw_app_meta_data = COALESCE(raw_app_meta_data, '{}'::jsonb) || '{"role":"admin"}'::jsonb
WHERE lower(email) = lower('Riayoung280@gmail.com');

COMMIT;

-- Verify admin role after running:
SELECT email, raw_app_meta_data ->> 'role' AS role
FROM auth.users
WHERE lower(email) = lower('Riayoung280@gmail.com');
