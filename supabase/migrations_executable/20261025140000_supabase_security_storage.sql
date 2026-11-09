-- =============================================================================
-- Migration: 20261025140000_supabase_security_storage.sql
-- Purpose:
--   * replace broad PostgREST table grants with a least-privilege allowlist;
--   * add status compatibility values without rewriting existing rows;
--   * remove email-only Auth identity linking and provision client profiles
--     only after email confirmation;
--   * close the audited RLS/column-write gaps; and
--   * provision the private PDF bucket used by the existing mobile document-review
--     flow and JWT-verified Edge Function (the remote project has no bucket or objects).
--
-- Forward-only hardening. Apply only after the remote migration-history drift
-- is reconciled and the complete sequence is tested on an isolated database.
-- =============================================================================

BEGIN;
-- Harden the baseline trigger helper. Timestamp maintenance needs no elevated
-- privileges; keep it invoker-rights and resolve built-ins from pg_catalog.
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog
AS $$
BEGIN
  NEW.updated_at := pg_catalog.now();
  RETURN NEW;
END;
$$;
-- The two baseline SECURITY DEFINER RPCs remain service_role-only, but their
-- search paths are pinned before this migration is considered deployable.
ALTER FUNCTION public.rpc_recalculate_lawyer_rating(text)
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.rpc_reserve_booking_slots(
  text, text, text, text, text, text, integer, numeric, text, text[], integer[]
) SET search_path = pg_catalog, public, pg_temp;
-- Preflight existing values before replacing constraints. This is deliberately
-- read-only: do not normalize or rewrite an unknown legacy label. A non-zero
-- count aborts the transaction with a count only, so operators can inspect the
-- data through their approved process and choose an explicit forward plan.
DO $$
DECLARE
  v_invalid_bookings bigint;
  v_invalid_tasks bigint;
BEGIN
  SELECT count(*) INTO v_invalid_bookings
    FROM public.bookings
   WHERE status IS NULL
      OR status NOT IN ('Pending', 'Confirmed', 'Active', 'Completed', 'Cancelled');
  SELECT count(*) INTO v_invalid_tasks
    FROM public.tasks
   WHERE status IS NULL
      OR status NOT IN ('Pending', 'In Progress', 'Completed', 'Cancelled', 'To Do', 'Done');
  IF v_invalid_bookings > 0 OR v_invalid_tasks > 0 THEN
    RAISE EXCEPTION 'Status preflight failed: % unsupported booking rows, % unsupported task rows; no data was changed',
      v_invalid_bookings, v_invalid_tasks;
  END IF;
END;
$$;
-- Preserve verified status values and add the values used by the
-- authenticated RPC/client contract. Keep legacy task labels until an explicitly
-- approved data-conversion plan exists. No row is rewritten by this migration.
ALTER TABLE public.bookings
  DROP CONSTRAINT IF EXISTS bookings_status_check;
ALTER TABLE public.bookings
  ADD CONSTRAINT bookings_status_check
  CHECK (status IN ('Pending', 'Confirmed', 'Active', 'Completed', 'Cancelled')) NOT VALID;
ALTER TABLE public.bookings VALIDATE CONSTRAINT bookings_status_check;
ALTER TABLE public.tasks
  DROP CONSTRAINT IF EXISTS tasks_status_check;
ALTER TABLE public.tasks
  ADD CONSTRAINT tasks_status_check
  CHECK (status IN ('Pending', 'In Progress', 'Completed', 'Cancelled', 'To Do', 'Done')) NOT VALID;
ALTER TABLE public.tasks VALIDATE CONSTRAINT tasks_status_check;
-- These fields are read by the Supabase clients and needed for reliable retries.
ALTER TABLE public.lawyers
  ADD COLUMN IF NOT EXISTS experience text NOT NULL DEFAULT '';
ALTER TABLE public.bookings
  ADD COLUMN IF NOT EXISTS idempotency_key_hash text;
CREATE UNIQUE INDEX IF NOT EXISTS uq_bookings_user_idempotency_key_hash
  ON public.bookings (user_id, idempotency_key_hash)
  WHERE idempotency_key_hash IS NOT NULL;
