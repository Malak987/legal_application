CREATE OR REPLACE FUNCTION public.guard_user_identity_fields()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
BEGIN
  -- Permit only the internal FK action caused by deleting the linked Auth user.
  IF OLD.auth_user_id IS NOT NULL
     AND NEW.auth_user_id IS NULL
     AND current_user = 'postgres'
     AND pg_trigger_depth() > 1
     AND (auth.role() IS NULL OR auth.role() = 'service_role')
     AND ROW(
       NEW.id, NEW.uid, NEW.name, NEW.email, NEW.phone, NEW.role,
       NEW.avatar, NEW.address, NEW.created_at, NEW.onboarding_status
     ) IS NOT DISTINCT FROM ROW(
       OLD.id, OLD.uid, OLD.name, OLD.email, OLD.phone, OLD.role,
       OLD.avatar, OLD.address, OLD.created_at, OLD.onboarding_status
     ) THEN
    RETURN NEW;
  END IF;

  -- Owner identity remains immutable to ordinary authenticated users.
  IF OLD.role = 'owner' OR NEW.role = 'owner' THEN
    IF NEW.id IS DISTINCT FROM OLD.id
       OR NEW.uid IS DISTINCT FROM OLD.uid
       OR NEW.auth_user_id IS DISTINCT FROM OLD.auth_user_id
       OR NEW.role IS DISTINCT FROM OLD.role THEN
      IF (current_user = 'service_role' AND auth.role() = 'service_role')
         OR (session_user = 'postgres' AND auth.role() IS NULL) THEN
        RETURN NEW;
      END IF;
      RAISE EXCEPTION 'The owner identity and role can only be changed by a trusted provisioning process'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  -- Role changes are exclusively controlled by the Owner, even through direct table UPDATE.
  IF NEW.role IS DISTINCT FROM OLD.role
     AND NOT (
       (current_user = 'service_role' AND auth.role() = 'service_role')
       OR (session_user = 'postgres' AND auth.role() IS NULL)
       OR (auth.uid() IS NOT NULL AND private.current_app_user_role() = 'owner')
     ) THEN
    RAISE EXCEPTION 'Only the owner can change account roles'
      USING ERRCODE = '42501', MESSAGE = 'OWNER_REQUIRED';
  END IF;

  -- Preserve existing administrator-only protection for identity fields.
  IF (
    NEW.id IS DISTINCT FROM OLD.id
    OR NEW.uid IS DISTINCT FROM OLD.uid
    OR NEW.auth_user_id IS DISTINCT FROM OLD.auth_user_id
  ) AND NOT COALESCE(
    current_setting('legal.auth_user_link_in_progress', true) = 'true'
    AND current_user = 'postgres'
    AND pg_trigger_depth() > 1,
    false
  ) AND NOT public.is_admin() THEN
    RAISE EXCEPTION 'Identity fields can only be changed by an administrator'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$function$;