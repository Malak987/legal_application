
BEGIN;

ALTER TABLE public.users
  ALTER COLUMN role SET DEFAULT 'user';

ALTER TABLE public.users
  DROP CONSTRAINT IF EXISTS users_role_check;

ALTER TABLE public.users
  ADD CONSTRAINT users_role_check
  CHECK (role = ANY (ARRAY['user'::text, 'client'::text, 'lawyer'::text, 'admin'::text, 'owner'::text]));

DO $migration$
DECLARE
  v_signature regprocedure;
  v_definition text;
  v_updated text;
  v_replacements integer;
  v_item record;
BEGIN
  -- Change only the ordinary-signup fallback. Explicit trusted lawyer role
  -- and invitation/legacy identity paths remain unchanged.
  v_signature := 'public.link_migrated_auth_user()'::regprocedure;
  v_definition := pg_get_functiondef(v_signature);
  v_updated := replace(v_definition, 'ELSE ''client''', 'ELSE ''user''');
  IF v_updated = v_definition THEN
    RAISE EXCEPTION 'Expected ordinary signup fallback not found in link_migrated_auth_user';
  END IF;
  EXECUTE v_updated;

  -- Include the new role in the authenticated role resolver.
  v_signature := 'private.current_app_user_role()'::regprocedure;
  v_definition := pg_get_functiondef(v_signature);
  v_updated := replace(v_definition,
    'role IN (''client'', ''lawyer'', ''admin'', ''owner'')',
    'role IN (''user'', ''client'', ''lawyer'', ''admin'', ''owner'')');
  IF v_updated = v_definition THEN
    RAISE EXCEPTION 'Expected role allow-list not found in private.current_app_user_role';
  END IF;
  EXECUTE v_updated;

  -- Admin assignment RPC may explicitly assign the ordinary user role.
  v_signature := 'public.rpc_admin_set_user_role(text,text)'::regprocedure;
  v_definition := pg_get_functiondef(v_signature);
  v_updated := replace(v_definition,
    'p_role NOT IN (''client'', ''lawyer'', ''admin'')',
    'p_role NOT IN (''user'', ''client'', ''lawyer'', ''admin'')');
  IF v_updated = v_definition THEN
    RAISE EXCEPTION 'Expected role validation not found in rpc_admin_set_user_role';
  END IF;
  EXECUTE v_updated;

  -- Admin case assignment: both legacy clients and new users are eligible owners.
  v_signature := 'private.is_eligible_case_owner(text)'::regprocedure;
  v_definition := pg_get_functiondef(v_signature);
  v_updated := replace(v_definition, 'u.role = ''client''', 'u.role IN (''client'', ''user'')');
  IF v_updated = v_definition THEN
    RAISE EXCEPTION 'Expected client owner check not found in is_eligible_case_owner';
  END IF;
  EXECUTE v_updated;

  -- Chat participant authorization treats user as the ordinary client-side participant.
  v_signature := 'private.chat_participant_can_read(text)'::regprocedure;
  v_definition := pg_get_functiondef(v_signature);
  v_updated := replace(v_definition, 'private.current_app_user_role() = ''client''',
                                  'private.current_app_user_role() IN (''client'', ''user'')');
  v_updated := replace(v_updated, 'actor.role = ''client''', 'actor.role IN (''client'', ''user'')');
  v_updated := replace(v_updated, 'peer_user.role = ''client''', 'peer_user.role IN (''client'', ''user'')');
  IF v_updated = v_definition THEN
    RAISE EXCEPTION 'Expected client checks not found in chat_participant_can_read';
  END IF;
  EXECUTE v_updated;

  -- Case status and case editing remain owner-only for ordinary accounts.
  FOR v_item IN
    SELECT * FROM (VALUES
      ('public.rpc_case_set_status(text,text)'::regprocedure,
       'public.rpc_case_set_status'),
      ('public.rpc_case_update(text,jsonb)'::regprocedure,
       'public.rpc_case_update')
    ) AS f(signature, function_name)
  LOOP
    v_definition := pg_get_functiondef(v_item.signature);
    v_updated := replace(v_definition,
      'public.current_app_user_role() <> ''client''',
      'public.current_app_user_role() NOT IN (''client'', ''user'')');
    IF v_updated = v_definition THEN
      RAISE EXCEPTION 'Expected client owner check not found in %', v_item.function_name;
    END IF;
    EXECUTE v_updated;
  END LOOP;

  -- Chat creation and initiation: allow user/client on the client side only.
  v_signature := 'public.rpc_chat_create(text[],text)'::regprocedure;
  v_definition := pg_get_functiondef(v_signature);
  v_updated := replace(v_definition, 'v_role = ''client''', 'v_role IN (''client'', ''user'')');
  v_updated := replace(v_updated, 'client.role = ''client''', 'client.role IN (''client'', ''user'')');
  IF v_updated = v_definition THEN
    RAISE EXCEPTION 'Expected client checks not found in rpc_chat_create';
  END IF;
  EXECUTE v_updated;

  v_signature := 'public.rpc_chat_start_with_lawyer(text,text,text,text,text)'::regprocedure;
  v_definition := pg_get_functiondef(v_signature);
  v_updated := replace(v_definition, 'v_role = ''client''', 'v_role IN (''client'', ''user'')');
  v_updated := replace(v_updated, 'role = ''client''', 'role IN (''client'', ''user'')');
  IF v_updated = v_definition THEN
    RAISE EXCEPTION 'Expected client checks not found in rpc_chat_start_with_lawyer';
  END IF;
  EXECUTE v_updated;

  v_signature := 'public.rpc_chat_list(integer,integer)'::regprocedure;
  v_definition := pg_get_functiondef(v_signature);
  v_updated := replace(v_definition,
    'v_role NOT IN (''client'', ''lawyer'', ''owner'')',
    'v_role NOT IN (''user'', ''client'', ''lawyer'', ''owner'')');
  v_updated := replace(v_updated, 'u.role = ''client''', 'u.role IN (''client'', ''user'')');
  IF v_updated = v_definition THEN
    RAISE EXCEPTION 'Expected client checks not found in rpc_chat_list';
  END IF;
  EXECUTE v_updated;

  v_signature := 'public.rpc_refresh_lawyer_availability(text)'::regprocedure;
  v_definition := pg_get_functiondef(v_signature);
  v_updated := replace(v_definition,
    'v_role NOT IN (''client'', ''lawyer'', ''admin'', ''owner'')',
    'v_role NOT IN (''user'', ''client'', ''lawyer'', ''admin'', ''owner'')');
  IF v_updated = v_definition THEN
    RAISE EXCEPTION 'Expected role allow-list not found in rpc_refresh_lawyer_availability';
  END IF;
  EXECUTE v_updated;
