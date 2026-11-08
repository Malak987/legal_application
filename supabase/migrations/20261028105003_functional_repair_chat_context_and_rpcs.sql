-- 1. Optional chat context (never required; nullable for all legacy rows)
ALTER TABLE public.chats
  ADD COLUMN IF NOT EXISTS booking_id text NULL
    REFERENCES public.bookings(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS case_id text NULL
    REFERENCES public.cases(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_chats_booking_id ON public.chats (booking_id);
CREATE INDEX IF NOT EXISTS idx_chats_case_id ON public.chats (case_id);
GRANT SELECT (booking_id, case_id) ON public.chats TO authenticated;

-- 2. Secure, idempotent 'open chat with this lawyer'
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
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_actor       text := public.current_app_user_id();
  v_role        text := public.current_app_user_role();
  v_lawyer      public.lawyers%ROWTYPE;
  v_lawyer_user text;
  v_client      text;
  v_pair        text[];
  v_chat        public.chats%ROWTYPE;
  v_names       jsonb;
  v_text        text := NULLIF(btrim(p_initial_message), '');
  v_booking     text := NULLIF(btrim(COALESCE(p_booking_id, '')), '');
  v_case        text := NULLIF(btrim(COALESCE(p_case_id, '')), '');
  v_reused      boolean := false;
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
  ELSIF v_role = 'lawyer' AND v_actor = v_lawyer_user THEN
    v_client := NULLIF(btrim(COALESCE(p_client_id, '')), '');
    IF v_client IS NULL OR NOT EXISTS (
      SELECT 1 FROM public.users WHERE id = v_client AND role = 'client'
    ) THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'UNKNOWN_CHAT_PARTICIPANT';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.bookings b
       WHERE b.lawyer_id = p_lawyer_id AND b.user_id = v_client
      UNION ALL
      SELECT 1 FROM public.cases c
       WHERE c.lawyer_id = p_lawyer_id AND c.user_id = v_client
    ) THEN
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
        FROM public.users u WHERE u.id = v_actor;
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
$$;

-- 3. Idempotent message send (client-generated id becomes the primary key)
CREATE OR REPLACE FUNCTION public.rpc_chat_send_message(
  p_chat_id text,
  p_text text,
  p_client_message_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_actor      text := public.current_app_user_id();
  v_chat       public.chats%ROWTYPE;
  v_message    public.chat_messages%ROWTYPE;
  v_existing   public.chat_messages%ROWTYPE;
  v_name       text;
  v_text       text := btrim(COALESCE(p_text, ''));
  v_client_id  text := NULLIF(btrim(COALESCE(p_client_message_id, '')), '');
BEGIN
  IF auth.uid() IS NULL OR v_actor IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AUTHENTICATION_REQUIRED';
  END IF;
  IF v_text = '' OR char_length(v_text) > 4000 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_MESSAGE';
  END IF;
  IF v_client_id IS NOT NULL AND NOT (v_client_id ~ '^[A-Za-z0-9_-]{8,128}$') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_MESSAGE_ID';
  END IF;

  SELECT * INTO v_chat FROM public.chats WHERE id = p_chat_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'CHAT_NOT_FOUND';
  END IF;
  IF NOT public.is_admin() AND NOT (v_actor = ANY(v_chat.participants)) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'NOT_CHAT_PARTICIPANT';
  END IF;

  IF v_client_id IS NOT NULL THEN
    SELECT * INTO v_existing FROM public.chat_messages WHERE id = v_client_id;
    IF FOUND THEN
      IF v_existing.chat_id <> p_chat_id OR v_existing.sender_id <> v_actor THEN
        RAISE EXCEPTION USING ERRCODE = '23505', MESSAGE = 'MESSAGE_ID_CONFLICT';
      END IF;
      RETURN to_jsonb(v_existing) || jsonb_build_object('replayed', true);
    END IF;
  END IF;

  SELECT name INTO v_name FROM public.users WHERE id = v_actor;
  INSERT INTO public.chat_messages (id, chat_id, sender_id, sender_name, text)
  VALUES (
    COALESCE(v_client_id, gen_random_uuid()::text),
    v_chat.id, v_actor,
    COALESCE(NULLIF(btrim(v_name), ''), 'User'), v_text
  ) RETURNING * INTO v_message;

  UPDATE public.chats SET last_message = v_text, updated_at = now()
   WHERE id = v_chat.id;

  RETURN to_jsonb(v_message) || jsonb_build_object('replayed', false);
END;
$$;

DROP FUNCTION IF EXISTS public.rpc_chat_send_message(text, text);