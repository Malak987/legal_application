-- Migration: 20261025143000_supabase_native_workflows.sql
-- Completes the PostgREST grants required by both Flutter clients and adds the
-- narrowly scoped lawyer-workspace and atomic admin case-update RPCs.

BEGIN;
-- Public category reads and administrator-only catalog writes. A trigger below
-- creates stable, collision-resistant slugs when the client submits a name.
REVOKE ALL ON public.legal_categories FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.legal_categories TO anon, authenticated;
GRANT INSERT (name, slug), UPDATE (name, slug), DELETE
  ON public.legal_categories TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.legal_categories TO service_role;
CREATE OR REPLACE FUNCTION public.set_legal_category_slug()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_base text;
  v_candidate text;
BEGIN
  IF TG_OP = 'UPDATE'
     AND NEW.name IS NOT DISTINCT FROM OLD.name THEN
    RETURN NEW;
  END IF;

  v_base := lower(regexp_replace(btrim(COALESCE(NEW.name, '')), '[^A-Za-z0-9]+', '-', 'g'));
  v_base := left(trim(both '-' from v_base), 140);
  IF v_base = '' THEN
    v_base := 'category';
  END IF;
  v_candidate := v_base || '-' || left(replace(COALESCE(NEW.id, gen_random_uuid()::text), '-', ''), 16);
  NEW.slug := left(v_candidate, 160);
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.set_legal_category_slug() FROM PUBLIC, anon, authenticated, service_role;
DROP TRIGGER IF EXISTS trg_legal_category_slug ON public.legal_categories;
CREATE TRIGGER trg_legal_category_slug
  BEFORE INSERT OR UPDATE OF name ON public.legal_categories
  FOR EACH ROW EXECUTE FUNCTION public.set_legal_category_slug();
-- PostgREST receives only the fields needed by the catalog and category
-- relationships. Never expose lawyers.user_id through a client table grant.
GRANT SELECT (category_id) ON public.lawyers TO anon, authenticated;
GRANT INSERT (category_id) ON public.lawyers TO authenticated;
GRANT UPDATE (category_id, specialty) ON public.lawyers TO authenticated;
-- Case assignment columns are necessary for the reviewed admin form. The FK
-- pair and RLS continue to reject mismatched/non-admin assignments.
GRANT INSERT (lawyer_id, category_id) ON public.cases TO authenticated;
GRANT SELECT (lawyer_id, category_id) ON public.cases TO authenticated;
-- Case ownership for new/reassigned admin cases is a client profile only.
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
      SELECT 1 FROM public.users AS u
       WHERE u.id = p_user_id AND u.role = 'client'
    ),
    false
  );
