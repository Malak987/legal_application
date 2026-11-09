
ALTER TABLE public.users
  DROP CONSTRAINT users_auth_user_id_fkey,
  ADD CONSTRAINT users_auth_user_id_fkey
    FOREIGN KEY (auth_user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

ALTER TABLE public.lawyers
  DROP CONSTRAINT lawyers_user_id_fkey,
  ADD CONSTRAINT lawyers_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE public.bookings
  DROP CONSTRAINT bookings_lawyer_id_fkey,
  ADD CONSTRAINT bookings_lawyer_id_fkey
    FOREIGN KEY (lawyer_id) REFERENCES public.lawyers(id) ON DELETE CASCADE;

ALTER TABLE public.cases
  DROP CONSTRAINT cases_lawyer_id_fkey,
  ADD CONSTRAINT cases_lawyer_id_fkey
    FOREIGN KEY (lawyer_id) REFERENCES public.lawyers(id) ON DELETE CASCADE;

ALTER TABLE public.cases
  DROP CONSTRAINT cases_lawyer_category_fkey,
  ADD CONSTRAINT cases_lawyer_category_fkey
    FOREIGN KEY (lawyer_id, category_id)
    REFERENCES public.lawyers(id, category_id) ON DELETE CASCADE;

CREATE OR REPLACE FUNCTION private.purge_lawyer_chats_before_delete()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp
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

DROP TRIGGER IF EXISTS purge_lawyer_chats_before_delete ON public.lawyers;
CREATE TRIGGER purge_lawyer_chats_before_delete
BEFORE DELETE ON public.lawyers
FOR EACH ROW
EXECUTE FUNCTION private.purge_lawyer_chats_before_delete();

REVOKE ALL ON FUNCTION private.purge_lawyer_chats_before_delete() FROM PUBLIC, anon, authenticated;
