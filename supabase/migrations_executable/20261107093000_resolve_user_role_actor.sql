-- Fix: authenticated clients were rejected with `AUTHENTICATION_REQUIRED`.
--
-- ROOT CAUSE (verified against the live project qqfzbecwhewswkyxgebu)
-- ------------------------------------------------------------------
-- `private.current_app_user_id()` resolved the caller's application profile
-- only for roles client | lawyer | admin | owner. It omitted `user`, which is
-- exactly the role the Auth provisioning trigger
-- (`public.link_migrated_auth_user`) writes for every ordinary account:
--
--     v_signup_role := CASE
--       WHEN v_email_confirmed AND raw_app_meta_data ->> 'signup_role' = 'lawyer'
--         THEN 'lawyer'
--       ELSE 'user'          -- every client account
--     END;
--
-- The Flutter client accepts that role as a client (`AppProfile.isClient` is
-- `role == 'client' || role == 'user'`), `private.current_app_user_role()`
-- accepts it, and the RLS policies for `bookings`, `booking_slots`, `chats`,
-- `chat_messages` and `cases` already name `'user'` next to `'client'`.
-- Only the actor resolver disagreed, so for a perfectly valid session:
--
--   * auth.uid()                  -> present
--   * current_app_user_role()     -> 'user'
--   * current_app_user_id()       -> NULL
--
-- and every guarded RPC raised
--
--   ERROR 42501 AUTHENTICATION_REQUIRED
--
-- This is what the booking/availability screen surfaced ("Could not load
-- availability" with `AUTHENTICATION_REQUIRED`), and it is also why chat
-- raised the same code for clients (`rpc_chat_list`,
-- `rpc_chat_messages_page`, `rpc_chat_send_message`,
-- `rpc_chat_start_with_lawyer`, `rpc_chat_create`) while the same
-- conversations and bookings loaded correctly for lawyer accounts.
-- Client-role RLS predicates also evaluated to NULL, so `GET /rest/v1/chats`
-- and `GET /rest/v1/bookings` returned empty lists instead of the caller's
-- rows.
--
-- WHY THIS IS NOT A POLICY WEAKENING
-- ----------------------------------
-- `user` is the default, non-elevated signup role. This migration makes the
-- resolver agree with the role model the rest of the schema and the client
-- already enforce; it adds no new privilege:
--   * `private.is_admin()` still requires admin | owner;
--   * `private.is_current_user_lawyer_for()` still requires role 'lawyer'
--     plus a matching `lawyers.user_id`;
--   * `private.chat_participant_can_read()` still requires a 2-participant
--     chat containing the resolved actor and a lawyer/client pair;
--   * every policy still scopes rows to the resolved profile id, so a caller
--     can only reach rows that belong to them.
-- RLS is untouched (still enabled on every table), no policy, grant, Edge
-- Function JWT setting or Realtime authorisation is changed, and no row of
-- customer data is modified.
--
-- Rollback: re-create the previous definition without `'user'` in the role
-- list (the function is STABLE and read-only, so the rollback is safe).

CREATE OR REPLACE FUNCTION private.current_app_user_id()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public'
AS $function$
  WITH matched_profile AS (
    SELECT u.id, u.role
    FROM public.users AS u
    WHERE auth.uid() IS NOT NULL
      AND (u.auth_user_id = auth.uid() OR u.id = auth.uid()::text)
    ORDER BY (u.auth_user_id = auth.uid()) DESC NULLS LAST,
             (u.id = auth.uid()::text) DESC NULLS LAST
    LIMIT 1
  )
  SELECT id
  FROM matched_profile
  WHERE role IN ('client', 'user', 'lawyer', 'admin', 'owner');
$function$;

COMMENT ON FUNCTION private.current_app_user_id() IS
  'Resolves the public.users profile of the authenticated Supabase Auth user. '
  'Accepts every application role, including the non-elevated signup role '
  '"user", so client RPCs and RLS predicates agree with '
  'private.current_app_user_role().';
