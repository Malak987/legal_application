-- Live-testing defect: public.guard_user_identity_fields() evaluates
-- public.is_admin() on every UPDATE of public.users. That function was only
-- executable by `postgres` and `authenticated`, so any service-role or
-- auth-service write to public.users failed with
--   ERROR 42501: permission denied for function is_admin
-- which blocked self-service account deletion (profile anonymisation and the
-- auth.users -> public.users FK action alike).
--
-- This grants EXECUTE on a parameterless, read-only predicate that reports
-- whether the *caller's own* JWT maps to an admin/owner profile. It does not
-- grant any data access, does not touch RLS, and does not change any guard's
-- logic: for these roles it simply returns false, exactly as before.

GRANT EXECUTE ON FUNCTION public.is_admin() TO service_role;
GRANT EXECUTE ON FUNCTION public.is_admin() TO supabase_auth_admin;