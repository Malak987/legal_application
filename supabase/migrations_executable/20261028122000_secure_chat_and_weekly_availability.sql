-- Forward-only application change, validated against an isolated PostgreSQL 17 database.
-- Apply only through the authorized migration path after live compatibility checks.
--
-- Adds backend-enforced lawyer/client chat access and message pagination, plus
-- normalized recurring weekly rules and on-demand, idempotent availability
-- generation in Africa/Cairo wall-clock time. Booking rows and booking_slots are
-- never rewritten or deleted by schedule reconciliation.

BEGIN;

-- ---------------------------------------------------------------------------
-- Trusted chat authorization helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION private.chat_participant_can_read(p_chat_id text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, private, pg_temp
AS $function$
  SELECT COALESCE(
    auth.uid() IS NOT NULL
    AND private.current_app_user_id() IS NOT NULL
    AND EXISTS (
      SELECT 1
        FROM public.chats AS c
       WHERE c.id = p_chat_id
         AND cardinality(c.participants) = 2
         AND private.current_app_user_id() = ANY(c.participants)
         AND (
           (
             private.current_app_user_role() = 'client'
             AND EXISTS (
               SELECT 1 FROM public.users AS actor
                WHERE actor.id = private.current_app_user_id()
                  AND actor.role = 'client'
             )
             AND EXISTS (
               SELECT 1
                 FROM unnest(c.participants) AS peer(user_id)
                 JOIN public.users AS peer_user
                   ON peer_user.id = peer.user_id
                  AND peer_user.role = 'lawyer'
                 JOIN public.lawyers AS lawyer
                   ON lawyer.user_id = peer_user.id
                WHERE peer.user_id <> private.current_app_user_id()
             )
           )
           OR
           (
             private.current_app_user_role() = 'lawyer'
             AND EXISTS (
               SELECT 1 FROM public.users AS actor
                WHERE actor.id = private.current_app_user_id()
                  AND actor.role = 'lawyer'
             )
             AND (
               SELECT count(*) FROM public.lawyers AS own_lawyer
                WHERE own_lawyer.user_id = private.current_app_user_id()
             ) = 1
             AND EXISTS (
               SELECT 1
                 FROM unnest(c.participants) AS peer(user_id)
                 JOIN public.users AS peer_user
                   ON peer_user.id = peer.user_id
                  AND peer_user.role = 'client'
                WHERE peer.user_id <> private.current_app_user_id()
             )
           )
         )
    ),
    false
  );
$function$;

CREATE OR REPLACE FUNCTION private.can_read_chat(p_chat_id text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, private, pg_temp
AS $function$
  SELECT COALESCE(
    auth.uid() IS NOT NULL
    AND (
      private.is_admin()
      OR private.chat_participant_can_read(p_chat_id)
    ),
    false
  );
$function$;

CREATE OR REPLACE FUNCTION private.can_send_chat(p_chat_id text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, private, pg_temp
AS $function$
  SELECT private.chat_participant_can_read(p_chat_id);
$function$;

REVOKE ALL ON FUNCTION private.chat_participant_can_read(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION private.can_read_chat(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION private.can_send_chat(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.chat_participant_can_read(text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.can_read_chat(text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.can_send_chat(text) TO authenticated, service_role;

-- Remove the broad participant/admin policy and any historical permissive
-- write-policy names. Authenticated clients retain SELECT only; all writes go
-- through role- and relationship-checked RPCs.
DROP POLICY IF EXISTS chats_select_participant_or_admin ON public.chats;
DROP POLICY IF EXISTS chats_insert_participant_or_admin ON public.chats;
DROP POLICY IF EXISTS chats_update_participant_or_admin ON public.chats;
DROP POLICY IF EXISTS chats_delete_participant_or_admin ON public.chats;
DROP POLICY IF EXISTS chat_messages_select_participant_or_admin ON public.chat_messages;
DROP POLICY IF EXISTS chat_messages_insert_participant_or_admin ON public.chat_messages;
DROP POLICY IF EXISTS chat_messages_update_participant_or_admin ON public.chat_messages;
DROP POLICY IF EXISTS chat_messages_delete_admin_only ON public.chat_messages;
DROP POLICY IF EXISTS chat_messages_delete_participant_or_admin ON public.chat_messages;

CREATE POLICY chats_select_authorized_pair_or_owner
  ON public.chats FOR SELECT TO authenticated
  USING (private.can_read_chat(id));

CREATE POLICY chat_messages_select_authorized_pair_or_owner
  ON public.chat_messages FOR SELECT TO authenticated
  USING (private.can_read_chat(chat_id));

REVOKE INSERT, UPDATE, DELETE ON public.chats FROM PUBLIC, anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.chat_messages FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.chats, public.chat_messages TO authenticated;

-- Lawyers and owners/admins get a safe, server-scoped inbox page. Names and
-- preview come from trusted rows; the caller never supplies participant IDs.
CREATE OR REPLACE FUNCTION public.rpc_chat_list(
  p_page integer DEFAULT 1,
  p_limit integer DEFAULT 50
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, private, pg_temp
AS $function$
DECLARE
  v_actor text := private.current_app_user_id();
  v_role text := private.current_app_user_role();
  v_total bigint;
  v_items jsonb;
BEGIN
  IF auth.uid() IS NULL OR v_actor IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AUTHENTICATION_REQUIRED';
  END IF;
  IF v_role NOT IN ('client', 'lawyer', 'admin', 'owner') THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'CHAT_NOT_ALLOWED';
  END IF;
  IF p_page IS NULL OR p_page < 1 OR p_limit IS NULL OR p_limit < 1 OR p_limit > 100 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_CHAT_PAGE';
  END IF;

  SELECT count(*) INTO v_total
    FROM public.chats AS c
   WHERE private.can_read_chat(c.id);

  SELECT COALESCE(
           jsonb_agg(page.item ORDER BY page.updated_at DESC, page.created_at DESC, page.chat_id DESC),
           '[]'::jsonb
         )
    INTO v_items
    FROM (
      SELECT
        c.id AS chat_id,
        c.created_at,
        c.updated_at,
        jsonb_build_object(
          'id', c.id,
          'client_name', COALESCE(client_participant.display_name, 'Client'),
          'lawyer_name', COALESCE(lawyer_participant.display_name, 'Lawyer'),
          'last_message', COALESCE(c.last_message, ''),
          'created_at', c.created_at,
          'updated_at', c.updated_at,
          'recent_activity', COALESCE(c.updated_at >= now() - interval '24 hours', false),
          'booking_id', c.booking_id,
          'case_id', c.case_id
        ) AS item
      FROM public.chats AS c
      LEFT JOIN LATERAL (
        SELECT u.name AS display_name
          FROM unnest(c.participants) AS p(user_id)
          JOIN public.users AS u ON u.id = p.user_id AND u.role = 'client'
         ORDER BY u.id
         LIMIT 1
      ) AS client_participant ON true
      LEFT JOIN LATERAL (
        SELECT l.name AS display_name
          FROM unnest(c.participants) AS p(user_id)
          JOIN public.users AS u ON u.id = p.user_id AND u.role = 'lawyer'
          JOIN public.lawyers AS l ON l.user_id = u.id
         ORDER BY l.id
         LIMIT 1
      ) AS lawyer_participant ON true
      WHERE private.can_read_chat(c.id)
      ORDER BY c.updated_at DESC, c.created_at DESC, c.id DESC
      LIMIT p_limit
      OFFSET ((p_page::bigint - 1) * p_limit)
    ) AS page;

  RETURN jsonb_build_object(
    'items', v_items,
    'page', p_page,
    'limit', p_limit,
    'total', v_total,
    'total_pages', GREATEST(1, CEIL(v_total::numeric / p_limit)::integer),
    'has_more', (p_page::bigint * p_limit) < v_total
  );
END;
$function$;

-- Stable keyset pagination avoids duplicate/gapped history when new messages
-- arrive while an older page is being fetched. The newest page is returned in
-- ascending display order and carries a cursor for the next older page.
CREATE OR REPLACE FUNCTION public.rpc_chat_messages_page(
  p_chat_id text,
  p_before_created_at timestamptz DEFAULT NULL,
  p_before_id text DEFAULT NULL,
  p_limit integer DEFAULT 100
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, private, pg_temp
AS $function$
DECLARE
  v_items jsonb;
  v_has_more boolean;
  v_before_created_at timestamptz;
  v_before_id text;
BEGIN
  IF auth.uid() IS NULL OR private.current_app_user_id() IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AUTHENTICATION_REQUIRED';
  END IF;
  IF p_chat_id IS NULL OR NOT private.can_read_chat(p_chat_id) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'CHAT_NOT_FOUND_OR_FORBIDDEN';
  END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_CHAT_PAGE';
  END IF;
  IF (p_before_created_at IS NULL) <> (p_before_id IS NULL) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_CHAT_CURSOR';
  END IF;

  WITH candidates AS (
    SELECT m.id, m.chat_id, m.sender_id, m.sender_name, m.text, m.created_at
      FROM public.chat_messages AS m
     WHERE m.chat_id = p_chat_id
       AND (
         p_before_created_at IS NULL
         OR (m.created_at, m.id) < (p_before_created_at, p_before_id)
       )
     ORDER BY m.created_at DESC, m.id DESC
     LIMIT (p_limit + 1)
  ), page_rows AS (
    SELECT * FROM candidates
     ORDER BY created_at DESC, id DESC
     LIMIT p_limit
  )
  SELECT
    COALESCE(
      (SELECT jsonb_agg(to_jsonb(display_row) ORDER BY display_row.created_at, display_row.id)
         FROM page_rows AS display_row),
      '[]'::jsonb
    ),
    (SELECT count(*) > p_limit FROM candidates),
    (SELECT created_at FROM page_rows ORDER BY created_at, id LIMIT 1),
    (SELECT id FROM page_rows ORDER BY created_at, id LIMIT 1)
  INTO v_items, v_has_more, v_before_created_at, v_before_id;

  RETURN jsonb_build_object(
    'items', v_items,
    'has_more', COALESCE(v_has_more, false),
    'next_before_created_at', v_before_created_at,
    'next_before_id', v_before_id
  );
END;
$function$;

-- The existing start-with-lawyer RPC is also called directly by the mobile
-- client, so hardening only rpc_chat_create would leave an alternate path for a
-- client to open an unrelated lawyer conversation. Require a live booking or
-- assigned case for either participant role, and lock the chosen relationship
-- row until this transaction finishes.
CREATE OR REPLACE FUNCTION public.rpc_chat_start_with_lawyer(
  p_lawyer_id text,
  p_initial_message text DEFAULT NULL,
  p_client_id text DEFAULT NULL,
  p_booking_id text DEFAULT NULL,
  p_case_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private, pg_temp
AS $function$
DECLARE
  v_actor text := private.current_app_user_id();
  v_role text := private.current_app_user_role();
  v_lawyer public.lawyers%ROWTYPE;
  v_lawyer_user text;
  v_client text;
  v_pair text[];
  v_chat public.chats%ROWTYPE;
  v_names jsonb;
  v_text text := NULLIF(btrim(p_initial_message), '');
  v_booking text := NULLIF(btrim(COALESCE(p_booking_id, '')), '');
  v_case text := NULLIF(btrim(COALESCE(p_case_id, '')), '');
  v_reused boolean := false;
BEGIN
  IF auth.uid() IS NULL OR v_actor IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AUTHENTICATION_REQUIRED';
  END IF;
  IF v_text IS NOT NULL AND char_length(v_text) > 4000 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'MESSAGE_TOO_LONG';
  END IF;

  SELECT * INTO v_lawyer FROM public.lawyers WHERE id = p_lawyer_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'LAWYER_NOT_FOUND';
  END IF;
  v_lawyer_user := NULLIF(btrim(COALESCE(v_lawyer.user_id, '')), '');
  IF v_lawyer_user IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.users WHERE id = v_lawyer_user AND role = 'lawyer'
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'LAWYER_ACCOUNT_NOT_LINKED';
  END IF;

  IF v_role = 'client' THEN
    IF NULLIF(btrim(COALESCE(p_client_id, '')), '') IS NOT NULL
       AND btrim(p_client_id) <> v_actor THEN
      RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'NOT_CHAT_PARTICIPANT';
    END IF;
    v_client := v_actor;

    -- A client may contact only a lawyer to whom this trusted application
    -- profile is already connected by a booking or a case. This applies even
    -- when the chat already exists: the call must not become a relationship
    -- bypass for opening/creating a conversation.
    PERFORM 1 FROM public.bookings AS b
     WHERE b.lawyer_id = p_lawyer_id AND b.user_id = v_client
     LIMIT 1
     FOR SHARE;
    IF NOT FOUND THEN
      PERFORM 1 FROM public.cases AS c
       WHERE c.lawyer_id = p_lawyer_id AND c.user_id = v_client
       LIMIT 1
       FOR SHARE;
    END IF;
    IF NOT FOUND THEN
      RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'NO_LAWYER_RELATIONSHIP';
    END IF;
  ELSIF v_role = 'lawyer' AND v_actor = v_lawyer_user THEN
    v_client := NULLIF(btrim(COALESCE(p_client_id, '')), '');
    IF v_client IS NULL OR NOT EXISTS (
      SELECT 1 FROM public.users WHERE id = v_client AND role = 'client'
    ) THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'UNKNOWN_CHAT_PARTICIPANT';
    END IF;
    -- Lawyers can initiate only toward a client already assigned through a
    -- booking or case; the relationship is locked through chat creation.
    PERFORM 1 FROM public.bookings AS b
     WHERE b.lawyer_id = p_lawyer_id AND b.user_id = v_client
     LIMIT 1
     FOR SHARE;
    IF NOT FOUND THEN
      PERFORM 1 FROM public.cases AS c
       WHERE c.lawyer_id = p_lawyer_id AND c.user_id = v_client
       LIMIT 1
       FOR SHARE;
    END IF;
    IF NOT FOUND THEN
      RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'NO_CLIENT_RELATIONSHIP';
    END IF;
  ELSE
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'CHAT_NOT_ALLOWED';
  END IF;

  IF v_booking IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.bookings
     WHERE id = v_booking AND lawyer_id = p_lawyer_id AND user_id = v_client
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_CHAT_CONTEXT';
  END IF;
  IF v_case IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.cases
     WHERE id = v_case AND lawyer_id = p_lawyer_id AND user_id = v_client
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_CHAT_CONTEXT';
  END IF;

  SELECT array_agg(DISTINCT x ORDER BY x) INTO v_pair
    FROM unnest(ARRAY[v_client, v_lawyer_user]) AS x;

  -- Serialize concurrent opens of the same pair so at most one chat is created.
  PERFORM pg_advisory_xact_lock(
    hashtextextended('chat-pair:' || array_to_string(v_pair, '|'), 0)
  );

  SELECT * INTO v_chat
    FROM public.chats
   WHERE participants = v_pair
     AND booking_id IS NOT DISTINCT FROM v_booking
     AND case_id IS NOT DISTINCT FROM v_case
   ORDER BY created_at ASC
   LIMIT 1
   FOR UPDATE;

  IF FOUND THEN
    v_reused := true;
  ELSE
    SELECT jsonb_object_agg(id, name) INTO v_names
      FROM public.users WHERE id = ANY(v_pair);
    INSERT INTO public.chats (
      participants, participant_names, last_message, booking_id, case_id
    ) VALUES (
      v_pair, COALESCE(v_names, '{}'::jsonb), COALESCE(v_text, ''), v_booking, v_case
    ) RETURNING * INTO v_chat;

    IF v_text IS NOT NULL THEN
      INSERT INTO public.chat_messages (chat_id, sender_id, sender_name, text)
      SELECT v_chat.id, v_actor,
             COALESCE(NULLIF(btrim(u.name), ''), 'User'), v_text
        FROM public.users AS u WHERE u.id = v_actor;
      UPDATE public.chats SET updated_at = now()
       WHERE id = v_chat.id RETURNING * INTO v_chat;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'chat', to_jsonb(v_chat),
    'reused', v_reused,
    'clientId', v_client,
    'lawyerUserId', v_lawyer_user
  );
END;
$function$;

-- The old generic RPC accepted arbitrary multi-user arrays. Preserve its
-- compatibility signature, but route only a trusted client/lawyer pair through
-- the relationship-checked start-with-lawyer RPC above.
CREATE OR REPLACE FUNCTION public.rpc_chat_create(
  p_participants text[],
  p_initial_message text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private, pg_temp
AS $function$
DECLARE
  v_actor text := private.current_app_user_id();
  v_role text := private.current_app_user_role();
  v_participants text[];
  v_other text;
  v_lawyer_id text;
  v_profile_count integer;
BEGIN
  IF auth.uid() IS NULL OR v_actor IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AUTHENTICATION_REQUIRED';
  END IF;
  SELECT array_agg(DISTINCT btrim(value) ORDER BY btrim(value))
    INTO v_participants
    FROM unnest(COALESCE(p_participants, ARRAY[]::text[])) AS participants(value)
   WHERE NULLIF(btrim(value), '') IS NOT NULL;
  IF COALESCE(cardinality(v_participants), 0) <> 2 OR NOT (v_actor = ANY(v_participants)) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'CHAT_MUST_BE_A_LAWYER_CLIENT_PAIR';
  END IF;
  SELECT participant INTO v_other
    FROM unnest(v_participants) AS pair(participant)
   WHERE participant <> v_actor
   LIMIT 1;

  IF v_role = 'client' THEN
    SELECT l.id INTO v_lawyer_id
      FROM public.lawyers AS l
      JOIN public.users AS u ON u.id = l.user_id AND u.role = 'lawyer'
     WHERE u.id = v_other
     ORDER BY l.id
     LIMIT 1;
    IF v_lawyer_id IS NULL THEN
      RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'CHAT_MUST_BE_A_LAWYER_CLIENT_PAIR';
    END IF;
    RETURN public.rpc_chat_start_with_lawyer(v_lawyer_id, p_initial_message, NULL, NULL, NULL);
  ELSIF v_role = 'lawyer' THEN
    SELECT count(*), min(l.id) INTO v_profile_count, v_lawyer_id
      FROM public.lawyers AS l
      JOIN public.users AS u ON u.id = l.user_id AND u.role = 'lawyer'
     WHERE u.id = v_actor;
    IF v_profile_count <> 1 OR NOT EXISTS (
      SELECT 1 FROM public.users AS client
       WHERE client.id = v_other AND client.role = 'client'
    ) THEN
      RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'CHAT_MUST_BE_A_LAWYER_CLIENT_PAIR';
    END IF;
    RETURN public.rpc_chat_start_with_lawyer(v_lawyer_id, p_initial_message, v_other, NULL, NULL);
  END IF;

  RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'CHAT_NOT_ALLOWED';
END;
$function$;

-- Remove the older non-idempotent two-argument overload. It authorized any
-- participant (and admins) and would otherwise bypass the verified-pair,
-- read-only-owner contract or make PostgREST overload resolution ambiguous.
DROP FUNCTION IF EXISTS public.rpc_chat_send_message(text, text);

-- Reuse the existing message RPC's idempotent insert shape, but do not let an
-- owner/admin impersonate either participant. Only a verified pair can send.
CREATE OR REPLACE FUNCTION public.rpc_chat_send_message(
  p_chat_id text,
  p_text text,
  p_client_message_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private, pg_temp
AS $function$
DECLARE
  v_actor text := private.current_app_user_id();
  v_chat public.chats%ROWTYPE;
  v_message public.chat_messages%ROWTYPE;
  v_existing public.chat_messages%ROWTYPE;
  v_name text;
  v_text text := btrim(COALESCE(p_text, ''));
  v_client_id text := NULLIF(btrim(COALESCE(p_client_message_id, '')), '');
BEGIN
  IF auth.uid() IS NULL OR v_actor IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AUTHENTICATION_REQUIRED';
  END IF;
  IF v_text = '' OR char_length(v_text) > 4000 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_MESSAGE';
  END IF;
  IF v_client_id IS NOT NULL AND v_client_id !~ '^[A-Za-z0-9_-]{8,128}$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_MESSAGE_ID';
  END IF;

  IF p_chat_id IS NULL OR NOT private.can_send_chat(p_chat_id) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'NOT_CHAT_PARTICIPANT';
  END IF;
  SELECT * INTO v_chat FROM public.chats WHERE id = p_chat_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'CHAT_NOT_FOUND';
  END IF;

  IF v_client_id IS NOT NULL THEN
    -- Serialize reuse of an id across different chats as well as retries in
    -- the same chat; the primary key is global to chat_messages.
    PERFORM pg_advisory_xact_lock(
      hashtextextended('chat-message:' || v_client_id, 0)
    );
    SELECT * INTO v_existing FROM public.chat_messages WHERE id = v_client_id;
    IF FOUND THEN
      IF v_existing.chat_id <> p_chat_id
         OR v_existing.sender_id <> v_actor
         OR v_existing.text <> v_text THEN
        RAISE EXCEPTION USING ERRCODE = '23505', MESSAGE = 'MESSAGE_ID_CONFLICT';
      END IF;
      RETURN to_jsonb(v_existing) || jsonb_build_object('replayed', true);
    END IF;
  END IF;

  SELECT name INTO v_name FROM public.users WHERE id = v_actor;
  INSERT INTO public.chat_messages (id, chat_id, sender_id, sender_name, text)
  VALUES (
    COALESCE(v_client_id, gen_random_uuid()::text),
    v_chat.id,
    v_actor,
    COALESCE(NULLIF(btrim(v_name), ''), 'User'),
    v_text
  ) RETURNING * INTO v_message;

  UPDATE public.chats SET last_message = v_text, updated_at = now()
   WHERE id = v_chat.id;
  RETURN to_jsonb(v_message) || jsonb_build_object('replayed', false);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_chat_start_with_lawyer(text, text, text, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_chat_list(integer, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_chat_messages_page(text, timestamptz, text, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_chat_create(text[], text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_chat_send_message(text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_chat_start_with_lawyer(text, text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_chat_list(integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_chat_messages_page(text, timestamptz, text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_chat_create(text[], text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_chat_send_message(text, text, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Normalized weekly schedules (ISO weekdays: Monday=1 ... Sunday=7)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.lawyer_weekly_schedules (
  lawyer_id text PRIMARY KEY REFERENCES public.lawyers(id) ON DELETE CASCADE,
  timezone text NOT NULL DEFAULT 'Africa/Cairo' CHECK (timezone = 'Africa/Cairo'),
  booking_horizon_days integer NOT NULL DEFAULT 90
    CHECK (booking_horizon_days BETWEEN 1 AND 365),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.lawyer_weekly_intervals (
  id text PRIMARY KEY DEFAULT gen_random_uuid()::text,
  lawyer_id text NOT NULL REFERENCES public.lawyer_weekly_schedules(lawyer_id) ON DELETE CASCADE,
  weekday_iso smallint NOT NULL CHECK (weekday_iso BETWEEN 1 AND 7),
  start_minute integer NOT NULL
    CHECK (start_minute >= 0 AND start_minute < 1440 AND start_minute % 60 = 0),
  end_minute integer NOT NULL
    CHECK (end_minute > 0 AND end_minute <= 1440 AND end_minute % 60 = 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (end_minute > start_minute),
  UNIQUE (lawyer_id, weekday_iso, start_minute)
);

CREATE INDEX IF NOT EXISTS lawyer_weekly_intervals_by_weekday
  ON public.lawyer_weekly_intervals (lawyer_id, weekday_iso, start_minute);

ALTER TABLE public.lawyer_weekly_schedules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lawyer_weekly_schedules FORCE ROW LEVEL SECURITY;
ALTER TABLE public.lawyer_weekly_intervals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lawyer_weekly_intervals FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS lawyer_weekly_schedules_owner_read ON public.lawyer_weekly_schedules;
CREATE POLICY lawyer_weekly_schedules_owner_read
  ON public.lawyer_weekly_schedules FOR SELECT TO authenticated
  USING (private.is_admin() OR private.is_current_user_lawyer_for(lawyer_id));
DROP POLICY IF EXISTS lawyer_weekly_intervals_owner_read ON public.lawyer_weekly_intervals;
CREATE POLICY lawyer_weekly_intervals_owner_read
  ON public.lawyer_weekly_intervals FOR SELECT TO authenticated
  USING (private.is_admin() OR private.is_current_user_lawyer_for(lawyer_id));
REVOKE ALL ON public.lawyer_weekly_schedules FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.lawyer_weekly_intervals FROM PUBLIC, anon, authenticated;

-- Keep the legacy daily editor usable only for lawyers without a recurring
-- schedule. Once weekly rules exist, the normalized schedule is authoritative;
-- old clients cannot silently overwrite its generated date rows.
ALTER FUNCTION public.rpc_lawyer_set_availability(text, text, text[])
  SET SCHEMA private;
ALTER FUNCTION private.rpc_lawyer_set_availability(text, text, text[])
  RENAME TO rpc_lawyer_set_availability_legacy_core;
REVOKE ALL ON FUNCTION private.rpc_lawyer_set_availability_legacy_core(text, text, text[])
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.rpc_lawyer_set_availability(
  p_lawyer_id text,
  p_date text,
  p_slots text[] DEFAULT ARRAY[]::text[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private, pg_temp
AS $function$
DECLARE
  v_actor text := private.current_app_user_id();
BEGIN
  IF auth.uid() IS NULL OR v_actor IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AUTHENTICATION_REQUIRED';
  END IF;
  IF NOT private.is_admin() AND NOT private.is_current_user_lawyer_for(p_lawyer_id) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'NOT_LAWYER_OWNER';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.lawyer_weekly_schedules AS s
     WHERE s.lawyer_id = p_lawyer_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'WEEKLY_SCHEDULE_IS_AUTHORITATIVE';
  END IF;
  RETURN private.rpc_lawyer_set_availability_legacy_core(
    p_lawyer_id, p_date, p_slots
  );
END;
$function$;
REVOKE ALL ON FUNCTION public.rpc_lawyer_set_availability(text, text, text[])
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_lawyer_set_availability(text, text, text[])
  TO authenticated;

CREATE OR REPLACE FUNCTION private.weekly_time_to_minute(
  p_value text,
  p_is_end boolean DEFAULT false
)
RETURNS integer
LANGUAGE plpgsql
IMMUTABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, private, pg_temp
AS $function$
DECLARE
  v_value text := btrim(COALESCE(p_value, ''));
  v_minute integer;
BEGIN
  IF p_is_end AND v_value = '24:00' THEN
    RETURN 1440;
  END IF;
  IF v_value !~ '^(0[0-9]|1[0-9]|2[0-3]):00$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_WEEKLY_TIME';
  END IF;
  v_minute := public.clock_time_minutes(v_value);
  IF v_minute IS NULL OR v_minute % 60 <> 0 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_WEEKLY_TIME';
  END IF;
  RETURN v_minute;
END;
$function$;

CREATE OR REPLACE FUNCTION private.try_iso_date(p_value text)
RETURNS date
LANGUAGE plpgsql
IMMUTABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, private, pg_temp
AS $function$
DECLARE
  v_date date;
BEGIN
  IF p_value IS NULL OR p_value !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN
    RETURN NULL;
  END IF;
  BEGIN
    v_date := p_value::date;
  EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
  END;
  IF to_char(v_date, 'YYYY-MM-DD') <> p_value THEN
    RETURN NULL;
  END IF;
  RETURN v_date;
END;
$function$;

CREATE OR REPLACE FUNCTION private.guard_weekly_interval_overlap()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private, pg_temp
AS $function$
BEGIN
  PERFORM pg_advisory_xact_lock(
    hashtextextended('weekly-interval:' || NEW.lawyer_id || ':' || NEW.weekday_iso::text, 0)
  );
  IF EXISTS (
    SELECT 1
      FROM public.lawyer_weekly_intervals AS existing
     WHERE existing.lawyer_id = NEW.lawyer_id
       AND existing.weekday_iso = NEW.weekday_iso
       AND existing.id IS DISTINCT FROM NEW.id
       AND existing.start_minute < NEW.end_minute
       AND NEW.start_minute < existing.end_minute
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'WEEKLY_INTERVAL_OVERLAP';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS lawyer_weekly_intervals_no_overlap ON public.lawyer_weekly_intervals;
CREATE TRIGGER lawyer_weekly_intervals_no_overlap
  BEFORE INSERT OR UPDATE OF lawyer_id, weekday_iso, start_minute, end_minute
  ON public.lawyer_weekly_intervals
  FOR EACH ROW EXECUTE FUNCTION private.guard_weekly_interval_overlap();

-- Converts recurring rules into date-specific availability rows. The generated
-- range is bounded, uses Egypt-local dates, and shares the existing per-day
-- advisory lock with booking creation. It changes availability only; booked
-- slots/bookings are inspected for conflicts and never updated or deleted.
CREATE OR REPLACE FUNCTION private.generate_lawyer_availability(p_lawyer_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private, pg_temp
AS $function$
DECLARE
  v_lawyer public.lawyers%ROWTYPE;
  v_horizon integer;
  v_today date;
  v_through date;
  v_local_now timestamp without time zone;
  v_now_minute integer;
  v_date date;
  v_date_text text;
  v_slots text[];
  v_slots_json jsonb;
  v_rows integer;
  v_day_conflicts integer;
  v_total_conflicts integer := 0;
  v_conflict_dates jsonb := '[]'::jsonb;
BEGIN
  IF p_lawyer_id IS NULL OR btrim(p_lawyer_id) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'LAWYER_NOT_FOUND';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('weekly-schedule:' || p_lawyer_id, 0));

  SELECT * INTO v_lawyer FROM public.lawyers AS l WHERE l.id = p_lawyer_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'LAWYER_NOT_FOUND';
  END IF;
  SELECT s.booking_horizon_days INTO v_horizon
    FROM public.lawyer_weekly_schedules AS s
   WHERE s.lawyer_id = p_lawyer_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'configured', false,
      'timezone', 'Africa/Cairo',
      'horizon_days', 365,
      'generated_through', NULL,
      'booking_conflict_count', 0,
      'conflict_dates', '[]'::jsonb
    );
  END IF;

  v_local_now := timezone('Africa/Cairo', now());
  v_today := v_local_now::date;
  v_now_minute := (extract(hour FROM v_local_now)::integer * 60)
                + extract(minute FROM v_local_now)::integer;
  v_through := v_today + v_horizon;

  FOR v_date IN
    SELECT dates.day
      FROM (
        SELECT generated.day::date AS day
          FROM generate_series(v_today::timestamp, v_through::timestamp, interval '1 day') AS generated(day)
        UNION
        SELECT private.try_iso_date(a.date) AS day
          FROM public.availability AS a
         WHERE a.lawyer_id = p_lawyer_id
           AND private.try_iso_date(a.date) >= v_today
      ) AS dates
     WHERE dates.day IS NOT NULL
     ORDER BY dates.day
  LOOP
    v_date_text := to_char(v_date, 'YYYY-MM-DD');
    PERFORM public._lock_booking_day(p_lawyer_id, v_date_text);

    IF v_date <= v_through THEN
      SELECT COALESCE(
               array_agg(to_char(make_time(slots.minute / 60, slots.minute % 60, 0), 'HH24:MI')
                         ORDER BY slots.minute),
               ARRAY[]::text[]
             )
        INTO v_slots
        FROM (
          SELECT DISTINCT generated_slot.minute
            FROM public.lawyer_weekly_intervals AS rule
            CROSS JOIN LATERAL generate_series(
              rule.start_minute,
              rule.end_minute - 60,
              60
            ) AS generated_slot(minute)
           WHERE rule.lawyer_id = p_lawyer_id
             AND rule.weekday_iso = extract(isodow FROM v_date)::integer
             AND (v_date > v_today OR generated_slot.minute > v_now_minute)
        ) AS slots;
    ELSE
      v_slots := ARRAY[]::text[];
    END IF;
    v_slots_json := to_jsonb(COALESCE(v_slots, ARRAY[]::text[]));

    SELECT count(*)::integer
      INTO v_day_conflicts
      FROM public.bookings AS b
      CROSS JOIN LATERAL (
        SELECT public.clock_time_minutes(b.time) AS start_minute
      ) AS booking_time
     WHERE b.lawyer_id = p_lawyer_id
       AND b.date = v_date_text
       AND b.status <> 'Cancelled'
       AND (
         v_date > v_through
         OR v_date > v_today
         OR booking_time.start_minute IS NULL
         OR b.hours IS NULL
         OR b.hours < 1
         OR booking_time.start_minute + (b.hours * 60) > v_now_minute
       )
       AND (
         v_date > v_through
         OR booking_time.start_minute IS NULL
         OR b.hours IS NULL
         OR b.hours < 1
         OR EXISTS (
           SELECT 1
             FROM generate_series(
               booking_time.start_minute,
               booking_time.start_minute + (b.hours * 60) - 60,
               60
             ) AS reserved(slot)
            WHERE (v_date > v_today OR reserved.slot > v_now_minute)
              AND NOT EXISTS (
                SELECT 1
                  FROM unnest(COALESCE(v_slots, ARRAY[]::text[])) AS expected(slot_text)
                 WHERE public.clock_time_minutes(expected.slot_text) = reserved.slot
              )
         )
       );
    IF v_day_conflicts > 0 THEN
      v_total_conflicts := v_total_conflicts + v_day_conflicts;
      v_conflict_dates := v_conflict_dates || jsonb_build_array(
        jsonb_build_object('date', v_date_text, 'booking_count', v_day_conflicts)
      );
    END IF;

    UPDATE public.availability AS a
       SET slots = v_slots_json,
           lawyer_name = v_lawyer.name,
           updated_at = now()
     WHERE a.lawyer_id = p_lawyer_id
       AND a.date = v_date_text
       AND (a.slots IS DISTINCT FROM v_slots_json OR a.lawyer_name IS DISTINCT FROM v_lawyer.name);
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows = 0 AND cardinality(COALESCE(v_slots, ARRAY[]::text[])) > 0
       AND NOT EXISTS (
         SELECT 1 FROM public.availability AS a
          WHERE a.lawyer_id = p_lawyer_id AND a.date = v_date_text
       ) THEN
      INSERT INTO public.availability (lawyer_id, lawyer_name, date, slots)
      VALUES (p_lawyer_id, v_lawyer.name, v_date_text, v_slots_json);
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'configured', true,
    'timezone', 'Africa/Cairo',
    'horizon_days', v_horizon,
    'generated_through', to_char(v_through, 'YYYY-MM-DD'),
    'booking_conflict_count', v_total_conflicts,
    'conflict_dates', v_conflict_dates
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_lawyer_my_weekly_schedule()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, private, pg_temp
AS $function$
DECLARE
  v_actor text := private.current_app_user_id();
  v_lawyer_id text;
  v_profile_count integer;
  v_horizon integer;
  v_rules jsonb;
BEGIN
  IF auth.uid() IS NULL OR v_actor IS NULL OR private.current_app_user_role() <> 'lawyer' THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'LAWYER_REQUIRED';
  END IF;
  SELECT count(*), min(l.id) INTO v_profile_count, v_lawyer_id
    FROM public.lawyers AS l
    JOIN public.users AS u ON u.id = l.user_id AND u.role = 'lawyer'
   WHERE l.user_id = v_actor;
  IF v_profile_count <> 1 THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'LAWYER_PROFILE_NOT_UNIQUE';
  END IF;

  SELECT s.booking_horizon_days INTO v_horizon
    FROM public.lawyer_weekly_schedules AS s
   WHERE s.lawyer_id = v_lawyer_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'configured', false,
      'timezone', 'Africa/Cairo',
      'horizon_days', 90,
      'rules', '[]'::jsonb
    );
  END IF;

  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'weekday_iso', i.weekday_iso,
               'start_time', to_char(make_time(i.start_minute / 60, i.start_minute % 60, 0), 'HH24:MI'),
               'end_time', CASE WHEN i.end_minute = 1440
                                THEN '24:00'
                                ELSE to_char(make_time(i.end_minute / 60, i.end_minute % 60, 0), 'HH24:MI')
                           END
             ) ORDER BY i.weekday_iso, i.start_minute
           ),
           '[]'::jsonb
         )
    INTO v_rules
    FROM public.lawyer_weekly_intervals AS i
   WHERE i.lawyer_id = v_lawyer_id;

  RETURN jsonb_build_object(
    'configured', true,
    'timezone', 'Africa/Cairo',
    'horizon_days', v_horizon,
    'rules', v_rules
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_lawyer_set_weekly_schedule(
  p_rules jsonb,
  p_horizon_days integer DEFAULT 90
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private, pg_temp
AS $function$
DECLARE
  v_actor text := private.current_app_user_id();
  v_lawyer_id text;
  v_profile_count integer;
  v_item jsonb;
  v_weekday_text text;
  v_start integer;
  v_end integer;
  v_horizon integer := COALESCE(p_horizon_days, 90);
  v_rules jsonb;
  v_generated jsonb;
BEGIN
  IF auth.uid() IS NULL OR v_actor IS NULL OR private.current_app_user_role() <> 'lawyer' THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'LAWYER_REQUIRED';
  END IF;
  IF v_horizon < 1 OR v_horizon > 365 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_BOOKING_HORIZON';
  END IF;
  IF p_rules IS NULL OR jsonb_typeof(p_rules) <> 'array' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_WEEKLY_SCHEDULE';
  END IF;
  IF jsonb_array_length(p_rules) > 168 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_WEEKLY_SCHEDULE';
  END IF;

  SELECT count(*), min(l.id) INTO v_profile_count, v_lawyer_id
    FROM public.lawyers AS l
    JOIN public.users AS u ON u.id = l.user_id AND u.role = 'lawyer'
   WHERE l.user_id = v_actor;
  IF v_profile_count <> 1 THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'LAWYER_PROFILE_NOT_UNIQUE';
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_rules) AS rule(value) LOOP
    IF jsonb_typeof(v_item) <> 'object' THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_WEEKLY_SCHEDULE';
    END IF;
    v_weekday_text := v_item ->> 'weekday_iso';
    IF v_weekday_text IS NULL OR v_weekday_text !~ '^[1-7]$' THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_WEEKLY_WEEKDAY';
    END IF;
    v_start := private.weekly_time_to_minute(v_item ->> 'start_time', false);
    v_end := private.weekly_time_to_minute(v_item ->> 'end_time', true);
    IF v_end <= v_start THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_WEEKLY_INTERVAL';
    END IF;
  END LOOP;

  IF EXISTS (
    SELECT 1
      FROM jsonb_array_elements(p_rules) WITH ORDINALITY AS a(rule, ordinal)
      JOIN jsonb_array_elements(p_rules) WITH ORDINALITY AS b(rule, ordinal)
        ON a.ordinal < b.ordinal
     WHERE a.rule ->> 'weekday_iso' = b.rule ->> 'weekday_iso'
       AND private.weekly_time_to_minute(a.rule ->> 'start_time', false)
           < private.weekly_time_to_minute(b.rule ->> 'end_time', true)
       AND private.weekly_time_to_minute(b.rule ->> 'start_time', false)
           < private.weekly_time_to_minute(a.rule ->> 'end_time', true)
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'WEEKLY_INTERVAL_OVERLAP';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('weekly-schedule:' || v_lawyer_id, 0));
  INSERT INTO public.lawyer_weekly_schedules (lawyer_id, timezone, booking_horizon_days, updated_at)
  VALUES (v_lawyer_id, 'Africa/Cairo', v_horizon, now())
  ON CONFLICT (lawyer_id) DO UPDATE
    SET timezone = EXCLUDED.timezone,
        booking_horizon_days = EXCLUDED.booking_horizon_days,
        updated_at = now();

  DELETE FROM public.lawyer_weekly_intervals WHERE lawyer_id = v_lawyer_id;
  INSERT INTO public.lawyer_weekly_intervals (lawyer_id, weekday_iso, start_minute, end_minute)
  SELECT
    v_lawyer_id,
    (rule.value ->> 'weekday_iso')::smallint,
    private.weekly_time_to_minute(rule.value ->> 'start_time', false),
    private.weekly_time_to_minute(rule.value ->> 'end_time', true)
  FROM jsonb_array_elements(p_rules) AS rule(value)
  ORDER BY 2, 3;

  v_generated := private.generate_lawyer_availability(v_lawyer_id);
  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'weekday_iso', i.weekday_iso,
               'start_time', to_char(make_time(i.start_minute / 60, i.start_minute % 60, 0), 'HH24:MI'),
               'end_time', CASE WHEN i.end_minute = 1440
                                THEN '24:00'
                                ELSE to_char(make_time(i.end_minute / 60, i.end_minute % 60, 0), 'HH24:MI')
                           END
             ) ORDER BY i.weekday_iso, i.start_minute
           ),
           '[]'::jsonb
         )
    INTO v_rules
    FROM public.lawyer_weekly_intervals AS i
   WHERE i.lawyer_id = v_lawyer_id;

  RETURN jsonb_build_object(
    'configured', true,
    'timezone', 'Africa/Cairo',
    'horizon_days', v_horizon,
    'rules', v_rules,
    'generated', v_generated
  );
END;
$function$;

-- Authenticated clients can request a bounded public availability view. If a
-- lawyer has not configured recurring hours, legacy date-specific schedules
-- remain readable for a compatibility window; configuring a weekly schedule
-- makes the generated horizon authoritative.
CREATE OR REPLACE FUNCTION public.rpc_refresh_lawyer_availability(p_lawyer_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private, pg_temp
AS $function$
DECLARE
  v_actor text := private.current_app_user_id();
  v_role text := private.current_app_user_role();
  v_generated jsonb;
  v_today date;
  v_through date;
  v_local_now timestamp without time zone;
  v_now_minute integer;
  v_horizon integer;
  v_items jsonb;
BEGIN
  IF auth.uid() IS NULL OR v_actor IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AUTHENTICATION_REQUIRED';
  END IF;
  IF v_role NOT IN ('client', 'lawyer', 'admin', 'owner') THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AVAILABILITY_NOT_ALLOWED';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.lawyers WHERE id = p_lawyer_id) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'LAWYER_NOT_FOUND';
  END IF;
  IF v_role = 'lawyer' AND NOT private.is_current_user_lawyer_for(p_lawyer_id) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'LAWYER_PROFILE_MISMATCH';
  END IF;

  v_generated := private.generate_lawyer_availability(p_lawyer_id);
  v_horizon := COALESCE((v_generated ->> 'horizon_days')::integer, 365);
  v_local_now := timezone('Africa/Cairo', now());
  v_today := v_local_now::date;
  v_now_minute := (extract(hour FROM v_local_now)::integer * 60)
                + extract(minute FROM v_local_now)::integer;
  v_through := v_today + v_horizon;

  WITH slot_rows AS (
    SELECT
      a.date,
      public.clock_time_minutes(slot_value.value) AS minute,
      min(slot_value.value) AS slot_label
    FROM public.availability AS a
    CROSS JOIN LATERAL jsonb_array_elements_text(
      CASE WHEN jsonb_typeof(a.slots) = 'array' THEN a.slots ELSE '[]'::jsonb END
    ) AS slot_value(value)
    WHERE a.lawyer_id = p_lawyer_id
      AND private.try_iso_date(a.date) BETWEEN v_today AND v_through
      AND public.clock_time_minutes(slot_value.value) IS NOT NULL
      AND (
        private.try_iso_date(a.date) > v_today
        OR public.clock_time_minutes(slot_value.value) > v_now_minute
      )
      AND NOT EXISTS (
        SELECT 1
          FROM public.booking_slots AS bs
          JOIN public.bookings AS b ON b.id = bs.booking_id
         WHERE bs.lawyer_id = p_lawyer_id
           AND bs.date = a.date
           AND bs.slot = public.clock_time_minutes(slot_value.value)
           AND b.status <> 'Cancelled'
      )
      -- Older bookings may predate booking_slots; do not advertise any
      -- hourly start that overlaps their stored date/time/duration either.
      AND NOT EXISTS (
        SELECT 1
          FROM public.bookings AS b
          CROSS JOIN LATERAL (
            SELECT public.clock_time_minutes(b.time) AS start_minute
          ) AS booking_time
         WHERE b.lawyer_id = p_lawyer_id
           AND b.date = a.date
           AND b.status <> 'Cancelled'
           AND (
             booking_time.start_minute IS NULL
             OR b.hours IS NULL
             OR b.hours < 1
             OR (
               public.clock_time_minutes(slot_value.value)
                 < booking_time.start_minute + (b.hours * 60)
               AND booking_time.start_minute
                 < public.clock_time_minutes(slot_value.value) + 60
             )
           )
      )
    GROUP BY a.date, public.clock_time_minutes(slot_value.value)
  ), daily_slots AS (
    SELECT date,
           jsonb_agg(slot_label ORDER BY minute) AS slots
      FROM slot_rows
     GROUP BY date
  ), representative_rows AS (
    SELECT DISTINCT ON (a.date)
           a.id, a.lawyer_id, a.lawyer_name, a.date, a.created_at, a.updated_at
      FROM public.availability AS a
      JOIN daily_slots AS d ON d.date = a.date
     WHERE a.lawyer_id = p_lawyer_id
     ORDER BY a.date, a.created_at, a.id
  )
  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'id', a.id,
               'lawyer_id', a.lawyer_id,
               'lawyer_name', a.lawyer_name,
               'date', a.date,
               'slots', d.slots,
               'created_at', a.created_at,
               'updated_at', a.updated_at
             ) ORDER BY a.date
           ),
           '[]'::jsonb
         )
    INTO v_items
    FROM representative_rows AS a
    JOIN daily_slots AS d ON d.date = a.date;

  RETURN jsonb_build_object(
    'items', v_items,
    'timezone', 'Africa/Cairo',
    'horizon_days', v_horizon,
    'generated_through', v_generated ->> 'generated_through'
  );
END;
$function$;

-- Move the already-audited transactional booking implementation into the
-- private schema, then wrap it with Cairo-time expiry and recurring-rule checks.
-- Its booking/slot write logic, idempotency hash and unique locks are preserved.
ALTER FUNCTION public.rpc_create_booking(text, text, text, integer, text, text)
  SET SCHEMA private;
ALTER FUNCTION private.rpc_create_booking(text, text, text, integer, text, text)
  RENAME TO rpc_create_booking_core;
REVOKE ALL ON FUNCTION private.rpc_create_booking_core(text, text, text, integer, text, text)
  FROM PUBLIC, anon, authenticated, service_role;

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
SET search_path = pg_catalog, public, private, pg_temp
AS $function$
DECLARE
  v_actor text := private.current_app_user_id();
  v_user_id text;
  v_date date;
  v_start integer;
  v_now_minute integer;
  v_local_now timestamp without time zone;
  v_today date;
  v_horizon integer;
  v_schedule_configured boolean := false;
  v_i integer;
  v_idempotency_key text := NULLIF(btrim(p_idempotency_key), '');
  v_idempotency_hash text;
BEGIN
  IF auth.uid() IS NULL OR v_actor IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AUTHENTICATION_REQUIRED';
  END IF;
  v_user_id := COALESCE(NULLIF(p_user_id, ''), v_actor);
  IF p_hours IS NULL OR p_hours < 1 OR p_hours > 12 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_BOOKING_DURATION';
  END IF;
  IF v_idempotency_key IS NOT NULL THEN
    IF char_length(v_idempotency_key) > 128 THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'IDEMPOTENCY_KEY_TOO_LONG';
    END IF;
    v_idempotency_hash := public._sha256_hex(
      convert_to(v_user_id, 'UTF8') || decode('00', 'hex') || convert_to(v_idempotency_key, 'UTF8')
    );
    -- Preserve a successful retry even if its original start time has since
    -- passed. The core RPC validates ownership and payload equality itself.
    IF EXISTS (
      SELECT 1 FROM public.bookings AS b
       WHERE b.user_id = v_user_id
         AND b.idempotency_key_hash = v_idempotency_hash
    ) THEN
      RETURN private.rpc_create_booking_core(
        p_lawyer_id, p_date, p_time, p_hours, p_idempotency_key, p_user_id
      );
    END IF;
  END IF;

  v_start := public.clock_time_minutes(p_time);
  IF v_start IS NULL OR v_start + p_hours * 60 > 1440 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_BOOKING_TIME';
  END IF;
  IF p_date IS NULL OR p_date !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN
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

  v_local_now := timezone('Africa/Cairo', now());
  v_today := v_local_now::date;
  v_now_minute := extract(hour FROM v_local_now)::integer * 60
                + extract(minute FROM v_local_now)::integer;
  IF v_date < v_today OR (v_date = v_today AND v_start <= v_now_minute) THEN
    RETURN jsonb_build_object('error', 'SLOT_EXPIRED');
  END IF;

  -- Same lock as generation and the underlying reservation RPC: the schedule
  -- check and final slot insert cannot straddle a concurrent schedule edit.
  PERFORM public._lock_booking_day(p_lawyer_id, p_date);
  SELECT s.booking_horizon_days INTO v_horizon
    FROM public.lawyer_weekly_schedules AS s
   WHERE s.lawyer_id = p_lawyer_id;
  v_schedule_configured := FOUND;
  -- Legacy daily schedules still use the documented 365-day fallback. Enforce
  -- that bound even when no weekly-rule row exists; only interval containment
  -- depends on a configured recurring schedule.
  IF NOT v_schedule_configured THEN
    v_horizon := 365;
  END IF;
  IF v_date > v_today + v_horizon THEN
    RETURN jsonb_build_object('error', 'BOOKING_OUTSIDE_HORIZON');
  END IF;
  IF v_schedule_configured THEN
    FOR v_i IN 0..p_hours - 1 LOOP
      IF NOT EXISTS (
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
  END IF;

  RETURN private.rpc_create_booking_core(
    p_lawyer_id, p_date, p_time, p_hours, p_idempotency_key, p_user_id
  );
END;
$function$;

REVOKE ALL ON FUNCTION private.weekly_time_to_minute(text, boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.try_iso_date(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.guard_weekly_interval_overlap() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.generate_lawyer_availability(text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.rpc_lawyer_my_weekly_schedule() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_lawyer_set_weekly_schedule(jsonb, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_refresh_lawyer_availability(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_create_booking(text, text, text, integer, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_lawyer_my_weekly_schedule() TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_lawyer_set_weekly_schedule(jsonb, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_refresh_lawyer_availability(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_create_booking(text, text, text, integer, text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;