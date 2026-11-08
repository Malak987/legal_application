-- 20261108120000_correct_chat_purge_trigger_bodies
-- Project: legal (qqfzbecwhewswkyxgebu)
--
-- WHY THIS MIGRATION EXISTS
-- ------------------------
-- Migration 20261107140057_complete_user_account_case_chat_cascade.sql created
-- two BEFORE DELETE triggers with bodies that reference columns which do NOT
-- exist on public.chats (its columns are id, participants, participant_names,
-- last_message, created_at, updated_at, booking_id, case_id — there is no
-- `user_id` and no `lawyer_id`):
--
--   private.purge_lawyer_chats_before_delete()  -> DELETE FROM chats WHERE lawyer_id = OLD.id
--   private.purge_user_chats_before_delete()    -> DELETE FROM chats WHERE user_id   = OLD.id
--
-- PL/pgSQL does not validate column references at CREATE time, so the migration
-- applied successfully. At runtime, however, the first DELETE of a row from
-- public.users (which is exactly what ON DELETE CASCADE does when the Auth user
-- is removed) fires purge_user_chats_before_delete and raises
--   ERROR 42703: column "user_id" does not exist
-- aborting the whole statement and therefore the whole account deletion.
--
-- The running project was subsequently patched by hand to the corrected bodies
-- below, so production is healthy today — but the repository is NOT: the
-- checked-in migration still holds the broken definitions, and 20261107140057
-- is already recorded in supabase_migrations.schema_migrations, so a plain
-- `supabase db push` will never re-run it. Any environment built from the
-- repository alone (new branch, restore, disaster recovery) would get the
-- broken trigger and account deletion would fail again.
--
-- WHAT THIS MIGRATION DOES
-- ------------------------
-- Re-asserts the corrected function bodies so that the repository and the
-- database agree again. Chats are matched through the `participants` text[]
-- column (for a user) or through booking/case ownership (for a lawyer).
--
-- SAFETY
-- ------
--  * CREATE OR REPLACE FUNCTION only — no table, column, policy, grant,
--    trigger or row is created, altered or removed.
--  * The bodies are character-for-character the definitions already running in
--    production, so applying this to the live project is a behavioural no-op.
--  * Idempotent: safe to run more than once.
--  * No RLS policy is changed and RLS remains enabled and forced on every
--    public table.

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
