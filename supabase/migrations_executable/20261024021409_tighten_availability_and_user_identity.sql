-- A lawyer may manage only their own availability; admins retain full access.
DROP POLICY IF EXISTS availability_write_lawyer_or_admin ON public.availability;
CREATE POLICY availability_write_owner_or_admin
ON public.availability
FOR ALL
TO authenticated
USING (
  public.is_admin()
  OR EXISTS (
    SELECT 1
    FROM public.lawyers l
    WHERE l.id = availability.lawyer_id
      AND l.user_id = public.current_app_user_id()
  )
)
WITH CHECK (
  public.is_admin()
  OR EXISTS (
    SELECT 1
    FROM public.lawyers l
    WHERE l.id = availability.lawyer_id
      AND l.user_id = public.current_app_user_id()
  )
);

-- Prevent a normal user from changing account identity or privilege fields
-- through the otherwise permitted self-profile UPDATE policy.
CREATE OR REPLACE FUNCTION public.guard_user_identity_fields()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF (
    NEW.id IS DISTINCT FROM OLD.id
    OR NEW.uid IS DISTINCT FROM OLD.uid
    OR NEW.auth_user_id IS DISTINCT FROM OLD.auth_user_id
    OR NEW.role IS DISTINCT FROM OLD.role
  ) AND NOT public.is_admin() THEN
    RAISE EXCEPTION 'Identity and role fields can only be changed by an administrator'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.guard_user_identity_fields() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS guard_user_identity_fields_trigger ON public.users;
CREATE TRIGGER guard_user_identity_fields_trigger
BEFORE UPDATE ON public.users
FOR EACH ROW
EXECUTE FUNCTION public.guard_user_identity_fields();