$$;
REVOKE ALL ON FUNCTION private.is_eligible_case_owner(text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.is_eligible_case_owner(text) TO authenticated, service_role;
CREATE OR REPLACE FUNCTION public.is_eligible_case_owner(p_user_id text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$ SELECT private.is_eligible_case_owner(p_user_id); $$;
REVOKE ALL ON FUNCTION public.is_eligible_case_owner(text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.is_eligible_case_owner(text) TO authenticated;
-- Earnings are visible only to the account's lawyer, or an administrator.
DROP POLICY IF EXISTS earnings_select_owner_or_admin ON public.earnings;
DROP POLICY IF EXISTS earnings_select_lawyer_owner_or_admin ON public.earnings;
CREATE POLICY earnings_select_lawyer_owner_or_admin ON public.earnings
  FOR SELECT TO authenticated
  USING (
    public.is_admin()
    OR (
      public.current_app_user_role() = 'lawyer'
      AND user_id = public.current_app_user_id()
    )
  );
-- A lawyer can request only their own availability. No profile ID or lawyer ID
-- is accepted from the caller, and the result is paged in the database.
CREATE OR REPLACE FUNCTION public.rpc_lawyer_my_availability(
  p_page integer DEFAULT 1,
  p_limit integer DEFAULT 100
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_actor text := public.current_app_user_id();
  v_total bigint;
  v_items jsonb;
BEGIN
  IF auth.uid() IS NULL OR v_actor IS NULL
     OR public.current_app_user_role() <> 'lawyer' THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'LAWYER_REQUIRED';
  END IF;
  IF p_page IS NULL OR p_page < 1 OR p_limit IS NULL OR p_limit < 1 OR p_limit > 100 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PAGE';
  END IF;

  SELECT count(*) INTO v_total
    FROM public.availability AS a
    JOIN public.lawyers AS l ON l.id = a.lawyer_id
   WHERE l.user_id = v_actor;

  SELECT COALESCE(jsonb_agg(to_jsonb(page_rows) ORDER BY page_rows.date DESC, page_rows.created_at DESC), '[]'::jsonb)
    INTO v_items
    FROM (
      SELECT a.*
        FROM public.availability AS a
        JOIN public.lawyers AS l ON l.id = a.lawyer_id
       WHERE l.user_id = v_actor
       ORDER BY a.date DESC, a.created_at DESC
       OFFSET ((p_page - 1) * p_limit)
       LIMIT p_limit
    ) AS page_rows;

  RETURN jsonb_build_object(
    'items', v_items,
    'total', v_total,
    'page', p_page,
    'limit', p_limit,
    'totalPages', GREATEST(1, CEIL(v_total::numeric / p_limit)::integer)
  );
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_lawyer_my_availability(integer, integer) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_lawyer_my_availability(integer, integer) TO authenticated;
-- Atomic admin update for case content, client ownership and the normalized
-- lawyer/category pair. Direct client updates remain owner-scoped and cannot
-- change any of these protected assignment fields.
CREATE OR REPLACE FUNCTION public.rpc_admin_case_update(
  p_case_id text,
  p_changes jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_case public.cases%ROWTYPE;
  v_owner text;
  v_category_id text;
  v_lawyer_id text;
  v_category_name text;
  v_key text;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'ADMIN_REQUIRED';
  END IF;
  IF p_changes IS NULL OR jsonb_typeof(p_changes) <> 'object' OR p_changes = '{}'::jsonb THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_CASE_PATCH';
  END IF;
  FOR v_key IN SELECT jsonb_object_keys(p_changes) LOOP
    IF v_key NOT IN (
      'title', 'description', 'client_name', 'case_type', 'priority',
      'due_date', 'status', 'user_id', 'lawyer_id', 'category_id'
    ) THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_CASE_FIELD';
    END IF;
  END LOOP;

  SELECT * INTO v_case FROM public.cases WHERE id = p_case_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'CASE_NOT_FOUND';
  END IF;

  IF p_changes ? 'title'
     AND (jsonb_typeof(p_changes->'title') <> 'string'
       OR char_length(btrim(p_changes->>'title')) < 2
       OR char_length(p_changes->>'title') > 200) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_CASE_TITLE';
  END IF;
  IF p_changes ? 'description'
     AND (jsonb_typeof(p_changes->'description') NOT IN ('string', 'null')
       OR char_length(COALESCE(p_changes->>'description', '')) > 4000) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_CASE_DESCRIPTION';
  END IF;
  IF p_changes ? 'client_name'
     AND (jsonb_typeof(p_changes->'client_name') NOT IN ('string', 'null')
       OR char_length(COALESCE(p_changes->>'client_name', '')) > 160) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_CASE_CLIENT_NAME';
  END IF;
  IF p_changes ? 'case_type'
     AND (jsonb_typeof(p_changes->'case_type') NOT IN ('string', 'null')
       OR char_length(COALESCE(p_changes->>'case_type', '')) > 120) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_CASE_TYPE';
  END IF;
  IF p_changes ? 'priority'
     AND (jsonb_typeof(p_changes->'priority') <> 'string'
       OR p_changes->>'priority' NOT IN ('High', 'Medium', 'Low')) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_CASE_PRIORITY';
  END IF;
  IF p_changes ? 'status'
     AND (jsonb_typeof(p_changes->'status') <> 'string'
       OR p_changes->>'status' NOT IN ('Open', 'In Progress', 'Closed', 'Pending')) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_CASE_STATUS';
  END IF;
  IF p_changes ? 'due_date'
     AND jsonb_typeof(p_changes->'due_date') NOT IN ('string', 'null') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_CASE_DUE_DATE';
  END IF;

  v_owner := v_case.user_id;
  IF p_changes ? 'user_id' THEN
    v_owner := NULLIF(p_changes->>'user_id', '');
    IF v_owner IS NULL OR NOT private.is_eligible_case_owner(v_owner) THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INELIGIBLE_CASE_OWNER';
    END IF;
  END IF;

  v_category_id := v_case.category_id;
  v_lawyer_id := v_case.lawyer_id;
  IF p_changes ? 'category_id' OR p_changes ? 'lawyer_id' THEN
    IF p_changes ? 'category_id' THEN
      v_category_id := NULLIF(p_changes->>'category_id', '');
    END IF;
    IF p_changes ? 'lawyer_id' THEN
      v_lawyer_id := NULLIF(p_changes->>'lawyer_id', '');
    END IF;
    IF (v_category_id IS NULL) <> (v_lawyer_id IS NULL) THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'CASE_ASSIGNMENT_PAIR_REQUIRED';
    END IF;
  END IF;
  IF v_category_id IS NOT NULL THEN
    SELECT c.name INTO v_category_name
      FROM public.legal_categories AS c
      JOIN public.lawyers AS l ON l.category_id = c.id
     WHERE c.id = v_category_id AND l.id = v_lawyer_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_CASE_ASSIGNMENT';
    END IF;
  END IF;

  UPDATE public.cases
     SET title = CASE WHEN p_changes ? 'title' THEN p_changes->>'title' ELSE title END,
         description = CASE WHEN p_changes ? 'description' THEN COALESCE(p_changes->>'description', '') ELSE description END,
         client_name = CASE WHEN p_changes ? 'client_name' THEN COALESCE(p_changes->>'client_name', '') ELSE client_name END,
         case_type = CASE
           WHEN v_category_name IS NOT NULL THEN v_category_name
           WHEN p_changes ? 'case_type' THEN COALESCE(p_changes->>'case_type', '')
           ELSE case_type
         END,
         priority = CASE WHEN p_changes ? 'priority' THEN p_changes->>'priority' ELSE priority END,
         status = CASE WHEN p_changes ? 'status' THEN p_changes->>'status' ELSE status END,
         due_date = CASE WHEN p_changes ? 'due_date' THEN COALESCE(p_changes->>'due_date', '') ELSE due_date END,
         user_id = v_owner,
         lawyer_id = v_lawyer_id,
         category_id = v_category_id,
         updated_at = now()
   WHERE id = p_case_id
   RETURNING * INTO v_case;
  RETURN to_jsonb(v_case);
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_admin_case_update(text, jsonb) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_admin_case_update(text, jsonb) TO authenticated;
-- Enforce RLS even when a role temporarily owns a table during SQL deployment.
DO $$
DECLARE
  v_table record;
BEGIN
  FOR v_table IN
    SELECT c.oid::regclass AS relation
      FROM pg_class AS c
      JOIN pg_namespace AS n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relkind IN ('r', 'p')
       AND c.relrowsecurity
  LOOP
    EXECUTE format('ALTER TABLE %s FORCE ROW LEVEL SECURITY', v_table.relation);
  END LOOP;
END;
$$;
COMMIT;