CREATE OR REPLACE FUNCTION public.guard_owner_profile_delete()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'pg_catalog', 'public'
AS $function$
BEGIN
  IF OLD.role = 'owner'
     AND NOT (
       session_user = 'postgres'
       AND auth.uid() IS NULL
       AND auth.role() IS NULL
     ) THEN
    RAISE EXCEPTION 'The owner profile cannot be deleted through application or service-role operations'
      USING ERRCODE = '42501', MESSAGE = 'OWNER_DELETE_FORBIDDEN';
  END IF;
  RETURN OLD;
END;
$function$;