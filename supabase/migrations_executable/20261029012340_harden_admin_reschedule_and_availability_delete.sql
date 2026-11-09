
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
SET search_path TO 'pg_catalog', 'public', 'private', 'pg_temp'
AS $function$
DECLARE
  v_booking public.bookings%ROWTYPE;
  v_lawyer public.lawyers%ROWTYPE;
  v_start integer;
  v_date date;
  v_available integer[];
  v_i integer;
  v_lock_ids text[];
  v_conflict text;
  v_local_now timestamp without time zone;
  v_today date;
  v_now_minute integer;
  v_horizon integer;
  v_schedule_configured boolean := false;
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

  v_local_now := timezone('Africa/Cairo', now());
  v_today := v_local_now::date;
  v_now_minute := extract(hour FROM v_local_now)::integer * 60
                + extract(minute FROM v_local_now)::integer;
  IF v_date < v_today OR (v_date = v_today AND v_start <= v_now_minute) THEN
    RETURN jsonb_build_object('error', 'SLOT_EXPIRED');
  END IF;

  SELECT * INTO v_booking
    FROM public.bookings
   WHERE id = p_booking_id
   FOR UPDATE;
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

  SELECT s.booking_horizon_days
    INTO v_horizon
    FROM public.lawyer_weekly_schedules AS s
   WHERE s.lawyer_id = p_lawyer_id;
  v_schedule_configured := FOUND;
  IF NOT v_schedule_configured THEN
    v_horizon := 365;
  END IF;
  IF v_date > v_today + v_horizon THEN
    RETURN jsonb_build_object('error', 'BOOKING_OUTSIDE_HORIZON');
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

    IF v_schedule_configured AND NOT EXISTS (
      SELECT 1
        FROM public.lawyer_weekly_intervals AS rule
       WHERE rule.lawyer_id = p_lawyer_id
         AND rule.weekday_iso = extract(isodow FROM v_date)::integer
         AND rule.start_minute <= v_start + (v_i * 60)
         AND rule.end_minute >= v_start + ((v_i + 1) * 60)
    ) THEN
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
$function$;

REVOKE DELETE ON TABLE public.availability FROM authenticated;
DROP POLICY IF EXISTS availability_write_owner_or_admin ON public.availability;
