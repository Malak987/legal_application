-- Regression guard for the production failure
--   "Could not load availability / AUTHENTICATION_REQUIRED"
-- and for the same code raised by the chat RPCs.
--
-- It is read-only: it creates no rows, writes nothing and rolls back. Run it
-- against a project or a database branch after applying
-- supabase/migrations/20261107093000_resolve_user_role_actor.sql:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/actor_role_resolution_test.sql
--
-- or paste the whole file into the Supabase SQL editor. Any failed assertion
-- raises an exception, which makes psql exit non-zero.

begin;

do $test$
declare
  v_uid uuid;
  v_actor text;
  v_result text;
  v_lawyer_id text;
begin
  -- 1. The actor resolver and the role resolver must agree about which roles
  --    belong to the application. `user` is the signup role written by
  --    public.link_migrated_auth_user() and is a client role everywhere else.
  if pg_get_functiondef('private.current_app_user_role()'::regprocedure)
       !~ '''user''' then
    raise exception
      'private.current_app_user_role() no longer recognises the signup role user';
  end if;

  if pg_get_functiondef('private.current_app_user_id()'::regprocedure)
       !~ '''user''' then
    raise exception
      'private.current_app_user_id() does not resolve the signup role user: every '
      'guarded RPC will raise AUTHENTICATION_REQUIRED for a valid client session';
  end if;

  -- 2. Behavioural check with a real client profile, when one exists.
  select u.auth_user_id
    into v_uid
    from public.users as u
   where u.role = 'user'
     and u.auth_user_id is not null
   limit 1;

  if v_uid is null then
    raise notice
      'no role=user profile with an Auth link in this database; '
      'skipping the live actor-resolution assertions';
    return;
  end if;

  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', v_uid::text, 'role', 'authenticated')::text,
    true
  );

  v_actor := private.current_app_user_id();
  if v_actor is null then
    raise exception
      'private.current_app_user_id() returned NULL for an authenticated role=user profile';
  end if;

  -- 3. The booking and availability RPCs must get past their authorisation
  --    guard and fail on business validation instead. These calls are chosen so
  --    they cannot write anything:
  --      * a non-existent lawyer id stops before availability generation;
  --      * an invalid duration stops before any slot reservation.
  select l.id into v_lawyer_id from public.lawyers as l limit 1;
  if v_lawyer_id is null then
    raise notice 'no lawyer rows in this database; skipping the RPC guard assertions';
    return;
  end if;

  begin
    perform public.rpc_refresh_lawyer_availability('regression-test-no-such-lawyer');
    raise exception 'rpc_refresh_lawyer_availability unexpectedly succeeded';
  exception
    when others then
      v_result := sqlstate || ' ' || sqlerrm;
      if v_result not like '22023%' then
        raise exception
          'rpc_refresh_lawyer_availability did not pass its authorisation guard: %',
          v_result;
      end if;
  end;

  begin
    perform public.rpc_create_booking(
      v_lawyer_id, '2099-01-01', '10:00', 0, 'regression-key-0001', null
    );
    raise exception 'rpc_create_booking unexpectedly succeeded';
  exception
    when others then
      v_result := sqlstate || ' ' || sqlerrm;
      if v_result not like '22023%' then
        raise exception
          'rpc_create_booking did not pass its authorisation guard: %',
          v_result;
      end if;
  end;

  -- 4. Authorisation is unchanged: a client still cannot read a conversation
  --    they are not a participant in.
  begin
    perform public.rpc_chat_messages_page(
      'regression-test-no-such-chat', null, null, 10
    );
    raise exception 'rpc_chat_messages_page returned another user''s chat';
  exception
    when others then
      v_result := sqlstate || ' ' || sqlerrm;
      if v_result not like '42501%CHAT_NOT_FOUND_OR_FORBIDDEN%' then
        raise exception
          'unexpected rpc_chat_messages_page result for a foreign chat: %',
          v_result;
      end if;
  end;

  raise notice 'actor resolution, booking and chat authorisation contracts hold';
end
$test$;

rollback;
