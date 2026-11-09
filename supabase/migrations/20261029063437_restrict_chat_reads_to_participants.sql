-- Restrict chat history to the two verified client/lawyer participants.
--
-- The existing participant helper validates the authenticated app profile,
-- membership in the chat, the two-party shape, the client role, and the
-- assigned lawyer profile. Admin/owner support access is intentionally not a
-- chat-read exception: this project requires client/lawyer-only access.
--
-- No table, policy, message, chat, or user data is changed. Authenticated
-- writes remain RPC-only; this migration only narrows read authorization.

BEGIN;

CREATE OR REPLACE FUNCTION private.can_read_chat(p_chat_id text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, private, pg_temp
AS $function$
  SELECT COALESCE(
    auth.uid() IS NOT NULL
    AND private.chat_participant_can_read(p_chat_id),
    false
  );
$function$;

-- Keep the existing API grant model explicit: authenticated callers need this
-- helper for the SELECT policies; trusted server operations retain their grant.
REVOKE ALL ON FUNCTION private.can_read_chat(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.can_read_chat(text) TO authenticated, service_role;

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
  IF v_role IS NULL OR v_role NOT IN ('client', 'lawyer') THEN
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

REVOKE ALL ON FUNCTION public.rpc_chat_list(integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_chat_list(integer, integer) TO authenticated;

COMMIT;