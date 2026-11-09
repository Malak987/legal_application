
-- Conservative live security hardening.
-- Preserve existing SELECT/INSERT/UPDATE/DELETE behavior for authenticated clients;
-- RLS policies remain the row-level authorization boundary.
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT tablename
    FROM pg_tables
    WHERE schemaname = 'public'
  LOOP
    EXECUTE format(
      'REVOKE TRUNCATE, REFERENCES, TRIGGER ON TABLE public.%I FROM anon, authenticated',
      r.tablename
    );
    -- Anonymous visitors may read only where existing policies permit.
    -- They must not mutate application data directly.
    EXECUTE format(
      'REVOKE INSERT, UPDATE, DELETE ON TABLE public.%I FROM anon',
      r.tablename
    );
  END LOOP;
END
$$;

-- Trigger functions are invoked by triggers, not through the Data API.
-- Remove their default PUBLIC/API execution grants without affecting existing triggers.
REVOKE EXECUTE ON FUNCTION public.set_updated_at() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.link_migrated_auth_user() FROM PUBLIC, anon, authenticated;

-- Pin SECURITY DEFINER search_path for all current public functions to system
-- catalogs first; application objects in function bodies are schema-qualified.
ALTER FUNCTION public.current_app_user_id() SET search_path = pg_catalog, public;
ALTER FUNCTION public.current_app_user_role() SET search_path = pg_catalog, public;
ALTER FUNCTION public.is_admin() SET search_path = pg_catalog, public;
ALTER FUNCTION public.is_lawyer_or_admin() SET search_path = pg_catalog, public;
ALTER FUNCTION public.link_migrated_auth_user() SET search_path = pg_catalog, public;
ALTER FUNCTION public.rpc_recalculate_lawyer_rating(text) SET search_path = pg_catalog, public;
ALTER FUNCTION public.rpc_reserve_booking_slots(text, text, text, text, text, text, integer, numeric, text, text[], integer[]) SET search_path = pg_catalog, public;
ALTER FUNCTION public.rpc_wallet_mutate(text, text, numeric, text, text) SET search_path = pg_catalog, public;
ALTER FUNCTION public.set_updated_at() SET search_path = pg_catalog, public;
