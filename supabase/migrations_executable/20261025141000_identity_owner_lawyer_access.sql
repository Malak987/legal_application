-- Migration: 20261025141000_identity_owner_lawyer_access.sql
-- Forward-only identity/owner/lawyer policies. No user data is rewritten.
-- Uses only existing `users`, `lawyers`, `cases`, and `bookings` tables.
-- No data rows are intentionally changed by this transaction.

BEGIN;
-- A profile is required for application identity. Never fall back to the Auth
-- UUID when the trusted profile is absent or carries an unsupported role.
CREATE OR REPLACE FUNCTION private.current_app_user_id()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
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
  WHERE role IN ('client', 'lawyer', 'admin', 'owner');
$function$;
CREATE OR REPLACE FUNCTION private.current_app_user_role()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
  WITH matched_profile AS (
    SELECT u.role
    FROM public.users AS u
    WHERE auth.uid() IS NOT NULL
      AND (u.auth_user_id = auth.uid() OR u.id = auth.uid()::text)
    ORDER BY (u.auth_user_id = auth.uid()) DESC NULLS LAST,
             (u.id = auth.uid()::text) DESC NULLS LAST
    LIMIT 1
  )
  SELECT role
  FROM matched_profile
  WHERE role IN ('client', 'lawyer', 'admin', 'owner');
$function$;
-- `admin` remains a compatibility role. It is not renamed or converted.
-- New `owner` profiles receive the same DB authorization used by existing
-- owner/admin policies; the partial unique index below allows at most one.
ALTER TABLE public.users DROP CONSTRAINT users_role_check;
ALTER TABLE public.users
  ADD CONSTRAINT users_role_check
  CHECK (role IN ('client', 'lawyer', 'admin', 'owner')) NOT VALID;
ALTER TABLE public.users VALIDATE CONSTRAINT users_role_check;
CREATE UNIQUE INDEX users_single_owner_key
  ON public.users (role)
  WHERE role = 'owner';
CREATE OR REPLACE FUNCTION private.is_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
  SELECT COALESCE(
    private.current_app_user_role() IN ('admin', 'owner'),
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
    private.current_app_user_role() IN ('lawyer', 'admin', 'owner'),
    false
  );
$function$;
-- Keep existing admin role changes for client/lawyer accounts compatible, but
-- reserve both promotion to and demotion from owner for a trusted SQL/service
-- role. Ordinary authenticated clients cannot set identity or role columns.
CREATE OR REPLACE FUNCTION public.guard_user_identity_fields()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $function$
BEGIN
  IF (OLD.role = 'owner' OR NEW.role = 'owner') AND (
    NEW.id IS DISTINCT FROM OLD.id
    OR NEW.uid IS DISTINCT FROM OLD.uid
    OR NEW.auth_user_id IS DISTINCT FROM OLD.auth_user_id
    OR NEW.role IS DISTINCT FROM OLD.role
  ) THEN
    -- SECURITY DEFINER RPCs run with current_user set to their function owner
    -- (often postgres). That alone is not operator authority: distinguish a
    -- service-role JWT from authenticated callers, and allow direct SQL
    -- operator sessions only when no PostgREST JWT role is present.
    IF (current_user = 'service_role' AND auth.role() = 'service_role')
       OR (session_user = 'postgres' AND auth.role() IS NULL) THEN
      RETURN NEW;
    END IF;
    RAISE EXCEPTION 'The owner identity and role can only be changed by a trusted provisioning process'
      USING ERRCODE = '42501';
  END IF;

  IF (
    NEW.id IS DISTINCT FROM OLD.id
    OR NEW.uid IS DISTINCT FROM OLD.uid
    OR NEW.auth_user_id IS DISTINCT FROM OLD.auth_user_id
    OR NEW.role IS DISTINCT FROM OLD.role
  ) AND NOT COALESCE(
    current_setting('legal.auth_user_link_in_progress', true) = 'true'
    AND current_user = 'postgres'
    AND pg_trigger_depth() > 1,
    false
  ) AND NOT public.is_admin() THEN
    RAISE EXCEPTION 'Identity and role fields can only be changed by an administrator'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$function$;
-- The live users INSERT policy permits authenticated admins to create users,
-- so reserve owner creation itself for the trusted provisioning path.
CREATE OR REPLACE FUNCTION public.guard_owner_profile_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $function$
BEGIN
  IF NEW.role = 'owner'
     AND NOT COALESCE(
       (current_user = 'service_role' AND auth.role() = 'service_role')
       OR (session_user = 'postgres' AND auth.role() IS NULL),
       false
     ) THEN
    RAISE EXCEPTION 'The owner profile can only be created by a trusted provisioning process'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$function$;
