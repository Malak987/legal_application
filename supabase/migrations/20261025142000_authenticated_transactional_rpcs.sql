-- =============================================================================
-- Migration: 20261025142000_authenticated_transactional_rpcs.sql
-- Purpose: replace service-only / compensating writes with authenticated,
-- database-authorized, atomic RPCs for bookings, wallets, chats, cases, tasks,
-- subscriptions, reviews, favorites, roles, and dashboard aggregates.
--
-- All SECURITY DEFINER functions pin search_path, derive identity from auth.uid,
-- and check the authoritative public.users role. Provider-backed payment success
-- is intentionally NOT implemented here.
-- =============================================================================

BEGIN
-- The old database cap (100,000) was lower than the route contract (1,000,000).
-- Preflight without touching data so an unknown legacy row fails with a count
-- before the check is replaced. Never clamp, round, or rewrite money values.
DO $$
DECLARE
  v_invalid_amount_rows bigint;
BEGIN
  SELECT count(*) INTO v_invalid_amount_rows
    FROM public.wallet_transactions
   WHERE amount IS NULL OR amount <= 0 OR amount > 1000000;
  IF v_invalid_amount_rows > 0 THEN
    RAISE EXCEPTION 'Wallet amount preflight failed: % unsupported rows; no data was changed',
      v_invalid_amount_rows;
  END IF;
END;
$$
-- Keep all existing valid rows and make the constraint match the validated API.
ALTER TABLE public.wallet_transactions
  DROP CONSTRAINT IF EXISTS wallet_transactions_amount_check
ALTER TABLE public.wallet_transactions
  ADD CONSTRAINT wallet_transactions_amount_check
  CHECK (amount > 0 AND amount <= 1000000) NOT VALID
ALTER TABLE public.wallet_transactions
  VALIDATE CONSTRAINT wallet_transactions_amount_check
-- Both booking and wallet idempotency must match the established Express
-- contract: lowercase SHA-256 hex of UTF-8(owner) + NUL + UTF-8(trimmed key).
-- The extension's installed schema varies between Supabase projects, so select
-- only one of the two known pgcrypto locations at runtime; never interpolate a
-- caller-controlled schema or function name.
DO $$
BEGIN
  IF to_regprocedure('extensions.digest(bytea,text)') IS NULL
     AND to_regprocedure('public.digest(bytea,text)') IS NULL THEN
    RAISE EXCEPTION 'pgcrypto digest(bytea,text) is required for canonical idempotency hashes';
  END IF;
END;
$$
CREATE OR REPLACE FUNCTION public._sha256_hex(p_value bytea)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SECURITY INVOKER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_schema text;
  v_hash text;
BEGIN
  IF p_value IS NULL THEN
    RETURN NULL;
  END IF;
  IF to_regprocedure('extensions.digest(bytea,text)') IS NOT NULL THEN
    v_schema := 'extensions';
  ELSIF to_regprocedure('public.digest(bytea,text)') IS NOT NULL THEN
    v_schema := 'public';
  ELSE
    RAISE EXCEPTION 'pgcrypto digest(bytea,text) is no longer available';
  END IF;
  EXECUTE format(
    'SELECT pg_catalog.encode(%I.digest($1, ''sha256''), ''hex'')',
    v_schema
  ) INTO v_hash USING p_value;
  RETURN v_hash;
END;
$$
-- Strict parser shared by booking RPCs. Returns NULL for malformed/invalid
-- times; accepts HH:MM, 9:00 am, and 12-hour AM/PM strings used by the legacy UI.
CREATE OR REPLACE FUNCTION public.clock_time_minutes(p_value text)
RETURNS integer
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_match text[];
  v_hour integer;
  v_minute integer;
  v_suffix text;
BEGIN
  IF p_value IS NULL THEN
    RETURN NULL;
  END IF;
  v_match := regexp_match(trim(p_value), '^([0-9]{1,2}):([0-9]{2})[[:space:]]*([AaPp][Mm])?$');
  IF v_match IS NULL THEN
    RETURN NULL;
  END IF;

  v_hour := v_match[1]::integer;
  v_minute := v_match[2]::integer;
  v_suffix := lower(v_match[3]);
  IF v_minute < 0 OR v_minute > 59 THEN
    RETURN NULL;
  END IF;

  IF v_suffix IS NOT NULL THEN
    IF v_hour < 1 OR v_hour > 12 THEN
      RETURN NULL;
    END IF;
    v_hour := v_hour % 12;
    IF v_suffix = 'pm' THEN
      v_hour := v_hour + 12;
    END IF;
  ELSIF v_hour < 0 OR v_hour > 23 THEN
    RETURN NULL;
  END IF;

  RETURN v_hour * 60 + v_minute;
END;
$$
-- Internal slot writer. The unique (lawyer_id,date,slot) constraint is the
-- concurrency arbiter; a conflict raises inside the caller's subtransaction,
-- rolling back the booking and every slot inserted by that call.
CREATE OR REPLACE FUNCTION public._reserve_booking_slots(
  p_user_id text,
  p_booking_id text,
  p_lawyer_id text,
  p_date text,
  p_start_minute integer,
  p_hours integer
)
RETURNS text[]
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_i integer;
  v_slot integer;
  v_id text;
  v_ids text[] := ARRAY[]::text[];
BEGIN
  FOR v_i IN 0..p_hours - 1 LOOP
    v_slot := p_start_minute + (v_i * 60);
    v_id := gen_random_uuid()::text;
    INSERT INTO public.booking_slots (id, lawyer_id, date, slot, booking_id, user_id)
    VALUES (v_id, p_lawyer_id, p_date, v_slot, p_booking_id, p_user_id)
    ON CONFLICT (lawyer_id, date, slot) DO NOTHING;

    IF NOT FOUND THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'BOOKING_SLOT_TAKEN';
    END IF;
    v_ids := array_append(v_ids, v_id);
  END LOOP;
  RETURN v_ids;