-- A user without an application profile has no application identity. Keep the
-- privileged lookups in `private`; public compatibility functions are invoker-
-- rights wrappers, matching the already-applied private-helper migration.
CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC, anon;
GRANT USAGE ON SCHEMA private TO authenticated, service_role;
CREATE OR REPLACE FUNCTION private.current_app_user_id()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT u.id
    FROM public.users AS u
   WHERE auth.uid() IS NOT NULL
     AND (u.auth_user_id = auth.uid() OR u.id = auth.uid()::text)
   ORDER BY (u.auth_user_id = auth.uid()) DESC
   LIMIT 1;
$$;
CREATE OR REPLACE FUNCTION private.current_app_user_role()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT u.role
    FROM public.users AS u
   WHERE auth.uid() IS NOT NULL
     AND (u.auth_user_id = auth.uid() OR u.id = auth.uid()::text)
   ORDER BY (u.auth_user_id = auth.uid()) DESC
   LIMIT 1;
$$;
CREATE OR REPLACE FUNCTION private.is_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT COALESCE(auth.uid() IS NOT NULL AND private.current_app_user_role() = 'admin', false);
$$;
CREATE OR REPLACE FUNCTION private.is_lawyer_or_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT COALESCE(private.current_app_user_role() IN ('lawyer', 'admin'), false);
$$;
CREATE OR REPLACE FUNCTION private.is_lawyer_owner(p_lawyer_id text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT COALESCE(
    private.current_app_user_role() = 'lawyer'
    AND EXISTS (
      SELECT 1
        FROM public.lawyers AS l
       WHERE l.id = p_lawyer_id
         AND l.user_id = private.current_app_user_id()
    ),
    false
  );
$$;
CREATE OR REPLACE FUNCTION private.is_eligible_case_owner(p_user_id text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT COALESCE(
    private.is_admin()
    AND EXISTS (
      SELECT 1
        FROM public.users AS u
       WHERE u.id = p_user_id
         AND u.role IN ('client', 'lawyer')
    ),
    false
  );
$$;
CREATE OR REPLACE FUNCTION public.current_app_user_id()
RETURNS text LANGUAGE sql STABLE SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$ SELECT private.current_app_user_id(); $$;
CREATE OR REPLACE FUNCTION public.current_app_user_role()
RETURNS text LANGUAGE sql STABLE SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$ SELECT private.current_app_user_role(); $$;
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$ SELECT private.is_admin(); $$;
CREATE OR REPLACE FUNCTION public.is_lawyer_or_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$ SELECT private.is_lawyer_or_admin(); $$;
CREATE OR REPLACE FUNCTION public.is_lawyer_owner(p_lawyer_id text)
RETURNS boolean LANGUAGE sql STABLE SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$ SELECT private.is_lawyer_owner(p_lawyer_id); $$;
CREATE OR REPLACE FUNCTION public.is_eligible_case_owner(p_user_id text)
RETURNS boolean LANGUAGE sql STABLE SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$ SELECT private.is_eligible_case_owner(p_user_id); $$;
-- Email alone is not proof that a legacy account belongs to a new Auth user.
-- A migration link requires a confirmed email AND an explicit legacy UID in
-- admin-controlled raw_app_meta_data. Never read legacy_uid from raw_user_meta_data.
-- Ordinary confirmed signups get a new, unprivileged client profile.
CREATE OR REPLACE FUNCTION public.link_migrated_auth_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_legacy_uid text;
  v_name text;
BEGIN
  IF NEW.email IS NULL OR NEW.email_confirmed_at IS NULL THEN
    RETURN NEW;
  END IF;

  -- An UPDATE OF email can be an unconfirmed address change. Do not copy it to
  -- the application profile unless the confirmation timestamp also changes;
  -- real GoTrue event semantics still require staging verification.
  IF TG_OP = 'UPDATE'
     AND OLD.email IS DISTINCT FROM NEW.email
     AND OLD.email_confirmed_at IS NOT DISTINCT FROM NEW.email_confirmed_at THEN
    RETURN NEW;
  END IF;

  -- If an already-linked user confirms a new address, sync only that confirmed
  -- address. Role and identity mapping are never changed by this branch.
  UPDATE public.users
     SET email = NEW.email,
         updated_at = now()
   WHERE auth_user_id = NEW.id;
  IF FOUND THEN
    RETURN NEW;
  END IF;

  v_legacy_uid := NULLIF(trim(NEW.raw_app_meta_data ->> 'legacy_uid'), '');
  IF v_legacy_uid IS NOT NULL
     AND NEW.raw_app_meta_data ->> 'legacy_migration_verified' = 'true' THEN
    UPDATE public.users
       SET auth_user_id = NEW.id,
           updated_at = now()
     WHERE id = v_legacy_uid
       AND auth_user_id IS NULL
       AND lower(email) = lower(NEW.email);

    -- A failed explicit mapping is left unlinked for manual reconciliation;
    -- do not silently match another row by email or create a duplicate profile.
    RETURN NEW;
  END IF;

  v_name := trim(COALESCE(NEW.raw_user_meta_data ->> 'name', ''));
  IF char_length(v_name) < 2 THEN
    v_name := split_part(NEW.email, '@', 1);
  END IF;
  IF char_length(trim(v_name)) < 2 THEN
    v_name := 'Client';
  END IF;

  INSERT INTO public.users (id, uid, auth_user_id, name, email, role)
  VALUES (NEW.id::text, NEW.id::text, NEW.id, v_name, NEW.email, 'client')
  ON CONFLICT DO NOTHING;

  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_auth_users_link_migrated ON auth.users;
CREATE TRIGGER trg_auth_users_link_migrated
  AFTER INSERT OR UPDATE OF email, email_confirmed_at ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.link_migrated_auth_user();
-- Private helpers are available to authenticated policy evaluation, never anon.
-- Public compatibility wrappers are invoker-rights only.
REVOKE ALL ON FUNCTION private.current_app_user_id() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION private.current_app_user_role() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION private.is_admin() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION private.is_lawyer_or_admin() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION private.is_lawyer_owner(text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION private.is_eligible_case_owner(text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.current_app_user_id() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.current_app_user_role() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.is_admin() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.is_lawyer_or_admin() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.is_lawyer_owner(text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.is_eligible_case_owner(text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.current_app_user_id() FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.current_app_user_role() FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.is_admin() FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.is_lawyer_or_admin() FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.is_lawyer_owner(text) FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.is_eligible_case_owner(text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.current_app_user_id() TO authenticated;
GRANT EXECUTE ON FUNCTION public.current_app_user_role() TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_admin() TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_lawyer_or_admin() TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_lawyer_owner(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_eligible_case_owner(text) TO authenticated;
REVOKE ALL ON FUNCTION public.link_migrated_auth_user() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.set_updated_at() FROM PUBLIC, anon, authenticated, service_role;
-- Preserve only the two pre-existing trusted server-side RPC contracts. They
-- remain unavailable to public and authenticated clients.
REVOKE ALL ON FUNCTION public.rpc_recalculate_lawyer_rating(text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_recalculate_lawyer_rating(text)
  TO service_role;
REVOKE ALL ON FUNCTION public.rpc_reserve_booking_slots(
  text, text, text, text, text, text, integer, numeric, text, text[], integer[]
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_reserve_booking_slots(
  text, text, text, text, text, text, integer, numeric, text, text[], integer[]
) TO service_role;
-- Public reviews remain visible, but the raw table's user_id is not exposed to
-- anon/authenticated PostgREST queries. Admin-only inspection uses a trusted RPC.
CREATE OR REPLACE VIEW public.public_reviews
WITH (security_barrier = true, security_invoker = true)
AS
SELECT id, user_name, lawyer_id, rating, comment, created_at, updated_at
  FROM public.reviews;
-- Replace policies that permitted broad row/column changes.
DROP POLICY IF EXISTS users_insert_self_client_or_admin ON public.users;
DROP POLICY IF EXISTS users_update_self_or_admin ON public.users;
DROP POLICY IF EXISTS users_delete_admin_only ON public.users;
CREATE POLICY users_update_self_or_admin ON public.users
  FOR UPDATE TO authenticated
  USING (id = public.current_app_user_id() OR public.is_admin())
  WITH CHECK (id = public.current_app_user_id() OR public.is_admin());
DROP POLICY IF EXISTS cases_insert_owner_or_admin ON public.cases;
CREATE POLICY cases_insert_owner_or_admin ON public.cases
  FOR INSERT TO authenticated
  WITH CHECK (
    (user_id = public.current_app_user_id()
      AND public.current_app_user_role() IN ('client', 'lawyer'))
    OR (public.is_admin() AND public.is_eligible_case_owner(user_id))
  );
-- Booking and money mutations are RPC-only. The old table-wide admin policies
-- allowed clients to bypass schedule, price, and ledger invariants.
DROP POLICY IF EXISTS bookings_write_admin_only ON public.bookings;
DROP POLICY IF EXISTS booking_slots_write_admin_only ON public.booking_slots;
DROP POLICY IF EXISTS wallets_write_admin_only ON public.wallets;
DROP POLICY IF EXISTS wallet_tx_write_admin_only ON public.wallet_transactions;
DROP POLICY IF EXISTS wallet_idempotency_write_admin_only ON public.wallet_idempotency;
-- Chat metadata is immutable to participants; atomic RPCs append a message and
-- update last_message together. A participant may delete the shared chat, as
-- the existing route permits; its messages cascade in the same transaction.
DROP POLICY IF EXISTS chats_insert_participant_or_admin ON public.chats;
DROP POLICY IF EXISTS chats_update_participant_or_admin ON public.chats;
DROP POLICY IF EXISTS chats_delete_admin_only ON public.chats;
DROP POLICY IF EXISTS chats_delete_participant_or_admin ON public.chats;
CREATE POLICY chats_delete_participant_or_admin ON public.chats
  FOR DELETE TO authenticated
  USING (public.current_app_user_id() = ANY(participants) OR public.is_admin());
DROP POLICY IF EXISTS chat_messages_insert_participant_or_admin ON public.chat_messages;
DROP POLICY IF EXISTS chat_messages_delete_admin_only ON public.chat_messages;
-- Reviews can only be submitted/moderated through role-checked RPCs.
DROP POLICY IF EXISTS reviews_insert_owner_or_admin ON public.reviews;
DROP POLICY IF EXISTS reviews_update_owner_or_admin ON public.reviews;
DROP POLICY IF EXISTS reviews_delete_owner_or_admin ON public.reviews;
-- Subscription state is commercial data. Owners can only cancel through RPC;
-- they cannot change plan fields or activate a subscription directly.
DROP POLICY IF EXISTS subscriptions_insert_owner_pending_or_admin ON public.subscriptions;
DROP POLICY IF EXISTS subscriptions_update_owner_cancel_or_admin ON public.subscriptions;
DROP POLICY IF EXISTS subscriptions_delete_admin_only ON public.subscriptions;
-- Keep the public plan catalogue SELECT policy separate from admin writes so
-- authenticated SELECT does not overlap a permissive FOR ALL policy.
DROP POLICY IF EXISTS plans_write_admin_only ON public.plans;
DROP POLICY IF EXISTS plans_insert_admin_only ON public.plans;
DROP POLICY IF EXISTS plans_update_admin_only ON public.plans;
DROP POLICY IF EXISTS plans_delete_admin_only ON public.plans;
CREATE POLICY plans_insert_admin_only ON public.plans
  FOR INSERT TO authenticated
  WITH CHECK (public.is_admin());
CREATE POLICY plans_update_admin_only ON public.plans
  FOR UPDATE TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());
CREATE POLICY plans_delete_admin_only ON public.plans
  FOR DELETE TO authenticated
  USING (public.is_admin());
-- Notification owners may update only `read` (column grants below) and delete
-- their own notification. Admin content/recipient changes are RPC-only.
DROP POLICY IF EXISTS notifications_update_owner_or_admin ON public.notifications;
DROP POLICY IF EXISTS notifications_update_read_owner_or_admin ON public.notifications;
CREATE POLICY notifications_update_read_owner_or_admin ON public.notifications
  FOR UPDATE TO authenticated
  USING (user_id = public.current_app_user_id() OR public.is_admin())
  WITH CHECK (user_id = public.current_app_user_id() OR public.is_admin());
-- The legacy earnings endpoint is self-or-admin, not lawyer-only. There is no
-- direct financial write grant; a trusted settlement integration is still not
-- implemented.
DROP POLICY IF EXISTS earnings_select_lawyer_owner_or_admin ON public.earnings;
DROP POLICY IF EXISTS earnings_select_owner_or_admin ON public.earnings;
CREATE POLICY earnings_select_owner_or_admin ON public.earnings
  FOR SELECT TO authenticated
  USING (user_id = public.current_app_user_id() OR public.is_admin());
DROP POLICY IF EXISTS earnings_write_admin_only ON public.earnings;
-- Availability writes must be tied to the actual public.lawyers.user_id owner,
-- not merely to any account whose role says "lawyer".
DROP POLICY IF EXISTS availability_write_lawyer_or_admin ON public.availability;
DROP POLICY IF EXISTS availability_insert_owner_or_admin ON public.availability;
DROP POLICY IF EXISTS availability_update_owner_or_admin ON public.availability;
DROP POLICY IF EXISTS availability_delete_owner_or_admin ON public.availability;
CREATE POLICY availability_insert_owner_or_admin ON public.availability
  FOR INSERT TO authenticated
  WITH CHECK (public.is_admin() OR public.is_lawyer_owner(lawyer_id));
CREATE POLICY availability_update_owner_or_admin ON public.availability
  FOR UPDATE TO authenticated
  USING (public.is_admin() OR public.is_lawyer_owner(lawyer_id))
  WITH CHECK (public.is_admin() OR public.is_lawyer_owner(lawyer_id));
CREATE POLICY availability_delete_owner_or_admin ON public.availability
  FOR DELETE TO authenticated
  USING (public.is_admin() OR public.is_lawyer_owner(lawyer_id));
-- Least-privilege grants. RLS does not protect TRUNCATE, REFERENCES, or
-- TRIGGER privileges, so none is granted to the API roles. service_role remains
-- a trusted-server-only role and is limited to DML (it still bypasses RLS).
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM PUBLIC, anon, authenticated, service_role;
REVOKE CREATE ON SCHEMA public FROM PUBLIC, anon, authenticated, service_role;
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON public.users, public.lawyers, public.cases, public.bookings,
     public.booking_slots, public.tasks, public.chats, public.chat_messages,
     public.reviews, public.favorites, public.wallets, public.wallet_transactions,
     public.wallet_idempotency, public.plans, public.subscriptions,
     public.notifications, public.earnings, public.availability
  TO service_role;
-- Public catalogue data. Never expose lawyers.user_id through PostgREST.
-- These columns match the mobile catalogue allowlist; owner/admin RPCs and the
-- trusted Express adapter continue to use the full row under their own role.
GRANT SELECT (id, name, specialty, price, price_value, image, rating, location,
              experience, bio, is_popular, is_top)
  ON public.lawyers TO anon, authenticated;
GRANT SELECT ON public.plans, public.availability TO anon;
-- The public, security-invoker view exposes review display fields only. Grant
-- those same safe base columns so the view remains subject to table RLS.
GRANT SELECT (id, user_name, lawyer_id, rating, comment, created_at, updated_at)
  ON public.reviews TO anon, authenticated;
GRANT SELECT ON public.public_reviews TO anon, authenticated;
-- Authenticated read surface; RLS limits rows, and column grants limit public
-- lawyers/reviews. wallet_idempotency has no client table grant.
GRANT SELECT ON public.users, public.cases, public.booking_slots,
  public.tasks, public.chats, public.chat_messages, public.favorites,
  public.wallets, public.plans, public.subscriptions,
  public.notifications, public.earnings, public.availability
  TO authenticated;
GRANT SELECT (id, user_id, type, amount, description, balance, currency,
              created_at, updated_at)
  ON public.wallet_transactions TO authenticated;
-- Keep the booking idempotency digest private while preserving the existing
-- owner/admin booking read shape.
GRANT SELECT (id, user_id, lawyer_id, lawyer_name, date, time, hours,
              total_price, status, slot_keys, created_at, updated_at)
  ON public.bookings TO authenticated;
-- Direct chat deletion is intentionally permitted by the participant/admin
-- RLS policy above; message rows cascade atomically from the chat delete.
GRANT DELETE ON public.chats TO authenticated;
-- Self-service profile changes cannot change identity, email, or role. Admins
-- use narrowly-scoped RPCs for role/email/Auth-user operations.
GRANT UPDATE (name, phone, avatar, address) ON public.users TO authenticated;
-- Public lawyer/plan catalog management is admin-only by RLS. The ownership
-- fields are intentionally immutable in direct updates.
GRANT INSERT (user_id, name, specialty, experience, price, price_value, image,
              rating, location, bio, is_popular, is_top)
  ON public.lawyers TO authenticated;
GRANT UPDATE (name, specialty, experience, price, price_value, image, rating,
              location, bio, is_popular, is_top)
  ON public.lawyers TO authenticated;
GRANT DELETE ON public.lawyers TO authenticated;
GRANT INSERT (title, price, price_value, color, features, is_popular)
  ON public.plans TO authenticated;
GRANT UPDATE (title, price, price_value, color, features, is_popular)
  ON public.plans TO authenticated;
GRANT DELETE ON public.plans TO authenticated;
-- Owner-scoped case/task CRUD. Ownership and status changes use dedicated RPCs;
-- CREATED/UPDATED metadata is server-managed by defaults/triggers.
GRANT INSERT (user_id, title, description, client_name, case_type, priority, status, due_date)
  ON public.cases TO authenticated;
GRANT UPDATE (title, description, client_name, case_type, priority, due_date)
  ON public.cases TO authenticated;
GRANT DELETE ON public.cases TO authenticated;
GRANT INSERT (user_id, title, description, due_date, priority, status)
  ON public.tasks TO authenticated;
GRANT UPDATE (title, description, due_date, priority)
  ON public.tasks TO authenticated;
GRANT DELETE ON public.tasks TO authenticated;
-- Favorites are idempotent via the unique constraint; clients cannot reassign
-- or rewrite an existing favorite.
GRANT INSERT (user_id, lawyer_id) ON public.favorites TO authenticated;
GRANT DELETE ON public.favorites TO authenticated;
-- A client can only append/modify its own availability rows. The lawyer_id is
-- intentionally not updateable, so a lawyer cannot move another owner's row.
GRANT INSERT (lawyer_id, lawyer_name, date, slots) ON public.availability TO authenticated;
GRANT UPDATE (lawyer_name, date, slots) ON public.availability TO authenticated;
GRANT DELETE ON public.availability TO authenticated;
-- Admin-created notifications are row-scoped by RLS. Owners can only change
-- the read flag, not title/content/recipient.
GRANT INSERT (user_id, title, content, type, icon, read)
  ON public.notifications TO authenticated;
GRANT UPDATE (read) ON public.notifications TO authenticated;
GRANT DELETE ON public.notifications TO authenticated;
-- Tasks/cases state changes and all booking/chat/review/wallet/subscription
-- mutations are exposed only through the transactional functions added in the
-- next migration. Never grant clients direct UPDATE on protected fields.

-- Default privileges for future objects created by this migration owner.
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  REVOKE ALL ON TABLES FROM PUBLIC, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA storage
  REVOKE ALL ON TABLES FROM PUBLIC, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA storage
  REVOKE ALL ON SEQUENCES FROM PUBLIC, anon, authenticated, service_role;
-- Private PDF storage is required by legal_app's consent-gated document
-- review flow. Authenticated clients may read/delete only their own objects;
-- they cannot INSERT arbitrary bytes directly. The document-upload Edge
-- Function validates the byte signature first and then uses a server-side
-- service-role client for Storage insertion. That key is never shipped to a
-- client. service_role remains a trusted server role and is granted only the
-- DML needed for the upload/cleanup path; it continues to bypass RLS.
REVOKE ALL ON SCHEMA storage FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON ALL TABLES IN SCHEMA storage FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA storage FROM PUBLIC, anon, authenticated, service_role;
GRANT USAGE ON SCHEMA storage TO authenticated, service_role;
GRANT SELECT, DELETE ON storage.objects TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON storage.objects TO service_role;
GRANT SELECT ON storage.buckets TO service_role;
-- Explicitly remove any previously granted analytics access, while tolerating
-- Storage versions that do not install this internal relation.
DO $$
BEGIN
  IF to_regclass('storage.buckets_analytics') IS NOT NULL THEN
    EXECUTE 'REVOKE ALL ON TABLE storage.buckets_analytics FROM PUBLIC, anon, authenticated, service_role';
  END IF;
END;
$$;
-- Never overwrite an existing bucket's privacy/limits as a side effect of an
-- application migration. If the ID already exists with different settings,
-- stop and require an explicit operator reconciliation.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('legal-documents', 'legal-documents', false, 10485760, ARRAY['application/pdf'])
ON CONFLICT (id) DO NOTHING;
DO $$
DECLARE
  v_bucket storage.buckets%ROWTYPE;
BEGIN
  SELECT * INTO v_bucket FROM storage.buckets WHERE id = 'legal-documents';
  IF NOT FOUND
     OR v_bucket.name <> 'legal-documents'
     OR v_bucket.public IS DISTINCT FROM false
     OR v_bucket.file_size_limit IS DISTINCT FROM 10485760
     OR v_bucket.allowed_mime_types IS DISTINCT FROM ARRAY['application/pdf']::text[] THEN
    RAISE EXCEPTION 'Existing legal-documents bucket does not match the reviewed private PDF configuration';
  END IF;
END;
$$;
-- The object name must be exactly <app-user-id>/documents/<opaque-name>.pdf.
-- Storage's allowed_mime_types and file_size_limit enforce the MIME/size limits;
-- path checks below prevent arbitrary folders and extension disguises.
DROP POLICY IF EXISTS legal_documents_read_owner_or_admin ON storage.objects;
CREATE POLICY legal_documents_read_owner_or_admin ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'legal-documents'
    AND array_length(storage.foldername(name), 1) = 2
    AND (storage.foldername(name))[2] = 'documents'
    AND name ~ '^[A-Za-z0-9_-]+/documents/[A-Za-z0-9_-]+[.]pdf$'
    AND ((storage.foldername(name))[1] = public.current_app_user_id()
      OR public.is_admin())
  );
-- Clients cannot insert directly: the trusted Edge Function checks PDF bytes
-- before using its server-only Storage client. Dropping any legacy policy also
-- makes re-verification fail closed if broad grants are later reintroduced.
DROP POLICY IF EXISTS legal_documents_insert_owner_or_admin ON storage.objects;
-- No UPDATE policy/grant: object names are opaque and overwrite is disabled.

DROP POLICY IF EXISTS legal_documents_delete_owner_or_admin ON storage.objects;
CREATE POLICY legal_documents_delete_owner_or_admin ON storage.objects
  FOR DELETE TO authenticated
  USING (
    bucket_id = 'legal-documents'
    AND array_length(storage.foldername(name), 1) = 2
    AND (storage.foldername(name))[2] = 'documents'
    AND name ~ '^[A-Za-z0-9_-]+/documents/[A-Za-z0-9_-]+[.]pdf$'
    AND ((storage.foldername(name))[1] = public.current_app_user_id()
      OR public.is_admin())
  );
COMMIT;