REVOKE ALL ON FUNCTION public.guard_owner_profile_insert() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS guard_owner_profile_insert_trigger ON public.users;
CREATE TRIGGER guard_owner_profile_insert_trigger
  BEFORE INSERT ON public.users
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_owner_profile_insert();
-- RLS permits administrators to delete users, so reserve deletion of the
-- singleton owner account for the same trusted operator path as provisioning.
CREATE OR REPLACE FUNCTION public.guard_owner_profile_delete()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $function$
BEGIN
  IF OLD.role = 'owner'
     AND NOT COALESCE(
       (current_user = 'service_role' AND auth.role() = 'service_role')
       OR (session_user = 'postgres' AND auth.role() IS NULL),
       false
     ) THEN
    RAISE EXCEPTION 'The owner profile can only be deleted by a trusted provisioning process'
      USING ERRCODE = '42501';
  END IF;
  RETURN OLD;
END;
$function$;
REVOKE ALL ON FUNCTION public.guard_owner_profile_delete() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS guard_owner_profile_delete_trigger ON public.users;
CREATE TRIGGER guard_owner_profile_delete_trigger
  BEFORE DELETE ON public.users
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_owner_profile_delete();
-- Do not claim a legacy profile on email equality. Legacy linking requires an
-- exact profile ID in admin-controlled raw_app_meta_data plus a confirmed,
-- matching email. Email and phone signups create profiles only after the
-- corresponding contact is confirmed. Only a trusted server-controlled
-- signup_role can request a lawyer profile; raw_user_meta_data.role is ignored.
-- Phone-only signups are always clients, and all other values (including
-- admin/owner) fail closed to client.
CREATE OR REPLACE FUNCTION public.link_migrated_auth_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_legacy_uid text;
  v_name text;
  v_signup_role text;
  v_email_confirmed boolean;
  v_phone_confirmed boolean;
BEGIN
  v_email_confirmed := NEW.email IS NOT NULL AND NEW.email_confirmed_at IS NOT NULL;
  v_phone_confirmed := NEW.phone IS NOT NULL AND NEW.phone_confirmed_at IS NOT NULL;
  IF NOT v_email_confirmed AND NOT v_phone_confirmed THEN
    RETURN NEW;
  END IF;

  -- Do not treat an unconfirmed address/number change as a verified identity.
  -- A simultaneous confirmation of the other contact may still provision a
  -- client profile, but only already-confirmed contact values are persisted.
  IF TG_OP = 'UPDATE'
     AND OLD.email IS DISTINCT FROM NEW.email
     AND OLD.email_confirmed_at IS NOT DISTINCT FROM NEW.email_confirmed_at
     AND OLD.phone_confirmed_at IS NOT DISTINCT FROM NEW.phone_confirmed_at THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE'
     AND OLD.phone IS DISTINCT FROM NEW.phone
     AND OLD.phone_confirmed_at IS NOT DISTINCT FROM NEW.phone_confirmed_at
     AND OLD.email_confirmed_at IS NOT DISTINCT FROM NEW.email_confirmed_at THEN
    RETURN NEW;
  END IF;

  -- Keep an existing explicit Auth mapping; update only confirmed contacts,
  -- never the stored application role or identity columns.
  UPDATE public.users
     SET email = CASE WHEN v_email_confirmed THEN NEW.email ELSE email END,
         phone = CASE WHEN v_phone_confirmed THEN NEW.phone ELSE phone END,
         updated_at = now()
   WHERE auth_user_id = NEW.id;
  IF FOUND THEN
    RETURN NEW;
  END IF;

  -- Legacy rows require both an administrator-verified exact ID and a
  -- confirmed, matching email. Phone alone is never used to claim legacy data.
  v_legacy_uid := NULLIF(btrim(NEW.raw_app_meta_data ->> 'legacy_uid'), '');
  IF v_email_confirmed
     AND v_legacy_uid IS NOT NULL
     AND NEW.raw_app_meta_data ->> 'legacy_migration_verified' = 'true' THEN
    -- The row's existing identity guard only permits identity updates from an
    -- admin. Mark this exact, nested Auth trigger update rather than broadly
    -- trusting current_user=postgres (which SECURITY DEFINER RPCs also use).
    PERFORM set_config('legal.auth_user_link_in_progress', 'true', true);
    UPDATE public.users
       SET auth_user_id = NEW.id,
           email = NEW.email,
           updated_at = now()
     WHERE id = v_legacy_uid
       AND auth_user_id IS NULL
       AND lower(email) = lower(NEW.email);
    PERFORM set_config('legal.auth_user_link_in_progress', 'false', true);
    -- A failed explicit mapping is left unlinked for manual reconciliation.
    RETURN NEW;
  END IF;

  v_name := btrim(COALESCE(NEW.raw_user_meta_data ->> 'name', ''));
  IF char_length(v_name) < 2 THEN
    v_name := CASE
      WHEN v_email_confirmed THEN split_part(NEW.email, '@', 1)
      ELSE 'Client'
    END;
  END IF;
  IF char_length(btrim(v_name)) < 2 THEN
    v_name := 'Client';
  END IF;

  -- Lawyer onboarding is an email-confirmed flow assigned by the trusted
  -- server. A verified phone signup can create a client profile only.
  v_signup_role := CASE
    WHEN v_email_confirmed
     AND NEW.raw_app_meta_data ->> 'signup_role' = 'lawyer' THEN 'lawyer'
    ELSE 'client'
  END;

  INSERT INTO public.users (id, uid, auth_user_id, name, email, phone, role)
  VALUES (
    NEW.id::text,
    NEW.id::text,
    NEW.id,
    v_name,
    CASE WHEN v_email_confirmed THEN NEW.email ELSE '' END,
    CASE WHEN v_phone_confirmed THEN NEW.phone ELSE '' END,
    v_signup_role
  )
  ON CONFLICT DO NOTHING;

  RETURN NEW;
