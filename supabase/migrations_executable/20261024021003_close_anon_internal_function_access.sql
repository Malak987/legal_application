
-- Close direct anonymous execution of internal identity/authorization helpers.
-- Anonymous policies only expose explicitly public SELECT tables and do not call these helpers.
REVOKE EXECUTE ON FUNCTION public.current_app_user_id() FROM anon;
REVOKE EXECUTE ON FUNCTION public.current_app_user_role() FROM anon;
REVOKE EXECUTE ON FUNCTION public.is_admin() FROM anon;
REVOKE EXECUTE ON FUNCTION public.is_lawyer_or_admin() FROM anon;

-- RLS helper functions remain executable for authenticated because policies invoke them.
-- Ensure application roles cannot execute the auth-linking trigger function directly.
REVOKE EXECUTE ON FUNCTION public.link_migrated_auth_user() FROM PUBLIC, anon, authenticated;

-- Ensure anon cannot write any public table, including tables added after the first hardening migration.
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT tablename FROM pg_tables WHERE schemaname='public'
  LOOP
    EXECUTE format('REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE public.%I FROM anon', r.tablename);
  END LOOP;
END $$;
