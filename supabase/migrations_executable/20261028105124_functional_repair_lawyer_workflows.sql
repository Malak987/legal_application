-- 4. Lawyer: own profile (lawyers.user_id is not publicly readable)
CREATE OR REPLACE FUNCTION public.rpc_lawyer_my_profile()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_actor text := public.current_app_user_id();
  v_items jsonb;
BEGIN
  IF auth.uid() IS NULL OR v_actor IS NULL
     OR public.current_app_user_role() <> 'lawyer' THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'LAWYER_REQUIRED';
  END IF;
  SELECT COALESCE(jsonb_agg(to_jsonb(l) ORDER BY l.created_at), '[]'::jsonb)
    INTO v_items
    FROM public.lawyers l WHERE l.user_id = v_actor;
  RETURN jsonb_build_object('items', v_items);
END;
$$;

-- 5. Lawyer/admin: publish a validated daily schedule
CREATE OR REPLACE FUNCTION public.rpc_lawyer_set_availability(
  p_lawyer_id text,
  p_date text,
  p_slots text[] DEFAULT ARRAY[]::text[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_actor      text := public.current_app_user_id();
  v_role       text := public.current_app_user_role();
  v_lawyer     public.lawyers%ROWTYPE;
  v_slots      text[];
  v_slots_json jsonb;
  v_invalid    integer;
  v_removed    integer;
  v_date       date;
  v_count      integer;
  v_row        public.availability%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR v_actor IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AUTHENTICATION_REQUIRED';
  END IF;

  SELECT * INTO v_lawyer FROM public.lawyers WHERE id = p_lawyer_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'LAWYER_NOT_FOUND';
  END IF;
  IF NOT public.is_admin() THEN
    IF v_role <> 'lawyer' OR v_lawyer.user_id IS DISTINCT FROM v_actor THEN
      RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'NOT_LAWYER_OWNER';
    END IF;
  END IF;

  IF p_date IS NULL OR NOT (p_date ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_BOOKING_DATE';
  END IF;
  BEGIN
    v_date := p_date::date;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_BOOKING_DATE';
  END;
  IF to_char(v_date, 'YYYY-MM-DD') <> p_date THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_BOOKING_DATE';
  END IF;
  IF v_date < (timezone('Africa/Cairo', now()))::date THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'DATE_IN_PAST';
  END IF;

  SELECT count(*) INTO v_invalid
    FROM unnest(COALESCE(p_slots, ARRAY[]::text[])) AS s
   WHERE s IS NULL OR NOT (s ~ '^([01][0-9]|2[0-3]):00$');
  IF v_invalid > 0 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_SLOT';
  END IF;
  SELECT COALESCE(array_agg(DISTINCT s ORDER BY s), ARRAY[]::text[])
    INTO v_slots
    FROM unnest(COALESCE(p_slots, ARRAY[]::text[])) AS s;
  IF cardinality(v_slots) > 24 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'TOO_MANY_SLOTS';
  END IF;
  v_slots_json := to_jsonb(v_slots);

  PERFORM public._lock_booking_day(p_lawyer_id, p_date);

  IF EXISTS (
    SELECT 1 FROM public.booking_slots bs
     WHERE bs.lawyer_id = p_lawyer_id AND bs.date = p_date
       AND NOT (to_char(make_time(bs.slot / 60, bs.slot % 60, 0), 'HH24:MI') = ANY(v_slots))
  ) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'BOOKED_SLOT_CANNOT_BE_REMOVED';
  END IF;

  FOR v_removed IN
    SELECT DISTINCT public.clock_time_minutes(value)
      FROM public.availability a
      CROSS JOIN LATERAL jsonb_array_elements_text(
        CASE WHEN jsonb_typeof(a.slots) = 'array' THEN a.slots ELSE '[]'::jsonb END
      ) AS value
     WHERE a.lawyer_id = p_lawyer_id AND a.date = p_date
       AND NOT (to_char(make_time(
             public.clock_time_minutes(value) / 60,
             public.clock_time_minutes(value) % 60, 0), 'HH24:MI') = ANY(v_slots))
       AND public.clock_time_minutes(value) IS NOT NULL
  LOOP
    IF public._booking_schedule_conflict(p_lawyer_id, p_date, v_removed, 1, NULL) IS NOT NULL THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'BOOKED_SLOT_CANNOT_BE_REMOVED';
    END IF;
  END LOOP;

  UPDATE public.availability
     SET slots = v_slots_json,
         lawyer_name = v_lawyer.name,
         updated_at = now()
   WHERE lawyer_id = p_lawyer_id AND date = p_date;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  IF v_count = 0 THEN
    INSERT INTO public.availability (lawyer_id, lawyer_name, date, slots)
    VALUES (p_lawyer_id, v_lawyer.name, p_date, v_slots_json)
    RETURNING * INTO v_row;
  ELSE
    SELECT * INTO v_row FROM public.availability
     WHERE lawyer_id = p_lawyer_id AND date = p_date
     ORDER BY created_at ASC LIMIT 1;
  END IF;

  RETURN jsonb_build_object('availability', to_jsonb(v_row), 'slots', v_slots_json);
END;
$$;

-- 6. Lawyer: own bookings with the linked client's display name
CREATE OR REPLACE FUNCTION public.rpc_lawyer_my_bookings(
  p_page integer DEFAULT 1,
  p_limit integer DEFAULT 100
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_actor text := public.current_app_user_id();
  v_total bigint;
  v_items jsonb;
BEGIN
  IF auth.uid() IS NULL OR v_actor IS NULL
     OR public.current_app_user_role() <> 'lawyer' THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'LAWYER_REQUIRED';
  END IF;
  IF p_page IS NULL OR p_page < 1 OR p_limit IS NULL OR p_limit < 1 OR p_limit > 100 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PAGE';
  END IF;

  SELECT count(*) INTO v_total
    FROM public.bookings b
    JOIN public.lawyers l ON l.id = b.lawyer_id
   WHERE l.user_id = v_actor;

  SELECT COALESCE(jsonb_agg(row_json ORDER BY created_at DESC), '[]'::jsonb)
    INTO v_items
    FROM (
      SELECT (to_jsonb(b) - 'idempotency_key_hash')
               || jsonb_build_object('client_name', COALESCE(u.name, '')) AS row_json,
             b.created_at
        FROM public.bookings b
        JOIN public.lawyers l ON l.id = b.lawyer_id
        LEFT JOIN public.users u ON u.id = b.user_id
       WHERE l.user_id = v_actor
       ORDER BY b.created_at DESC
       LIMIT p_limit OFFSET ((p_page - 1) * p_limit)
    ) AS page_rows;

  RETURN jsonb_build_object(
    'items', v_items, 'total', v_total, 'page', p_page, 'limit', p_limit,
    'totalPages', GREATEST(1, CEIL(v_total::numeric / p_limit)::integer)
  );
END;
$$;

-- 7. Assigned lawyer: accept / reject / complete / cancel a booking
CREATE OR REPLACE FUNCTION public.rpc_lawyer_set_booking_status(
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
  IF auth.uid() IS NULL OR public.current_app_user_id() IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AUTHENTICATION_REQUIRED';
  END IF;
  IF p_status IS NULL OR p_status NOT IN ('Confirmed', 'Completed', 'Cancelled') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_BOOKING_STATUS';
  END IF;

  SELECT * INTO v_booking FROM public.bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'BOOKING_NOT_FOUND';
  END IF;
  IF NOT private.is_current_user_lawyer_for(v_booking.lawyer_id) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'NOT_ASSIGNED_LAWYER';
  END IF;
  IF v_booking.status IN ('Completed', 'Cancelled') AND p_status <> v_booking.status THEN
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
$$;