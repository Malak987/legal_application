-- =============================================================================
-- Transactional RPC functions for atomic multi-table workflows in PostgreSQL
-- Restricted to service_role (backend server) via REVOKE/GRANT.
-- =============================================================================

-- 1. Recalculate a lawyer's average rating from public.reviews
CREATE OR REPLACE FUNCTION public.rpc_recalculate_lawyer_rating(p_lawyer_id text)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_avg numeric(3, 2);
BEGIN
  SELECT ROUND(COALESCE(AVG(r.rating), 0), 1)::numeric(3, 2)
    INTO v_avg
    FROM public.reviews r
   WHERE r.lawyer_id = p_lawyer_id;

  UPDATE public.lawyers
     SET rating = COALESCE(v_avg, 0),
         updated_at = now()
   WHERE id = p_lawyer_id;

  RETURN COALESCE(v_avg, 0);
END;
$$;

-- 2. Atomic booking creation + per-hour slot reservation
CREATE OR REPLACE FUNCTION public.rpc_reserve_booking_slots(
  p_booking_id text,
  p_user_id text,
  p_lawyer_id text,
  p_lawyer_name text,
  p_date text,
  p_time text,
  p_hours integer,
  p_total_price numeric,
  p_status text,
  p_slot_keys text[],
  p_slots integer[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_conflicts integer[];
  v_booking public.bookings%ROWTYPE;
  v_idx integer;
BEGIN
  -- Lock any existing slot rows for this lawyer and date to prevent races
  SELECT array_agg(bs.slot ORDER BY bs.slot)
    INTO v_conflicts
    FROM public.booking_slots bs
   WHERE bs.lawyer_id = p_lawyer_id
     AND bs.date = p_date
     AND bs.slot = ANY(p_slots);

  IF v_conflicts IS NOT NULL AND cardinality(v_conflicts) > 0 THEN
    RETURN jsonb_build_object(
      'conflict', true,
      'conflicting_slots', to_jsonb(v_conflicts)
    );
  END IF;

  INSERT INTO public.bookings (
    id, user_id, lawyer_id, lawyer_name, date, time, hours, total_price, status, slot_keys
  ) VALUES (
    COALESCE(p_booking_id, gen_random_uuid()::text),
    p_user_id,
    p_lawyer_id,
    COALESCE(p_lawyer_name, ''),
    p_date,
    p_time,
    p_hours,
    p_total_price,
    COALESCE(p_status, 'Confirmed'),
    COALESCE(p_slot_keys, '{}')
  )
  RETURNING * INTO v_booking;

  FOR v_idx IN 1..COALESCE(cardinality(p_slot_keys), 0) LOOP
    INSERT INTO public.booking_slots (
      id, lawyer_id, date, slot, booking_id, user_id
    ) VALUES (
      p_slot_keys[v_idx],
      p_lawyer_id,
      p_date,
      p_slots[v_idx],
      v_booking.id,
      p_user_id
    );
  END LOOP;

  RETURN jsonb_build_object(
    'conflict', false,
    'booking', to_jsonb(v_booking)
  );
END;
$$;

-- 3. Atomic wallet credit/debit with row-level lock and idempotency
CREATE OR REPLACE FUNCTION public.rpc_wallet_mutate(
  p_user_id text,
  p_type text,
  p_amount numeric,
  p_description text,
  p_idempotency_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_idem public.wallet_idempotency%ROWTYPE;
  v_wallet public.wallets%ROWTYPE;
  v_next_balance numeric(14, 2);
  v_tx public.wallet_transactions%ROWTYPE;
BEGIN
  IF p_idempotency_id IS NOT NULL THEN
    SELECT *
      INTO v_idem
      FROM public.wallet_idempotency
     WHERE id = p_idempotency_id
       FOR UPDATE;

    IF FOUND THEN
      IF v_idem.type <> p_type OR v_idem.amount <> p_amount THEN
        RETURN jsonb_build_object('error', 'IDEMPOTENCY_KEY_MISMATCH');
      END IF;
      RETURN jsonb_build_object(
        'replayed', true,
        'balance', v_idem.balance,
        'currency', v_idem.currency,
        'transaction', v_idem.transaction
      );
    END IF;
  END IF;

  INSERT INTO public.wallets (id, user_id, balance, currency)
  VALUES (p_user_id, p_user_id, 0, 'USD')
  ON CONFLICT (id) DO NOTHING;

  SELECT *
    INTO v_wallet
    FROM public.wallets
   WHERE id = p_user_id
     FOR UPDATE;

  IF p_type = 'debit' THEN
    IF v_wallet.balance < p_amount THEN
      RETURN jsonb_build_object(
        'error', 'INSUFFICIENT_FUNDS',
        'available', v_wallet.balance
      );
    END IF;
    v_next_balance := ROUND(v_wallet.balance - p_amount, 2);
  ELSE
    v_next_balance := ROUND(v_wallet.balance + p_amount, 2);
  END IF;

  UPDATE public.wallets
     SET balance = v_next_balance,
         updated_at = now()
   WHERE id = p_user_id;

  INSERT INTO public.wallet_transactions (
    user_id, type, amount, description, balance, currency, idempotency_key_hash
  ) VALUES (
    p_user_id,
    p_type,
    p_amount,
    COALESCE(p_description, ''),
    v_next_balance,
    v_wallet.currency,
    p_idempotency_id
  )
  RETURNING * INTO v_tx;

  IF p_idempotency_id IS NOT NULL THEN
    INSERT INTO public.wallet_idempotency (
      id, user_id, type, amount, currency, balance, transaction
    ) VALUES (
      p_idempotency_id,
      p_user_id,
      p_type,
      p_amount,
      v_wallet.currency,
      v_next_balance,
      to_jsonb(v_tx)
    );
  END IF;

  RETURN jsonb_build_object(
    'replayed', false,
    'balance', v_next_balance,
    'currency', v_wallet.currency,
    'transaction', to_jsonb(v_tx)
  );
END;
$$;

-- Restrict RPC execution to service_role only (never anon/authenticated directly)
REVOKE ALL ON FUNCTION public.rpc_recalculate_lawyer_rating(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_recalculate_lawyer_rating(text) TO service_role;

REVOKE ALL ON FUNCTION public.rpc_reserve_booking_slots(text, text, text, text, text, text, integer, numeric, text, text[], integer[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_reserve_booking_slots(text, text, text, text, text, text, integer, numeric, text, text[], integer[]) TO service_role;

REVOKE ALL ON FUNCTION public.rpc_wallet_mutate(text, text, numeric, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_wallet_mutate(text, text, numeric, text, text) TO service_role;