END;
$$
-- Serialize booking operations and schedule edits for a lawyer/day. Advisory
-- transaction locks cover the empty-row case; the availability trigger below
-- ensures direct RLS/service-role INSERT/UPDATE/DELETE operations take the
-- same lock before changing a published schedule.
CREATE OR REPLACE FUNCTION public._lock_booking_day(
  p_lawyer_id text,
  p_date text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF p_lawyer_id IS NULL OR p_date IS NULL THEN
    RETURN;
  END IF;
  PERFORM pg_advisory_xact_lock(
    hashtextextended('booking-schedule:' || p_lawyer_id || ':' || p_date, 0)
  );
END;
$$
CREATE OR REPLACE FUNCTION public.lock_schedule_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_old_key text;
  v_new_key text;
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM public._lock_booking_day(NEW.lawyer_id, NEW.date);
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    PERFORM public._lock_booking_day(OLD.lawyer_id, OLD.date);
    RETURN OLD;
  END IF;

  v_old_key := COALESCE(OLD.lawyer_id, '') || '|' || COALESCE(OLD.date, '');
  v_new_key := COALESCE(NEW.lawyer_id, '') || '|' || COALESCE(NEW.date, '');
  IF v_old_key = v_new_key THEN
    PERFORM public._lock_booking_day(NEW.lawyer_id, NEW.date);
  ELSIF v_old_key < v_new_key THEN
    PERFORM public._lock_booking_day(OLD.lawyer_id, OLD.date);
    PERFORM public._lock_booking_day(NEW.lawyer_id, NEW.date);
  ELSE
    PERFORM public._lock_booking_day(NEW.lawyer_id, NEW.date);
    PERFORM public._lock_booking_day(OLD.lawyer_id, OLD.date);
  END IF;
  RETURN NEW;
END;
$$
DROP TRIGGER IF EXISTS trg_availability_schedule_lock ON public.availability
CREATE TRIGGER trg_availability_schedule_lock
  BEFORE INSERT OR UPDATE OF lawyer_id, date, slots OR DELETE ON public.availability
  FOR EACH ROW
  EXECUTE FUNCTION public.lock_schedule_change()
-- Direct server-side booking mutations also take the same advisory locks. This
-- does not make the legacy adapter's multi-request staged writes atomic; it
-- only ensures each committed row change serializes with reservation RPCs.
DROP TRIGGER IF EXISTS trg_bookings_schedule_lock ON public.bookings
CREATE TRIGGER trg_bookings_schedule_lock
  BEFORE INSERT OR UPDATE OF lawyer_id, date, time, hours, status OR DELETE ON public.bookings
  FOR EACH ROW
  EXECUTE FUNCTION public.lock_schedule_change()
-- Check existing appointment rows as a second line of defence for legacy data
-- that predates booking_slots. Unknown legacy time/duration is a review blocker,
-- not silently ignored; all non-Cancelled statuses (including Completed) reserve
-- their historical interval, matching the existing Express booking contract.
CREATE OR REPLACE FUNCTION public._booking_schedule_conflict(
  p_lawyer_id text,
  p_date text,
  p_start_minute integer,
  p_hours integer,
  p_ignore_booking_id text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF EXISTS (
    SELECT 1
      FROM public.bookings AS b
     WHERE b.lawyer_id = p_lawyer_id
       AND b.date = p_date
       AND b.status <> 'Cancelled'
       AND b.id IS DISTINCT FROM p_ignore_booking_id
       AND (public.clock_time_minutes(b.time) IS NULL OR b.hours IS NULL OR b.hours <= 0)
  ) THEN
    RETURN 'LEGACY_BOOKING_REVIEW_REQUIRED';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM public.bookings AS b
     WHERE b.lawyer_id = p_lawyer_id
       AND b.date = p_date
       AND b.status <> 'Cancelled'
       AND b.id IS DISTINCT FROM p_ignore_booking_id
       AND public.clock_time_minutes(b.time) < p_start_minute + (p_hours * 60)
       AND p_start_minute < public.clock_time_minutes(b.time) + (b.hours * 60)
  ) THEN
    RETURN 'BOOKING_OVERLAP';
  END IF;

  RETURN NULL;
END;
$$
-- Atomic client booking creation. Price/name/status/user are all database-
-- derived; the client supplies only the lawyer, requested schedule, duration,
-- and an optional idempotency key. No payment is implied by a booking.
CREATE OR REPLACE FUNCTION public.rpc_create_booking(
  p_lawyer_id text,
  p_date text,
  p_time text,
  p_hours integer,
  p_idempotency_key text DEFAULT NULL,
  p_user_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_actor_id text := public.current_app_user_id();
  v_user_id text;
  v_start integer;
  v_date date;
  v_lawyer public.lawyers%ROWTYPE;
  v_price numeric(12,2);
  v_available integer[];
  v_i integer;
  v_lock_ids text[];
  v_booking public.bookings%ROWTYPE;
  v_existing public.bookings%ROWTYPE;
  v_conflict text;
  v_idempotency_key text := NULLIF(trim(p_idempotency_key), '');
  v_idempotency_hash text;
BEGIN
  IF auth.uid() IS NULL OR v_actor_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AUTHENTICATION_REQUIRED';
  END IF;
  v_user_id := COALESCE(NULLIF(p_user_id, ''), v_actor_id);
  IF v_user_id <> v_actor_id AND NOT public.is_admin() THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'NOT_BOOKING_OWNER';
  END IF;
  IF p_hours IS NULL OR p_hours < 1 OR p_hours > 12 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_BOOKING_DURATION';
  END IF;
  IF v_idempotency_key IS NOT NULL AND char_length(v_idempotency_key) > 128 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'IDEMPOTENCY_KEY_TOO_LONG';
  END IF;
  IF v_idempotency_key IS NOT NULL THEN
    v_idempotency_hash := public._sha256_hex(
      pg_catalog.convert_to(v_user_id, 'UTF8')
      || pg_catalog.decode('00', 'hex')
      || pg_catalog.convert_to(v_idempotency_key, 'UTF8')
    );
  END IF;

  v_start := public.clock_time_minutes(p_time);
  IF v_start IS NULL OR v_start + (p_hours * 60) > 1440 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_BOOKING_TIME';
  END IF;

  BEGIN
    v_date := p_date::date;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_BOOKING_DATE';
  END;
  IF to_char(v_date, 'YYYY-MM-DD') <> p_date THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_BOOKING_DATE';
  END IF;

  IF v_idempotency_hash IS NOT NULL THEN
    SELECT * INTO v_existing
      FROM public.bookings
     WHERE user_id = v_user_id
       AND idempotency_key_hash = v_idempotency_hash;
    IF FOUND THEN
      IF v_existing.lawyer_id <> p_lawyer_id
         OR v_existing.date <> p_date
         OR public.clock_time_minutes(v_existing.time) <> v_start
         OR v_existing.hours <> p_hours THEN
        RETURN jsonb_build_object('error', 'IDEMPOTENCY_KEY_MISMATCH');
      END IF;
      RETURN jsonb_build_object(
        'replayed', true,
        'booking', to_jsonb(v_existing) - 'idempotency_key_hash'
      );
    END IF;
  END IF;

  SELECT * INTO v_lawyer
    FROM public.lawyers
   WHERE id = p_lawyer_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'LAWYER_NOT_FOUND';
  END IF;
  IF v_lawyer.price_value IS NULL OR v_lawyer.price_value < 0 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'LAWYER_RATE_NOT_CONFIGURED';
  END IF;
  v_price := round(v_lawyer.price_value * p_hours, 2);

  -- Serialize all booking and availability mutations for this lawyer/day,
  -- including concurrent INSERT/DELETE when no schedule row existed yet.
  PERFORM public._lock_booking_day(p_lawyer_id, p_date);
  PERFORM a.id
    FROM public.availability AS a
   WHERE a.lawyer_id = p_lawyer_id
     AND a.date = p_date
   FOR SHARE;

  -- Merge all published rows for this lawyer/date and normalize legacy 12/24h
  -- clock strings. Every hourly interval must be advertised, not merely the
  -- requested first slot.
  SELECT array_agg(DISTINCT public.clock_time_minutes(slot_value))
    INTO v_available
    FROM public.availability AS a
    CROSS JOIN LATERAL jsonb_array_elements_text(
      CASE WHEN jsonb_typeof(a.slots) = 'array' THEN a.slots ELSE '[]'::jsonb END
    ) AS slot_value
   WHERE a.lawyer_id = p_lawyer_id
     AND a.date = p_date
     AND public.clock_time_minutes(slot_value) IS NOT NULL;
  IF COALESCE(cardinality(v_available), 0) = 0 THEN
    RETURN jsonb_build_object('error', 'NO_AVAILABILITY');
  END IF;
  FOR v_i IN 0..p_hours - 1 LOOP
    IF NOT ((v_start + (v_i * 60)) = ANY(v_available)) THEN
      RETURN jsonb_build_object('error', 'TIME_NOT_AVAILABLE');
    END IF;
  END LOOP;

  v_conflict := public._booking_schedule_conflict(
    p_lawyer_id, p_date, v_start, p_hours, NULL
  );
  IF v_conflict IS NOT NULL THEN
    RETURN jsonb_build_object('error', v_conflict);
  END IF;

  BEGIN
    INSERT INTO public.bookings (
      user_id, lawyer_id, lawyer_name, date, time, hours, total_price,
      status, slot_keys, idempotency_key_hash
    ) VALUES (
      v_user_id,
      p_lawyer_id,
      v_lawyer.name,
      p_date,
      to_char(make_time(v_start / 60, v_start % 60, 0), 'HH24:MI'),
      p_hours,
      v_price,
      'Pending',
      ARRAY[]::text[],
      v_idempotency_hash
    )
    RETURNING * INTO v_booking;

    v_lock_ids := public._reserve_booking_slots(
      v_user_id, v_booking.id, p_lawyer_id, p_date, v_start, p_hours
    );
    UPDATE public.bookings
       SET slot_keys = v_lock_ids,
           updated_at = now()
     WHERE id = v_booking.id
     RETURNING * INTO v_booking;
  EXCEPTION
    WHEN unique_violation THEN
      IF v_idempotency_hash IS NOT NULL THEN
        SELECT * INTO v_existing
          FROM public.bookings
         WHERE user_id = v_user_id
           AND idempotency_key_hash = v_idempotency_hash;
        IF FOUND THEN
          IF v_existing.lawyer_id = p_lawyer_id
             AND v_existing.date = p_date
             AND public.clock_time_minutes(v_existing.time) = v_start
             AND v_existing.hours = p_hours THEN
            RETURN jsonb_build_object(
              'replayed', true,
              'booking', to_jsonb(v_existing) - 'idempotency_key_hash'
            );
          END IF;
          RETURN jsonb_build_object('error', 'IDEMPOTENCY_KEY_MISMATCH');
        END IF;
      END IF;
      RETURN jsonb_build_object('error', 'SLOT_TAKEN');
    WHEN SQLSTATE 'P0001' THEN
      IF SQLERRM = 'BOOKING_SLOT_TAKEN' THEN
        RETURN jsonb_build_object('error', 'SLOT_TAKEN');
      END IF;
      RAISE;
  END;

  RETURN jsonb_build_object(
    'replayed', false,
    'booking', to_jsonb(v_booking) - 'idempotency_key_hash'
  );
END;
$$
-- Owner cancellation is terminal and releases every reserved slot atomically.
CREATE OR REPLACE FUNCTION public.rpc_cancel_booking(p_booking_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_user_id text := public.current_app_user_id();
  v_booking public.bookings%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR v_user_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AUTHENTICATION_REQUIRED';
  END IF;
  SELECT * INTO v_booking
    FROM public.bookings
   WHERE id = p_booking_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'BOOKING_NOT_FOUND';
  END IF;
  IF v_booking.user_id IS DISTINCT FROM v_user_id AND NOT public.is_admin() THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'NOT_BOOKING_OWNER';
  END IF;
  IF NOT public.is_admin() AND v_booking.status NOT IN ('Pending', 'Active') THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'BOOKING_CANNOT_BE_CANCELLED';
  END IF;

  DELETE FROM public.booking_slots WHERE booking_id = v_booking.id;
  UPDATE public.bookings
     SET status = 'Cancelled', slot_keys = ARRAY[]::text[], updated_at = now()
   WHERE id = v_booking.id
   RETURNING * INTO v_booking;
  RETURN to_jsonb(v_booking) - 'idempotency_key_hash';
END;
$$
-- Admin-only status moderation. Direct table updates are not granted.
CREATE OR REPLACE FUNCTION public.rpc_admin_set_booking_status(
  p_booking_id text,
  p_status text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_booking public.bookings%ROWTYPE;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'ADMIN_REQUIRED';
  END IF;
  IF p_status IS NULL OR p_status NOT IN ('Pending', 'Confirmed', 'Completed', 'Cancelled') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_BOOKING_STATUS';
  END IF;
  SELECT * INTO v_booking FROM public.bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'BOOKING_NOT_FOUND';
  END IF;
  -- Cancelled bookings have released their slot locks, and completed
  -- appointments are terminal. Reopening either state without a new reservation
  -- would create a booking that does not actually own a schedule slot.
  IF v_booking.status IN ('Cancelled', 'Completed') AND p_status <> v_booking.status THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'BOOKING_STATUS_IS_TERMINAL';
  END IF;
  IF p_status = 'Cancelled' THEN
    DELETE FROM public.booking_slots WHERE booking_id = v_booking.id;
  END IF;
  UPDATE public.bookings
     SET status = p_status,
         slot_keys = CASE WHEN p_status = 'Cancelled' THEN ARRAY[]::text[] ELSE slot_keys END,
         updated_at = now()
   WHERE id = p_booking_id
   RETURNING * INTO v_booking;
  RETURN to_jsonb(v_booking) - 'idempotency_key_hash';
END;
$$
-- Admin rescheduling uses the same advertised-slot and unique-lock guarantees
-- as creation. The old locks are restored automatically if the new schedule
-- conflicts because the delete/reserve/update are one transaction.
CREATE OR REPLACE FUNCTION public.rpc_admin_reschedule_booking(
  p_booking_id text,
  p_lawyer_id text,
  p_date text,
  p_time text,
  p_hours integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_booking public.bookings%ROWTYPE;
  v_lawyer public.lawyers%ROWTYPE;
  v_start integer;
  v_date date;
  v_available integer[];
  v_i integer;
  v_lock_ids text[];
  v_conflict text;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'ADMIN_REQUIRED';
  END IF;
  IF p_hours IS NULL OR p_hours < 1 OR p_hours > 12 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_BOOKING_DURATION';
  END IF;
  v_start := public.clock_time_minutes(p_time);
  IF v_start IS NULL OR v_start + p_hours * 60 > 1440 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_BOOKING_TIME';
  END IF;
  BEGIN
    v_date := p_date::date;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_BOOKING_DATE';
  END;
  IF to_char(v_date, 'YYYY-MM-DD') <> p_date THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_BOOKING_DATE';
  END IF;
  SELECT * INTO v_booking FROM public.bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'BOOKING_NOT_FOUND';
  END IF;
  IF v_booking.status IN ('Cancelled', 'Completed') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'TERMINAL_BOOKING_CANNOT_BE_RESCHEDULED';
  END IF;
  SELECT * INTO v_lawyer FROM public.lawyers WHERE id = p_lawyer_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'LAWYER_NOT_FOUND';
  END IF;

  -- Acquire old/new schedule locks in a stable order, then hold the matching
  -- availability rows while validating and reserving the rescheduled slots.
  IF (COALESCE(v_booking.lawyer_id, '') || '|' || COALESCE(v_booking.date, ''))
     <= (COALESCE(p_lawyer_id, '') || '|' || COALESCE(p_date, '')) THEN
    PERFORM public._lock_booking_day(v_booking.lawyer_id, v_booking.date);
    PERFORM public._lock_booking_day(p_lawyer_id, p_date);
  ELSE
    PERFORM public._lock_booking_day(p_lawyer_id, p_date);
    PERFORM public._lock_booking_day(v_booking.lawyer_id, v_booking.date);
  END IF;
  PERFORM a.id
    FROM public.availability AS a
   WHERE a.lawyer_id = p_lawyer_id
     AND a.date = p_date
   FOR SHARE;

  SELECT array_agg(DISTINCT public.clock_time_minutes(slot_value))
    INTO v_available
    FROM public.availability AS a
    CROSS JOIN LATERAL jsonb_array_elements_text(
      CASE WHEN jsonb_typeof(a.slots) = 'array' THEN a.slots ELSE '[]'::jsonb END
    ) AS slot_value
   WHERE a.lawyer_id = p_lawyer_id
     AND a.date = p_date
     AND public.clock_time_minutes(slot_value) IS NOT NULL;
  IF COALESCE(cardinality(v_available), 0) = 0 THEN
    RETURN jsonb_build_object('error', 'NO_AVAILABILITY');
  END IF;
  FOR v_i IN 0..p_hours - 1 LOOP
    IF NOT ((v_start + (v_i * 60)) = ANY(v_available)) THEN
      RETURN jsonb_build_object('error', 'TIME_NOT_AVAILABLE');
    END IF;
  END LOOP;

  v_conflict := public._booking_schedule_conflict(
    p_lawyer_id, p_date, v_start, p_hours, v_booking.id
  );
  IF v_conflict IS NOT NULL THEN
    RETURN jsonb_build_object('error', v_conflict);
  END IF;

  BEGIN
    DELETE FROM public.booking_slots WHERE booking_id = v_booking.id;
    v_lock_ids := public._reserve_booking_slots(
      v_booking.user_id, v_booking.id, p_lawyer_id, p_date, v_start, p_hours
    );
    UPDATE public.bookings
       SET lawyer_id = p_lawyer_id,
           lawyer_name = v_lawyer.name,
           date = p_date,
           time = to_char(make_time(v_start / 60, v_start % 60, 0), 'HH24:MI'),
           hours = p_hours,
           total_price = round(v_lawyer.price_value * p_hours, 2),
           slot_keys = v_lock_ids,
           updated_at = now()
     WHERE id = v_booking.id
     RETURNING * INTO v_booking;
  EXCEPTION
    WHEN unique_violation THEN
      RETURN jsonb_build_object('error', 'SLOT_TAKEN');
    WHEN SQLSTATE 'P0001' THEN
      IF SQLERRM = 'BOOKING_SLOT_TAKEN' THEN
        RETURN jsonb_build_object('error', 'SLOT_TAKEN');
      END IF;
      RAISE;
  END;
  RETURN to_jsonb(v_booking) - 'idempotency_key_hash';
END;
$$
-- Delete a booking and all of its held slots atomically. The existing route
-- allows the booking owner or admin to delete; direct table/slot DML is revoked.
CREATE OR REPLACE FUNCTION public.rpc_delete_booking(p_booking_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_user_id text := public.current_app_user_id();
  v_booking public.bookings%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR v_user_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AUTHENTICATION_REQUIRED';
  END IF;
  SELECT * INTO v_booking
    FROM public.bookings
   WHERE id = p_booking_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'BOOKING_NOT_FOUND';
  END IF;
  IF v_booking.user_id IS DISTINCT FROM v_user_id AND NOT public.is_admin() THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'NOT_BOOKING_OWNER';
  END IF;

  DELETE FROM public.booking_slots WHERE booking_id = v_booking.id;
  DELETE FROM public.bookings WHERE id = v_booking.id;
  RETURN jsonb_build_object('id', v_booking.id);
END;
$$
-- Atomic wallet ledger. A non-admin may only debit their own wallet; an
-- authenticated database admin may make the same manual credits/debits as the
-- existing Admin API. Client payment-provider credits are still unavailable:
-- no caller-supplied value is treated as proof of payment or a webhook result.
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
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_actor text := public.current_app_user_id();
  v_idem_id text;
  v_idempotency_key text := NULLIF(trim(p_idempotency_id), '');
  v_idem public.wallet_idempotency%ROWTYPE;
  v_wallet public.wallets%ROWTYPE;
  v_next_balance numeric(14,2);
  v_tx public.wallet_transactions%ROWTYPE;
BEGIN
  IF p_user_id IS NULL OR p_type IS NULL OR p_type NOT IN ('credit', 'debit')
     OR p_amount IS NULL OR p_amount <= 0 OR p_amount > 1000000
     OR p_amount <> round(p_amount, 2) THEN
    RETURN jsonb_build_object('error', 'INVALID_TRANSACTION');
  END IF;
  IF auth.uid() IS NULL OR v_actor IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AUTHENTICATION_REQUIRED';
  END IF;
  IF NOT public.is_admin()
     AND (p_type <> 'debit' OR p_user_id <> v_actor) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'WALLET_OPERATION_NOT_AUTHORIZED';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = p_user_id) THEN
    RETURN jsonb_build_object('error', 'UNKNOWN_USER');
  END IF;

  IF v_idempotency_key IS NOT NULL THEN
    IF char_length(v_idempotency_key) > 128 THEN
      RETURN jsonb_build_object('error', 'IDEMPOTENCY_KEY_TOO_LONG');
    END IF;
    -- Match Express exactly: SHA-256(owner UTF-8 + NUL + trimmed key UTF-8).
    -- Only the digest is persisted; no raw key or delimiter-ambiguous composite.
    v_idem_id := public._sha256_hex(
      pg_catalog.convert_to(p_user_id, 'UTF8')
      || pg_catalog.decode('00', 'hex')
      || pg_catalog.convert_to(v_idempotency_key, 'UTF8')
    );
    -- Serialize retries with the same digest before checking/inserting the
    -- ledger record so concurrent requests replay instead of returning 500.
    PERFORM pg_advisory_xact_lock(hashtextextended(v_idem_id, 0));
  END IF;

  INSERT INTO public.wallets (id, user_id, balance, currency)
  VALUES (p_user_id, p_user_id, 0, 'USD')
  ON CONFLICT (id) DO NOTHING;
  SELECT * INTO v_wallet FROM public.wallets WHERE id = p_user_id FOR UPDATE;
  IF v_wallet.currency <> 'USD' THEN
    RETURN jsonb_build_object('error', 'CURRENCY_MISMATCH', 'currency', v_wallet.currency);
  END IF;

  IF v_idem_id IS NOT NULL THEN
    SELECT * INTO v_idem FROM public.wallet_idempotency WHERE id = v_idem_id FOR UPDATE;
    IF FOUND THEN
      IF v_idem.user_id <> p_user_id OR v_idem.type <> p_type OR v_idem.amount <> p_amount THEN
        RETURN jsonb_build_object('error', 'IDEMPOTENCY_KEY_MISMATCH');
      END IF;
      RETURN jsonb_build_object(
        'replayed', true,
        'balance', v_idem.balance,
        'currency', v_idem.currency,
        'transaction', v_idem.transaction - 'idempotency_key_hash'
      );
    END IF;
  END IF;

  IF p_type = 'debit' AND v_wallet.balance < p_amount THEN
    RETURN jsonb_build_object('error', 'INSUFFICIENT_FUNDS', 'available', v_wallet.balance);
  END IF;
  v_next_balance := CASE
    WHEN p_type = 'debit' THEN v_wallet.balance - p_amount
    ELSE v_wallet.balance + p_amount
  END;

  UPDATE public.wallets
     SET balance = v_next_balance, updated_at = now()
   WHERE id = p_user_id
   RETURNING * INTO v_wallet;
  INSERT INTO public.wallet_transactions (
    user_id, type, amount, description, balance, currency, idempotency_key_hash
  ) VALUES (
    p_user_id, p_type, p_amount, left(COALESCE(p_description, ''), 300), v_next_balance,
    v_wallet.currency, v_idem_id
  ) RETURNING * INTO v_tx;

  IF v_idem_id IS NOT NULL THEN
    INSERT INTO public.wallet_idempotency (
      id, user_id, type, amount, currency, balance, transaction
    ) VALUES (
      v_idem_id, p_user_id, p_type, p_amount, v_wallet.currency, v_next_balance,
      to_jsonb(v_tx)
    );
  END IF;
  RETURN jsonb_build_object(
    'replayed', false,
    'balance', v_next_balance,
    'currency', v_wallet.currency,
    'transaction', to_jsonb(v_tx) - 'idempotency_key_hash'
  );
END;
$$
-- Chat creation and message append are one database transaction. Names and
-- sender identity come from public.users, never from client-supplied metadata.
CREATE OR REPLACE FUNCTION public.rpc_chat_create(
  p_participants text[],
  p_initial_message text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_actor text := public.current_app_user_id();
  v_participants text[];
  v_names jsonb;
  v_chat public.chats%ROWTYPE;
  v_message public.chat_messages%ROWTYPE;
  v_text text := NULLIF(trim(p_initial_message), '');
  v_name text;
BEGIN
  IF auth.uid() IS NULL OR v_actor IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AUTHENTICATION_REQUIRED';
  END IF;
  SELECT array_agg(x ORDER BY x) INTO v_participants
    FROM (SELECT DISTINCT trim(value) AS x
            FROM unnest(COALESCE(p_participants, ARRAY[]::text[])) AS value
           WHERE trim(value) <> '') AS unique_values;
  IF COALESCE(cardinality(v_participants), 0) < 2 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'TWO_DISTINCT_PARTICIPANTS_REQUIRED';
  END IF;
  IF NOT public.is_admin() AND NOT (v_actor = ANY(v_participants)) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'CALLER_MUST_BE_PARTICIPANT';
  END IF;
  IF (SELECT count(*) FROM public.users WHERE id = ANY(v_participants)) <> cardinality(v_participants) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'UNKNOWN_CHAT_PARTICIPANT';
  END IF;

  SELECT jsonb_object_agg(id, name) INTO v_names
    FROM public.users WHERE id = ANY(v_participants);
  INSERT INTO public.chats (participants, participant_names, last_message)
  VALUES (v_participants, COALESCE(v_names, '{}'::jsonb), COALESCE(v_text, ''))
  RETURNING * INTO v_chat;

  IF v_text IS NOT NULL THEN
    IF char_length(v_text) > 4000 THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'MESSAGE_TOO_LONG';
    END IF;
    SELECT name INTO v_name FROM public.users WHERE id = v_actor;
    INSERT INTO public.chat_messages (chat_id, sender_id, sender_name, text)
    VALUES (v_chat.id, v_actor, COALESCE(NULLIF(trim(v_name), ''), 'User'), v_text)
    RETURNING * INTO v_message;
    UPDATE public.chats SET last_message = v_text, updated_at = now()
     WHERE id = v_chat.id RETURNING * INTO v_chat;
  END IF;

  RETURN jsonb_build_object(
    'chat', to_jsonb(v_chat),
    'message', CASE WHEN v_text IS NULL THEN NULL ELSE to_jsonb(v_message) END
  );
END;
$$
CREATE OR REPLACE FUNCTION public.rpc_chat_send_message(
  p_chat_id text,
  p_text text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_actor text := public.current_app_user_id();
  v_chat public.chats%ROWTYPE;
  v_message public.chat_messages%ROWTYPE;
  v_name text;
  v_text text := trim(COALESCE(p_text, ''));
BEGIN
  IF auth.uid() IS NULL OR v_actor IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AUTHENTICATION_REQUIRED';
  END IF;
  IF v_text = '' OR char_length(v_text) > 4000 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_MESSAGE';
  END IF;
  SELECT * INTO v_chat FROM public.chats WHERE id = p_chat_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'CHAT_NOT_FOUND';
  END IF;
  IF NOT public.is_admin() AND NOT (v_actor = ANY(v_chat.participants)) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'NOT_CHAT_PARTICIPANT';
  END IF;
  SELECT name INTO v_name FROM public.users WHERE id = v_actor;
  INSERT INTO public.chat_messages (chat_id, sender_id, sender_name, text)
  VALUES (v_chat.id, v_actor, COALESCE(NULLIF(trim(v_name), ''), 'User'), v_text)
  RETURNING * INTO v_message;
  UPDATE public.chats
     SET last_message = v_text, updated_at = now()
   WHERE id = v_chat.id;
  RETURN to_jsonb(v_message);
END;
$$
-- Case/task transitions are authenticated, owner/admin checked, and keep status
-- values inside the contract. Case owners have no general status column grant.
CREATE OR REPLACE FUNCTION public.rpc_case_set_status(p_case_id text, p_status text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_actor text := public.current_app_user_id();
  v_case public.cases%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR v_actor IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AUTHENTICATION_REQUIRED';
  END IF;
  IF p_status IS NULL OR p_status NOT IN ('Open', 'In Progress', 'Closed', 'Pending') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_CASE_STATUS';
  END IF;
  SELECT * INTO v_case FROM public.cases WHERE id = p_case_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'CASE_NOT_FOUND';
  END IF;
  IF NOT public.is_admin()
     AND (public.current_app_user_role() <> 'client'
       OR v_case.user_id IS DISTINCT FROM v_actor) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'NOT_CASE_OWNER';
  END IF;
  UPDATE public.cases SET status = p_status, updated_at = now()
   WHERE id = p_case_id RETURNING * INTO v_case;
  RETURN to_jsonb(v_case);
END;
$$
-- Atomically update case content, status, and (admin-only) ownership. The table
-- has no case_id relation in the observed schema, so this RPC does not invent one.
CREATE OR REPLACE FUNCTION public.rpc_case_update(
  p_case_id text,
  p_changes jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_actor text := public.current_app_user_id();
  v_case public.cases%ROWTYPE;
  v_key text;
  v_owner text;
BEGIN
  IF auth.uid() IS NULL OR v_actor IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AUTHENTICATION_REQUIRED';
  END IF;
  IF p_changes IS NULL OR jsonb_typeof(p_changes) <> 'object'
     OR p_changes = '{}'::jsonb THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_CASE_PATCH';
  END IF;
  FOR v_key IN SELECT jsonb_object_keys(p_changes) LOOP
    IF v_key NOT IN ('title', 'description', 'client_name', 'case_type', 'priority', 'due_date', 'status', 'user_id') THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_CASE_FIELD';
    END IF;
  END LOOP;

  SELECT * INTO v_case FROM public.cases WHERE id = p_case_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'CASE_NOT_FOUND';
  END IF;
  IF NOT public.is_admin()
     AND (public.current_app_user_role() <> 'client'
       OR v_case.user_id IS DISTINCT FROM v_actor) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'NOT_CASE_OWNER';
  END IF;

  IF p_changes ? 'title'
     AND (jsonb_typeof(p_changes->'title') <> 'string'
       OR char_length(trim(p_changes->>'title')) < 2
       OR char_length(p_changes->>'title') > 200) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_CASE_TITLE';
  END IF;
  IF p_changes ? 'description'
     AND jsonb_typeof(p_changes->'description') NOT IN ('string', 'null') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_CASE_DESCRIPTION';
  END IF;
  IF p_changes ? 'description' AND char_length(COALESCE(p_changes->>'description', '')) > 4000 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_CASE_DESCRIPTION';
  END IF;
  IF p_changes ? 'client_name'
     AND (jsonb_typeof(p_changes->'client_name') NOT IN ('string', 'null')
       OR char_length(COALESCE(p_changes->>'client_name', '')) > 160) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_CASE_CLIENT_NAME';
  END IF;
  IF p_changes ? 'case_type'
     AND (jsonb_typeof(p_changes->'case_type') NOT IN ('string', 'null')
       OR char_length(COALESCE(p_changes->>'case_type', '')) > 120) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_CASE_TYPE';
  END IF;
  IF p_changes ? 'priority'
     AND (jsonb_typeof(p_changes->'priority') <> 'string'
       OR p_changes->>'priority' NOT IN ('High', 'Medium', 'Low')) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_CASE_PRIORITY';
  END IF;
  IF p_changes ? 'status'
     AND (jsonb_typeof(p_changes->'status') <> 'string'
       OR p_changes->>'status' NOT IN ('Open', 'In Progress', 'Closed', 'Pending')) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_CASE_STATUS';
  END IF;
  IF p_changes ? 'due_date'
     AND jsonb_typeof(p_changes->'due_date') NOT IN ('string', 'null') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_CASE_DUE_DATE';
  END IF;
  IF p_changes ? 'user_id' THEN
    IF NOT public.is_admin() THEN
      IF p_changes->>'user_id' IS DISTINCT FROM v_case.user_id THEN
        RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'ADMIN_REQUIRED_FOR_CASE_REASSIGNMENT';
      END IF;
    ELSE
      v_owner := NULLIF(p_changes->>'user_id', '');
      IF v_owner IS NULL OR NOT public.is_eligible_case_owner(v_owner) THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INELIGIBLE_CASE_OWNER';
      END IF;
    END IF;
  END IF;

  UPDATE public.cases
     SET title = CASE WHEN p_changes ? 'title' THEN p_changes->>'title' ELSE title END,
         description = CASE WHEN p_changes ? 'description'
                             THEN COALESCE(p_changes->>'description', '') ELSE description END,
         client_name = CASE WHEN p_changes ? 'client_name'
                            THEN COALESCE(p_changes->>'client_name', '') ELSE client_name END,
         case_type = CASE WHEN p_changes ? 'case_type'
                          THEN COALESCE(p_changes->>'case_type', '') ELSE case_type END,
         priority = CASE WHEN p_changes ? 'priority' THEN p_changes->>'priority' ELSE priority END,
         status = CASE WHEN p_changes ? 'status' THEN p_changes->>'status' ELSE status END,
         due_date = CASE WHEN p_changes ? 'due_date'
                         THEN COALESCE(p_changes->>'due_date', '') ELSE due_date END,
         user_id = CASE WHEN public.is_admin() AND p_changes ? 'user_id'
                        THEN v_owner ELSE user_id END,
         updated_at = now()
   WHERE id = p_case_id RETURNING * INTO v_case;
  RETURN to_jsonb(v_case);
END;
$$
CREATE OR REPLACE FUNCTION public.rpc_task_set_status(p_task_id text, p_status text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_actor text := public.current_app_user_id();
  v_task public.tasks%ROWTYPE;
  v_allowed text[];
BEGIN
  IF auth.uid() IS NULL OR v_actor IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AUTHENTICATION_REQUIRED';
  END IF;
  IF p_status IS NULL OR p_status NOT IN ('Pending', 'In Progress', 'Completed', 'Cancelled') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_TASK_STATUS';
  END IF;
  SELECT * INTO v_task FROM public.tasks WHERE id = p_task_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'TASK_NOT_FOUND';
  END IF;
  IF v_task.user_id IS DISTINCT FROM v_actor AND NOT public.is_admin() THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'NOT_TASK_OWNER';
  END IF;
  IF NOT public.is_admin() THEN
    v_allowed := CASE v_task.status
      WHEN 'Pending' THEN ARRAY['In Progress', 'Completed', 'Cancelled']::text[]
      WHEN 'To Do' THEN ARRAY['Pending', 'In Progress', 'Completed', 'Cancelled']::text[]
      WHEN 'In Progress' THEN ARRAY['Completed', 'Cancelled']::text[]
      -- Legacy Done/Completed/Cancelled rows are terminal for non-admins.
      -- An administrator can correct a legacy row through the checked branch.
      ELSE ARRAY[]::text[]
    END;
    IF NOT (p_status = ANY(v_allowed)) THEN
      RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'INVALID_TASK_TRANSITION';
    END IF;
  END IF;
  UPDATE public.tasks SET status = p_status, updated_at = now()
   WHERE id = p_task_id RETURNING * INTO v_task;
  RETURN to_jsonb(v_task);
END;
$$
-- General task edits and status transitions share one row lock and transaction;
-- the client never receives a direct UPDATE grant on the protected status field.
CREATE OR REPLACE FUNCTION public.rpc_task_update(
  p_task_id text,
  p_changes jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_actor text := public.current_app_user_id();
  v_task public.tasks%ROWTYPE;
  v_key text;
  v_allowed text[];
  v_status text;
BEGIN
  IF auth.uid() IS NULL OR v_actor IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AUTHENTICATION_REQUIRED';
  END IF;
  IF p_changes IS NULL OR jsonb_typeof(p_changes) <> 'object'
     OR p_changes = '{}'::jsonb THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_TASK_PATCH';
  END IF;
  FOR v_key IN SELECT jsonb_object_keys(p_changes) LOOP
    IF v_key NOT IN ('title', 'description', 'due_date', 'priority', 'status') THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_TASK_FIELD';
    END IF;
  END LOOP;

  SELECT * INTO v_task FROM public.tasks WHERE id = p_task_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'TASK_NOT_FOUND';
  END IF;
  IF v_task.user_id IS DISTINCT FROM v_actor AND NOT public.is_admin() THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'NOT_TASK_OWNER';
  END IF;

  IF p_changes ? 'title'
     AND (jsonb_typeof(p_changes->'title') <> 'string'
       OR char_length(trim(p_changes->>'title')) < 2
       OR char_length(p_changes->>'title') > 200) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_TASK_TITLE';
  END IF;
  IF p_changes ? 'description'
     AND jsonb_typeof(p_changes->'description') NOT IN ('string', 'null') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_TASK_DESCRIPTION';
  END IF;
  IF p_changes ? 'description' AND char_length(COALESCE(p_changes->>'description', '')) > 4000 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_TASK_DESCRIPTION';
  END IF;
  IF p_changes ? 'due_date'
     AND jsonb_typeof(p_changes->'due_date') NOT IN ('string', 'null') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_TASK_DUE_DATE';
  END IF;
  IF p_changes ? 'priority'
     AND (jsonb_typeof(p_changes->'priority') <> 'string'
       OR p_changes->>'priority' NOT IN ('High', 'Medium', 'Low')) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_TASK_PRIORITY';
  END IF;

  IF p_changes ? 'status' THEN
    v_status := p_changes->>'status';
    IF jsonb_typeof(p_changes->'status') <> 'string'
       OR v_status NOT IN ('Pending', 'In Progress', 'Completed', 'Cancelled') THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_TASK_STATUS';
    END IF;
    IF NOT public.is_admin() AND v_status IS DISTINCT FROM v_task.status THEN
      v_allowed := CASE v_task.status
        WHEN 'Pending' THEN ARRAY['In Progress', 'Completed', 'Cancelled']::text[]
        WHEN 'To Do' THEN ARRAY['Pending', 'In Progress', 'Completed', 'Cancelled']::text[]
        WHEN 'In Progress' THEN ARRAY['Completed', 'Cancelled']::text[]
        ELSE ARRAY[]::text[]
      END;
      IF NOT (v_status = ANY(v_allowed)) THEN
        RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'INVALID_TASK_TRANSITION';
      END IF;
    END IF;
  END IF;

  UPDATE public.tasks
     SET title = CASE WHEN p_changes ? 'title' THEN p_changes->>'title' ELSE title END,
         description = CASE WHEN p_changes ? 'description'
                            THEN COALESCE(p_changes->>'description', '') ELSE description END,
         due_date = CASE WHEN p_changes ? 'due_date'
                         THEN COALESCE(p_changes->>'due_date', '') ELSE due_date END,
         priority = CASE WHEN p_changes ? 'priority' THEN p_changes->>'priority' ELSE priority END,
         status = CASE WHEN p_changes ? 'status' THEN p_changes->>'status' ELSE status END,
         updated_at = now()
   WHERE id = p_task_id RETURNING * INTO v_task;
  RETURN to_jsonb(v_task);
END;
$$
-- A notification owner may only toggle its own read flag. Administrators may
-- edit content/recipient through this RPC; direct UPDATE remains column-limited.
CREATE OR REPLACE FUNCTION public.rpc_notification_update(
  p_notification_id text,
  p_changes jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_actor text := public.current_app_user_id();
  v_notification public.notifications%ROWTYPE;
  v_key text;
BEGIN
  IF auth.uid() IS NULL OR v_actor IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AUTHENTICATION_REQUIRED';
  END IF;
  IF p_changes IS NULL OR jsonb_typeof(p_changes) <> 'object'
     OR p_changes = '{}'::jsonb THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_NOTIFICATION_PATCH';
  END IF;
  FOR v_key IN SELECT jsonb_object_keys(p_changes) LOOP
    IF v_key NOT IN ('user_id', 'title', 'content', 'type', 'read') THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_NOTIFICATION_FIELD';
    END IF;
  END LOOP;

  SELECT * INTO v_notification
    FROM public.notifications
   WHERE id = p_notification_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'NOTIFICATION_NOT_FOUND';
  END IF;
  IF v_notification.user_id IS DISTINCT FROM v_actor AND NOT public.is_admin() THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'NOTIFICATION_OWNER_REQUIRED';
  END IF;
  IF NOT public.is_admin() AND (p_changes - 'read') <> '{}'::jsonb THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'NOTIFICATION_OWNER_READ_ONLY';
  END IF;
  IF p_changes ? 'title'
     AND (jsonb_typeof(p_changes->'title') <> 'string'
       OR char_length(trim(p_changes->>'title')) < 2
       OR char_length(p_changes->>'title') > 200) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_NOTIFICATION_TITLE';
  END IF;
  IF p_changes ? 'content'
     AND jsonb_typeof(p_changes->'content') NOT IN ('string', 'null') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_NOTIFICATION_CONTENT';
  END IF;
  IF p_changes ? 'type'
     AND jsonb_typeof(p_changes->'type') NOT IN ('string', 'null') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_NOTIFICATION_TYPE';
  END IF;
  IF p_changes ? 'read' AND jsonb_typeof(p_changes->'read') <> 'boolean' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_NOTIFICATION_READ_FLAG';
  END IF;
  IF public.is_admin() AND p_changes ? 'user_id'
     AND (jsonb_typeof(p_changes->'user_id') <> 'string'
       OR NOT EXISTS (SELECT 1 FROM public.users WHERE id = p_changes->>'user_id')) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_NOTIFICATION_RECIPIENT';
  END IF;

  UPDATE public.notifications
     SET user_id = CASE WHEN public.is_admin() AND p_changes ? 'user_id'
                        THEN p_changes->>'user_id' ELSE user_id END,
         title = CASE WHEN p_changes ? 'title' THEN p_changes->>'title' ELSE title END,
         content = CASE WHEN p_changes ? 'content'
                        THEN COALESCE(p_changes->>'content', '') ELSE content END,
         type = CASE WHEN p_changes ? 'type'
                     THEN COALESCE(NULLIF(p_changes->>'type', ''), 'general') ELSE type END,
         read = CASE WHEN p_changes ? 'read' THEN (p_changes->>'read')::boolean ELSE read END,
         updated_at = now()
   WHERE id = p_notification_id
   RETURNING * INTO v_notification;
  RETURN to_jsonb(v_notification);
END;
$$
-- Admin case owner reassignment is the only route that may change user_id.
CREATE OR REPLACE FUNCTION public.rpc_admin_assign_case_owner(
  p_case_id text,
  p_user_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_case public.cases%ROWTYPE;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'ADMIN_REQUIRED';
  END IF;
  IF NOT public.is_eligible_case_owner(p_user_id) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INELIGIBLE_CASE_OWNER';
  END IF;
  UPDATE public.cases SET user_id = p_user_id, updated_at = now()
   WHERE id = p_case_id RETURNING * INTO v_case;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'CASE_NOT_FOUND';
  END IF;
  RETURN to_jsonb(v_case);
END;
$$
-- Pending-only subscription creation derives the display title from plans.
-- It does not imply payment or grant an active entitlement.
CREATE OR REPLACE FUNCTION public.rpc_subscription_create(
  p_plan_id text,
  p_user_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_actor text := public.current_app_user_id();
  v_target text;
  v_plan public.plans%ROWTYPE;
  v_subscription public.subscriptions%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR v_actor IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AUTHENTICATION_REQUIRED';
  END IF;
  v_target := COALESCE(NULLIF(p_user_id, ''), v_actor);
  IF v_target <> v_actor AND NOT public.is_admin() THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'NOT_SUBSCRIPTION_OWNER';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = v_target) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'UNKNOWN_USER';
  END IF;
  SELECT * INTO v_plan FROM public.plans WHERE id = p_plan_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'UNKNOWN_PLAN';
  END IF;
  INSERT INTO public.subscriptions (user_id, plan_id, plan_title, status)
  VALUES (v_target, v_plan.id, v_plan.title, 'Pending')
  RETURNING * INTO v_subscription;
  RETURN to_jsonb(v_subscription);
END;
$$
CREATE OR REPLACE FUNCTION public.rpc_subscription_cancel(p_subscription_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_actor text := public.current_app_user_id();
  v_subscription public.subscriptions%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR v_actor IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AUTHENTICATION_REQUIRED';
  END IF;
  SELECT * INTO v_subscription
    FROM public.subscriptions WHERE id = p_subscription_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'SUBSCRIPTION_NOT_FOUND';
  END IF;
  IF v_subscription.user_id IS DISTINCT FROM v_actor AND NOT public.is_admin() THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'NOT_SUBSCRIPTION_OWNER';
  END IF;
  IF NOT public.is_admin() AND v_subscription.status NOT IN ('Pending', 'Active') THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'SUBSCRIPTION_CANNOT_BE_CANCELLED';
  END IF;
  UPDATE public.subscriptions SET status = 'Cancelled', updated_at = now()
   WHERE id = p_subscription_id RETURNING * INTO v_subscription;
  RETURN to_jsonb(v_subscription);
END;
$$
-- No authenticated RPC activates/changes paid subscription entitlements.
-- Provider-backed activation must wait for a verified webhook and its
-- separately reviewed RPC.

CREATE OR REPLACE FUNCTION public.rpc_subscription_delete(p_subscription_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_actor text := public.current_app_user_id();
  v_subscription public.subscriptions%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR v_actor IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AUTHENTICATION_REQUIRED';
  END IF;
  SELECT * INTO v_subscription
    FROM public.subscriptions WHERE id = p_subscription_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'SUBSCRIPTION_NOT_FOUND';
  END IF;
  IF v_subscription.user_id IS DISTINCT FROM v_actor AND NOT public.is_admin() THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'NOT_SUBSCRIPTION_OWNER';
  END IF;
  IF v_subscription.status = 'Active' THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'ACTIVE_SUBSCRIPTION_CANNOT_BE_DELETED';
  END IF;
  DELETE FROM public.subscriptions WHERE id = p_subscription_id;
  RETURN jsonb_build_object('id', p_subscription_id, 'deleted', true);
END;
$$
-- Review author is derived from the Auth mapping. One-review-per-lawyer remains
-- enforced by the existing UNIQUE constraint; a trigger maintains rating.
CREATE OR REPLACE FUNCTION public.rpc_review_submit(
  p_lawyer_id text,
  p_rating numeric,
  p_comment text DEFAULT ''
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_actor text := public.current_app_user_id();
  v_name text;
  v_review public.reviews%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR v_actor IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AUTHENTICATION_REQUIRED';
  END IF;
  IF p_rating IS NULL OR p_rating < 1 OR p_rating > 5
     OR char_length(COALESCE(p_comment, '')) > 4000 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_REVIEW';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.lawyers WHERE id = p_lawyer_id) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'LAWYER_NOT_FOUND';
  END IF;
  SELECT name INTO v_name FROM public.users WHERE id = v_actor;
  INSERT INTO public.reviews (user_id, user_name, lawyer_id, rating, comment)
  VALUES (v_actor, COALESCE(NULLIF(trim(v_name), ''), 'User'), p_lawyer_id, p_rating, COALESCE(p_comment, ''))
  ON CONFLICT (user_id, lawyer_id) DO NOTHING
  RETURNING * INTO v_review;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'DUPLICATE_REVIEW');
  END IF;
  RETURN to_jsonb(v_review);
END;
$$
CREATE OR REPLACE FUNCTION public.rpc_admin_review_moderate(
  p_review_id text,
  p_rating numeric DEFAULT NULL,
  p_comment text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_review public.reviews%ROWTYPE;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'ADMIN_REQUIRED';
  END IF;
  IF p_rating IS NULL AND p_comment IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'NO_REVIEW_CHANGES';
  END IF;
  IF p_rating IS NOT NULL AND (p_rating < 1 OR p_rating > 5) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_REVIEW_RATING';
  END IF;
  IF p_comment IS NOT NULL AND char_length(p_comment) > 4000 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'REVIEW_COMMENT_TOO_LONG';
  END IF;
  UPDATE public.reviews
     SET rating = COALESCE(p_rating, rating),
         comment = COALESCE(p_comment, comment),
         updated_at = now()
   WHERE id = p_review_id RETURNING * INTO v_review;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'REVIEW_NOT_FOUND';
  END IF;
  RETURN to_jsonb(v_review);
END;
$$
CREATE OR REPLACE FUNCTION public.rpc_admin_review_delete(p_review_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'ADMIN_REQUIRED';
  END IF;
  DELETE FROM public.reviews WHERE id = p_review_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'REVIEW_NOT_FOUND';
  END IF;
  RETURN jsonb_build_object('id', p_review_id, 'deleted', true);
END;
$$
-- Review authors may remove their own review; administrators may remove any
-- review. Direct table DELETE remains revoked, and the trigger recalculates the
-- lawyer rating in the same transaction.
CREATE OR REPLACE FUNCTION public.rpc_review_delete(p_review_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_actor text := public.current_app_user_id();
  v_review public.reviews%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR v_actor IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AUTHENTICATION_REQUIRED';
  END IF;
  SELECT * INTO v_review FROM public.reviews WHERE id = p_review_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'REVIEW_NOT_FOUND';
  END IF;
  IF v_review.user_id IS DISTINCT FROM v_actor AND NOT public.is_admin() THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'NOT_REVIEW_OWNER';
  END IF;
  DELETE FROM public.reviews WHERE id = p_review_id;
  RETURN jsonb_build_object('id', p_review_id, 'deleted', true);
END;
$$
CREATE OR REPLACE FUNCTION public.recalculate_lawyer_rating_from_reviews()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_lawyer_id text;
BEGIN
  v_lawyer_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.lawyer_id ELSE NEW.lawyer_id END;
  UPDATE public.lawyers AS l
     SET rating = COALESCE((
       SELECT round(avg(r.rating), 1)::numeric(3,2)
         FROM public.reviews AS r WHERE r.lawyer_id = v_lawyer_id
     ), 0),
         updated_at = now()
   WHERE l.id = v_lawyer_id;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$
DROP TRIGGER IF EXISTS trg_reviews_recalculate_lawyer_rating ON public.reviews
CREATE TRIGGER trg_reviews_recalculate_lawyer_rating
  AFTER INSERT OR UPDATE OF rating OR DELETE ON public.reviews
  FOR EACH ROW
  EXECUTE FUNCTION public.recalculate_lawyer_rating_from_reviews()
-- Idempotent favorite insert uses the existing unique key and caller identity.
CREATE OR REPLACE FUNCTION public.rpc_favorite_add(p_lawyer_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_actor text := public.current_app_user_id();
  v_favorite public.favorites%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR v_actor IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AUTHENTICATION_REQUIRED';
  END IF;
  INSERT INTO public.favorites (user_id, lawyer_id)
  VALUES (v_actor, p_lawyer_id)
  ON CONFLICT (user_id, lawyer_id) DO UPDATE SET lawyer_id = EXCLUDED.lawyer_id
  RETURNING * INTO v_favorite;
  RETURN to_jsonb(v_favorite);
END;
$$
-- Role assignment is a database-checked admin operation. No client metadata or
-- direct users-table grant can promote an account.
CREATE OR REPLACE FUNCTION public.rpc_admin_set_user_role(p_user_id text, p_role text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_actor text := public.current_app_user_id();
  v_user public.users%ROWTYPE;
  v_admin_count integer;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'ADMIN_REQUIRED';
  END IF;
  IF p_role IS NULL OR p_role NOT IN ('client', 'lawyer', 'admin') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_ROLE';
  END IF;
  -- Serialize role changes so concurrent demotions cannot each observe two
  -- administrators and leave the project with none.
  PERFORM pg_advisory_xact_lock(hashtextextended('public.rpc_admin_set_user_role', 0));
  SELECT * INTO v_user FROM public.users WHERE id = p_user_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'USER_NOT_FOUND';
  END IF;
  IF v_user.role = 'admin' AND p_role <> 'admin' THEN
    SELECT count(*) INTO v_admin_count FROM public.users WHERE role = 'admin';
    IF v_admin_count <= 1 THEN
      RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'CANNOT_DEMOTE_LAST_ADMIN';
    END IF;
  END IF;
  UPDATE public.users SET role = p_role, updated_at = now()
   WHERE id = p_user_id RETURNING * INTO v_user;
  RETURN to_jsonb(v_user);
END;
$$
-- Dashboard values are aggregated inside the database, never through a client
-- using the service-role key. Only an authenticated admin may call this RPC.
CREATE OR REPLACE FUNCTION public.rpc_dashboard_stats()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'ADMIN_REQUIRED';
  END IF;
  RETURN jsonb_build_object(
    'users', (SELECT count(*) FROM public.users),
    'lawyers', (SELECT count(*) FROM public.lawyers),
    'cases', (SELECT count(*) FROM public.cases),
    'reviews', (SELECT count(*) FROM public.reviews),
    'plans', (SELECT count(*) FROM public.plans),
    'bookings', (SELECT count(*) FROM public.bookings),
    'activeBookings', (SELECT count(*) FROM public.bookings WHERE status = 'Confirmed'),
    'completedBookings', (SELECT count(*) FROM public.bookings WHERE status = 'Completed'),
    'cancelledBookings', (SELECT count(*) FROM public.bookings WHERE status = 'Cancelled'),
    'walletBalance', (SELECT COALESCE(sum(balance), 0) FROM public.wallets),
    'subscriptions', (SELECT count(*) FROM public.subscriptions)
  );
END;
$$
-- No public/anon execute on privileged workflows. Baseline rating and slot
-- reservation RPCs remain service_role-only for the Express adapter; the new
-- wallet RPC is authenticated-only and permits self-debits, never credits.
REVOKE ALL ON FUNCTION public.clock_time_minutes(text) FROM PUBLIC, anon, authenticated, service_role
REVOKE ALL ON FUNCTION public._sha256_hex(bytea) FROM PUBLIC, anon, authenticated, service_role
REVOKE ALL ON FUNCTION public._reserve_booking_slots(text, text, text, text, integer, integer) FROM PUBLIC, anon, authenticated, service_role
REVOKE ALL ON FUNCTION public._lock_booking_day(text, text) FROM PUBLIC, anon, authenticated, service_role
REVOKE ALL ON FUNCTION public.lock_schedule_change() FROM PUBLIC, anon, authenticated, service_role
REVOKE ALL ON FUNCTION public._booking_schedule_conflict(text, text, integer, integer, text) FROM PUBLIC, anon, authenticated, service_role
REVOKE ALL ON FUNCTION public.rpc_create_booking(text, text, text, integer, text, text) FROM PUBLIC, anon, service_role
REVOKE ALL ON FUNCTION public.rpc_cancel_booking(text) FROM PUBLIC, anon, service_role
REVOKE ALL ON FUNCTION public.rpc_admin_set_booking_status(text, text) FROM PUBLIC, anon, service_role
REVOKE ALL ON FUNCTION public.rpc_admin_reschedule_booking(text, text, text, text, integer) FROM PUBLIC, anon, service_role
REVOKE ALL ON FUNCTION public.rpc_delete_booking(text) FROM PUBLIC, anon, service_role
REVOKE ALL ON FUNCTION public.rpc_wallet_mutate(text, text, numeric, text, text) FROM PUBLIC, anon, authenticated, service_role
REVOKE ALL ON FUNCTION public.rpc_chat_create(text[], text) FROM PUBLIC, anon, service_role
REVOKE ALL ON FUNCTION public.rpc_chat_send_message(text, text) FROM PUBLIC, anon, service_role
REVOKE ALL ON FUNCTION public.rpc_case_set_status(text, text) FROM PUBLIC, anon, service_role
REVOKE ALL ON FUNCTION public.rpc_case_update(text, jsonb) FROM PUBLIC, anon, service_role
REVOKE ALL ON FUNCTION public.rpc_task_set_status(text, text) FROM PUBLIC, anon, service_role
REVOKE ALL ON FUNCTION public.rpc_task_update(text, jsonb) FROM PUBLIC, anon, service_role
REVOKE ALL ON FUNCTION public.rpc_notification_update(text, jsonb) FROM PUBLIC, anon, service_role
REVOKE ALL ON FUNCTION public.rpc_admin_assign_case_owner(text, text) FROM PUBLIC, anon, service_role
REVOKE ALL ON FUNCTION public.rpc_subscription_create(text, text) FROM PUBLIC, anon, service_role
REVOKE ALL ON FUNCTION public.rpc_subscription_cancel(text) FROM PUBLIC, anon, service_role
REVOKE ALL ON FUNCTION public.rpc_subscription_delete(text) FROM PUBLIC, anon, service_role
REVOKE ALL ON FUNCTION public.rpc_review_submit(text, numeric, text) FROM PUBLIC, anon, service_role
REVOKE ALL ON FUNCTION public.rpc_admin_review_moderate(text, numeric, text) FROM PUBLIC, anon, service_role
REVOKE ALL ON FUNCTION public.rpc_admin_review_delete(text) FROM PUBLIC, anon, service_role
REVOKE ALL ON FUNCTION public.rpc_review_delete(text) FROM PUBLIC, anon, service_role
REVOKE ALL ON FUNCTION public.recalculate_lawyer_rating_from_reviews() FROM PUBLIC, anon, authenticated, service_role
REVOKE ALL ON FUNCTION public.rpc_favorite_add(text) FROM PUBLIC, anon, service_role
REVOKE ALL ON FUNCTION public.rpc_admin_set_user_role(text, text) FROM PUBLIC, anon, service_role
REVOKE ALL ON FUNCTION public.rpc_dashboard_stats() FROM PUBLIC, anon, service_role
GRANT EXECUTE ON FUNCTION public.rpc_create_booking(text, text, text, integer, text, text) TO authenticated
GRANT EXECUTE ON FUNCTION public.rpc_cancel_booking(text) TO authenticated
GRANT EXECUTE ON FUNCTION public.rpc_admin_set_booking_status(text, text) TO authenticated
GRANT EXECUTE ON FUNCTION public.rpc_admin_reschedule_booking(text, text, text, text, integer) TO authenticated
GRANT EXECUTE ON FUNCTION public.rpc_delete_booking(text) TO authenticated
GRANT EXECUTE ON FUNCTION public.rpc_wallet_mutate(text, text, numeric, text, text) TO authenticated
GRANT EXECUTE ON FUNCTION public.rpc_chat_create(text[], text) TO authenticated
GRANT EXECUTE ON FUNCTION public.rpc_chat_send_message(text, text) TO authenticated
GRANT EXECUTE ON FUNCTION public.rpc_case_set_status(text, text) TO authenticated
GRANT EXECUTE ON FUNCTION public.rpc_case_update(text, jsonb) TO authenticated
GRANT EXECUTE ON FUNCTION public.rpc_task_set_status(text, text) TO authenticated
GRANT EXECUTE ON FUNCTION public.rpc_task_update(text, jsonb) TO authenticated
GRANT EXECUTE ON FUNCTION public.rpc_notification_update(text, jsonb) TO authenticated
GRANT EXECUTE ON FUNCTION public.rpc_admin_assign_case_owner(text, text) TO authenticated
GRANT EXECUTE ON FUNCTION public.rpc_subscription_create(text, text) TO authenticated
GRANT EXECUTE ON FUNCTION public.rpc_subscription_cancel(text) TO authenticated
GRANT EXECUTE ON FUNCTION public.rpc_subscription_delete(text) TO authenticated
GRANT EXECUTE ON FUNCTION public.rpc_review_submit(text, numeric, text) TO authenticated
GRANT EXECUTE ON FUNCTION public.rpc_admin_review_moderate(text, numeric, text) TO authenticated
GRANT EXECUTE ON FUNCTION public.rpc_admin_review_delete(text) TO authenticated
GRANT EXECUTE ON FUNCTION public.rpc_review_delete(text) TO authenticated
GRANT EXECUTE ON FUNCTION public.rpc_favorite_add(text) TO authenticated
GRANT EXECUTE ON FUNCTION public.rpc_admin_set_user_role(text, text) TO authenticated
GRANT EXECUTE ON FUNCTION public.rpc_dashboard_stats() TO authenticated
COMMIT