END;
$function$;
DROP TRIGGER IF EXISTS trg_auth_users_link_migrated ON auth.users;
CREATE TRIGGER trg_auth_users_link_migrated
  AFTER INSERT OR UPDATE OF email, email_confirmed_at, phone, phone_confirmed_at ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.link_migrated_auth_user();
REVOKE ALL ON FUNCTION private.current_app_user_id() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION private.current_app_user_role() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION private.is_admin() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION private.is_lawyer_or_admin() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.current_app_user_id() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.current_app_user_role() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.is_admin() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.is_lawyer_or_admin() TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.link_migrated_auth_user() FROM PUBLIC, anon, authenticated;
-- Owner policies must be role-bound before any assigned-lawyer policy is
-- added. A profile with a matching user_id is a client owner only when its
-- server-owned role is `client`; admin/owner access remains explicit.
DROP POLICY IF EXISTS cases_select_owner_or_admin ON public.cases;
CREATE POLICY cases_select_owner_or_admin ON public.cases
  FOR SELECT TO authenticated
  USING (
    private.is_admin()
    OR (
      private.current_app_user_role() = 'client'
      AND user_id = private.current_app_user_id()
    )
  );
DROP POLICY IF EXISTS cases_insert_owner_or_admin ON public.cases;
CREATE POLICY cases_insert_owner_or_admin ON public.cases
  FOR INSERT TO authenticated
  WITH CHECK (
    private.is_admin()
    OR (
      private.current_app_user_role() = 'client'
      AND user_id = private.current_app_user_id()
    )
  );
DROP POLICY IF EXISTS cases_update_owner_or_admin ON public.cases;
CREATE POLICY cases_update_owner_or_admin ON public.cases
  FOR UPDATE TO authenticated
  USING (
    private.is_admin()
    OR (
      private.current_app_user_role() = 'client'
      AND user_id = private.current_app_user_id()
    )
  )
  WITH CHECK (
    private.is_admin()
    OR (
      private.current_app_user_role() = 'client'
      AND user_id = private.current_app_user_id()
    )
  );
DROP POLICY IF EXISTS cases_delete_owner_or_admin ON public.cases;
CREATE POLICY cases_delete_owner_or_admin ON public.cases
  FOR DELETE TO authenticated
  USING (
    private.is_admin()
    OR (
      private.current_app_user_role() = 'client'
      AND user_id = private.current_app_user_id()
    )
  );
DROP POLICY IF EXISTS bookings_select_owner_or_admin ON public.bookings;
CREATE POLICY bookings_select_owner_or_admin ON public.bookings
  FOR SELECT TO authenticated
  USING (
    private.is_admin()
    OR (
      private.current_app_user_role() = 'client'
      AND user_id = private.current_app_user_id()
    )
  );
-- `bookings_write_admin_only` and `booking_slots_write_admin_only` remain
-- unchanged, including their server/admin-only writes. Booking-slot rows
-- contain booking/user identifiers and are deliberately not exposed to lawyers.
DROP POLICY IF EXISTS booking_slots_select_owner_or_admin ON public.booking_slots;
CREATE POLICY booking_slots_select_owner_or_admin ON public.booking_slots
  FOR SELECT TO authenticated
  USING (
    private.is_admin()
    OR (
      private.current_app_user_role() = 'client'
      AND user_id = private.current_app_user_id()
    )
  );
-- Lawyer access is restricted to read-only assigned cases/bookings. The
-- relationship is `lawyers.user_id -> public.users.id`, not Auth UUID equality.
CREATE OR REPLACE FUNCTION private.is_current_user_lawyer_for(p_lawyer_id text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
  SELECT COALESCE(
    auth.uid() IS NOT NULL
    AND p_lawyer_id IS NOT NULL
    AND private.current_app_user_role() = 'lawyer'
    AND EXISTS (
      SELECT 1
      FROM public.lawyers AS l
      WHERE l.id = p_lawyer_id
        AND l.user_id = private.current_app_user_id()
    ),
    false
  );
$function$;
REVOKE ALL ON FUNCTION private.is_current_user_lawyer_for(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.is_current_user_lawyer_for(text) TO authenticated, service_role;
DROP POLICY IF EXISTS cases_select_assigned_lawyer ON public.cases;
CREATE POLICY cases_select_assigned_lawyer ON public.cases
  FOR SELECT TO authenticated
  USING (private.is_current_user_lawyer_for(lawyer_id));
DROP POLICY IF EXISTS bookings_select_assigned_lawyer ON public.bookings;
CREATE POLICY bookings_select_assigned_lawyer ON public.bookings
  FOR SELECT TO authenticated
  USING (private.is_current_user_lawyer_for(lawyer_id));
COMMIT;