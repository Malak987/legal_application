CREATE OR REPLACE FUNCTION private.purge_user_chats_before_delete()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
BEGIN
  DELETE FROM public.chats AS c
   WHERE c.participants @> ARRAY[OLD.id]::text[];
  RETURN OLD;
END;
$function$;

CREATE OR REPLACE FUNCTION private.purge_lawyer_chats_before_delete()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
BEGIN
  DELETE FROM public.chats AS c
   WHERE (
     OLD.user_id IS NOT NULL
     AND c.participants @> ARRAY[OLD.user_id]::text[]
   )
   OR c.booking_id IN (
     SELECT b.id FROM public.bookings AS b WHERE b.lawyer_id = OLD.id
   )
   OR c.case_id IN (
     SELECT cs.id FROM public.cases AS cs WHERE cs.lawyer_id = OLD.id
   );

  RETURN OLD;
END;
$function$;

COMMENT ON FUNCTION private.purge_user_chats_before_delete() IS
  'BEFORE DELETE on public.users: removes every chat the deleted profile '
  'participates in so account deletion is complete. Matches on the '
  'chats.participants array because public.chats has no user_id column.';

COMMENT ON FUNCTION private.purge_lawyer_chats_before_delete() IS
  'BEFORE DELETE on public.lawyers: removes chats owned by the lawyer profile, '
  'plus chats attached to that lawyer''s bookings or cases.';