END
$migration$;

-- Preserve existing policy behavior; add user as an equivalent case owner.
ALTER POLICY cases_insert_owner_or_admin ON public.cases
  WITH CHECK (
    private.is_admin()
    OR (
      private.current_app_user_role() IN ('client', 'user')
      AND user_id = private.current_app_user_id()
    )
  );

ALTER POLICY cases_update_owner_or_admin ON public.cases
  USING (
    private.is_admin()
    OR (
      private.current_app_user_role() IN ('client', 'user')
      AND user_id = private.current_app_user_id()
    )
  )
  WITH CHECK (
    private.is_admin()
    OR (
      private.current_app_user_role() IN ('client', 'user')
      AND user_id = private.current_app_user_id()
    )
  );

ALTER POLICY cases_delete_owner_or_admin ON public.cases
  USING (
    private.is_admin()
    OR (
      private.current_app_user_role() IN ('client', 'user')
      AND user_id = private.current_app_user_id()
    )
  );

ALTER POLICY booking_slots_select_owner_or_admin ON public.booking_slots
  USING (
    private.is_admin()
    OR (
      private.current_app_user_role() IN ('client', 'user')
      AND user_id = private.current_app_user_id()
    )
  );

ALTER POLICY bookings_select_authorized_parties ON public.bookings
  USING (
    private.is_current_user_lawyer_for(lawyer_id)
    OR private.is_admin()
    OR (
      private.current_app_user_role() IN ('client', 'user')
      AND user_id = private.current_app_user_id()
    )
  );

ALTER POLICY cases_select_authorized_parties ON public.cases
  USING (
    private.is_current_user_lawyer_for(lawyer_id)
    OR private.is_admin()
    OR (
      private.current_app_user_role() IN ('client', 'user')
      AND user_id = private.current_app_user_id()
    )
  );

COMMIT;
