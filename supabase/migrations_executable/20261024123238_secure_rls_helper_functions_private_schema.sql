BEGIN;

CREATE SCHEMA IF NOT EXISTS private;

REVOKE ALL ON SCHEMA private FROM PUBLIC, anon;
GRANT USAGE ON SCHEMA private TO authenticated, service_role;

CREATE OR REPLACE FUNCTION private.current_app_user_id()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
  SELECT COALESCE(
    (
      SELECT u.id
      FROM public.users u
      WHERE u.auth_user_id = auth.uid()
         OR u.id = auth.uid()::text
      LIMIT 1
    ),
    auth.uid()::text
  );
$function$;

CREATE OR REPLACE FUNCTION private.current_app_user_role()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
  SELECT u.role
  FROM public.users u
  WHERE u.auth_user_id = auth.uid()
     OR u.id = auth.uid()::text
  LIMIT 1;
$function$;

CREATE OR REPLACE FUNCTION private.is_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
  SELECT COALESCE(
    private.current_app_user_role() = 'admin',
    false
  );
$function$;

CREATE OR REPLACE FUNCTION private.is_lawyer_or_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
  SELECT COALESCE(
    private.current_app_user_role() IN ('lawyer', 'admin'),
    false
  );
$function$;

REVOKE ALL ON FUNCTION private.current_app_user_id() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION private.current_app_user_role() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION private.is_admin() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION private.is_lawyer_or_admin() FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION private.current_app_user_id() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.current_app_user_role() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.is_admin() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.is_lawyer_or_admin() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.current_app_user_id()
RETURNS text
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $function$
  SELECT private.current_app_user_id();
$function$;

CREATE OR REPLACE FUNCTION public.current_app_user_role()
RETURNS text
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $function$
  SELECT private.current_app_user_role();
$function$;

CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $function$
  SELECT private.is_admin();
$function$;

CREATE OR REPLACE FUNCTION public.is_lawyer_or_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $function$
  SELECT private.is_lawyer_or_admin();
$function$;

REVOKE ALL ON FUNCTION public.current_app_user_id() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.current_app_user_role() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.is_admin() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.is_lawyer_or_admin() FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.current_app_user_id() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.current_app_user_role() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.is_admin() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.is_lawyer_or_admin() TO authenticated, service_role;

COMMIT;