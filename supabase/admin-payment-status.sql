-- MAISON ANNA: secure admin review and customer payment status
-- Run in Supabase SQL Editor after the existing payment tables are created.

CREATE OR REPLACE FUNCTION public.ma_is_admin()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin', false);
$$;

REVOKE ALL ON FUNCTION public.ma_is_admin() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ma_is_admin() TO authenticated;

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

CREATE OR REPLACE FUNCTION public.ma_customer_order_status(p_order_id uuid, p_email text)
RETURNS TABLE(reference_id uuid, payment_status text, payment_method text, total_amount numeric, currency text, created_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT o.id, o.payment_status, o.payment_method, o.total_amount, o.currency, o.created_at
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
         END,
         count(*),
         min(g.created_at)
  FROM public.gift_card_submissions g
  WHERE g.submission_id = p_submission_id
    AND lower(g.customer_email) = lower(trim(p_email))
  GROUP BY g.submission_id;
$$;

REVOKE ALL ON FUNCTION public.ma_admin_list_orders() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.ma_admin_list_gift_cards() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.ma_admin_set_order_status(uuid,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.ma_admin_set_gift_status(uuid,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ma_admin_list_orders() TO authenticated;
GRANT EXECUTE ON FUNCTION public.ma_admin_list_gift_cards() TO authenticated;
GRANT EXECUTE ON FUNCTION public.ma_admin_set_order_status(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.ma_admin_set_gift_status(uuid,text,text) TO authenticated;

REVOKE ALL ON FUNCTION public.ma_customer_order_status(uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.ma_customer_gift_status(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ma_customer_order_status(uuid,text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ma_customer_gift_status(uuid,text) TO anon, authenticated;

DROP POLICY IF EXISTS "Admin can view gift card evidence" ON storage.objects;
CREATE POLICY "Admin can view gift card evidence"
ON storage.objects FOR SELECT TO authenticated
USING (bucket_id = 'gift-card-evidence' AND public.ma_is_admin());

-- Admin page reads sensitive submissions only through the guarded admin RPCs.
