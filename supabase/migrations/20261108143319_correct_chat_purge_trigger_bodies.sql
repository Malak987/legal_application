-- 20261108120000_correct_chat_purge_trigger_bodies
-- Project: legal (qqfzbecwhewswkyxgebu)
--
-- WHY THIS MIGRATION EXISTS
-- ------------------------
-- CORRECTED 2026-11-08. An earlier version of this header claimed production
-- had applied broken SQL and been hot-patched afterwards. That was wrong.
-- The authoritative record is supabase_migrations.schema_migrations.statements,
-- which stores the exact text of every applied migration. It shows:
--
--   * 20261107140036 and 20261107140057 were APPLIED with the CORRECT bodies
--     (participants-array matching), together with DROP TRIGGER IF EXISTS /
--     CREATE TRIGGER and a REVOKE. Production was never broken.
--   * The CHECKED-IN files for those two versions are the corrupted variants:
--     they use `DELETE FROM public.chats WHERE lawyer_id = OLD.id` and
--     `WHERE user_id = OLD.id`, but public.chats has neither column (its
--     columns are id, participants, participant_names, last_message,
--     created_at, updated_at, booking_id, case_id). They also omit the
--     trigger-creation and REVOKE statements entirely.
--
-- Because both versions are already recorded as applied, `supabase db push`
-- will never re-run them on this project, so the repository stays wrong unless
-- it is repaired. Any environment built from the repository alone (new branch,
-- restore, disaster recovery) would install the broken bodies, and the first
-- DELETE from public.users — exactly what ON DELETE CASCADE performs when the
-- Auth user is removed — would raise
--   ERROR 42703: column "user_id" does not exist
-- and abort the entire account deletion.
--
-- WHAT THIS MIGRATION DOES
-- ------------------------
-- Re-asserts the corrected function bodies so that the repository and the
-- database agree again. Chats are matched through the `participants` text[]
-- column (for a user) or through booking/case ownership (for a lawyer).
--
-- It does NOT recreate the triggers or the REVOKE: production already has
-- them (created by the original applied migrations), and re-issuing them is
-- out of scope here. A repository-only rebuild would still need those two
-- statements — see the review report; adding them is proposed as a separate
-- idempotent migration.
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
