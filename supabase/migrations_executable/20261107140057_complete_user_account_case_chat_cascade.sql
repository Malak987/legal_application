
-- A client deleting their account must not leave their cases behind either.
ALTER TABLE public.cases
  DROP CONSTRAINT cases_user_id_fkey,
  ADD CONSTRAINT cases_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

-- Chats are linked through a participants array rather than a foreign key.
-- Remove the whole conversation when one of its account participants is deleted.
CREATE OR REPLACE FUNCTION private.purge_user_chats_before_delete()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp
AS $function$
BEGIN
  DELETE FROM public.chats AS c
   WHERE c.participants @> ARRAY[OLD.id]::text[];
  RETURN OLD;
END;
$function$;

DROP TRIGGER IF EXISTS purge_user_chats_before_delete ON public.users;
CREATE TRIGGER purge_user_chats_before_delete
BEFORE DELETE ON public.users
FOR EACH ROW
EXECUTE FUNCTION private.purge_user_chats_before_delete();

REVOKE ALL ON FUNCTION private.purge_user_chats_before_delete() FROM PUBLIC, anon, authenticated;
