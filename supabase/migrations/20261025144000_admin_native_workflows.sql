-- Migration: 20261025144000_admin_native_workflows.sql
-- Supabase-native, database-authorized admin workflows for the Flutter panel.
-- Lawyer account links are read/written only through these admin-checked RPCs;
-- ordinary authenticated catalogue reads never receive lawyers.user_id.

BEGIN
-- Category renames synchronize denormalized lawyer/case labels. This trigger
-- keeps using a trusted definer because lawyer/case writes are narrowed below;
-- it independently rechecks the JWT-bound administrator role before syncing.
CREATE OR REPLACE FUNCTION public.sync_legal_category_labels()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'ADMIN_REQUIRED';
  END IF;
  IF NEW.name IS DISTINCT FROM OLD.name THEN
    UPDATE public.lawyers SET specialty = NEW.name WHERE category_id = NEW.id;
    UPDATE public.cases SET case_type = NEW.name WHERE category_id = NEW.id;
  END IF;
  RETURN NEW;
END;
$$
REVOKE ALL ON FUNCTION public.sync_legal_category_labels() FROM PUBLIC, anon, authenticated, service_role
-- Lawyer-to-profile links are private administration data. The panel uses a
-- caller-JWT RPC that rechecks the stored administrator role and validates the
-- linked account instead of granting authenticated users this column.
REVOKE INSERT, UPDATE, DELETE ON public.lawyers FROM authenticated
REVOKE INSERT (user_id, name, specialty, experience, price, price_value, image,
               rating, location, bio, is_popular, is_top, category_id)
  ON public.lawyers FROM authenticated
REVOKE UPDATE (name, specialty, experience, price, price_value, image, rating,
               location, bio, is_popular, is_top, category_id)
  ON public.lawyers FROM authenticated
REVOKE DELETE ON public.lawyers FROM authenticated
-- Preserve the reviewed public lawyer catalogue projection and the normalized
-- category relationship needed by authenticated case/lawyer workspace views.
GRANT SELECT (id, name, specialty, price, price_value, image, rating, location,
              experience, bio, is_popular, is_top, category_id)
  ON public.lawyers TO anon, authenticated
CREATE OR REPLACE FUNCTION public.rpc_admin_lawyers_page(
  p_page integer DEFAULT 1,
  p_limit integer DEFAULT 50,
  p_search text DEFAULT NULL,
  p_category_id text DEFAULT NULL,
  p_is_popular boolean DEFAULT NULL,
  p_is_top boolean DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_page integer := COALESCE(p_page, 1);
  v_limit integer := COALESCE(p_limit, 50);
  v_search text := NULLIF(btrim(COALESCE(p_search, '')), '');
  v_total bigint;
  v_items jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'ADMIN_REQUIRED';
  END IF;
  IF v_page < 1 OR v_limit < 1 OR v_limit > 100 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PAGE';
  END IF;

  SELECT count(*) INTO v_total
    FROM public.lawyers AS l
   WHERE (p_category_id IS NULL OR l.category_id = p_category_id)
     AND (p_is_popular IS NULL OR l.is_popular = p_is_popular)
     AND (p_is_top IS NULL OR l.is_top = p_is_top)
     AND (v_search IS NULL OR position(lower(v_search) IN lower(concat_ws(' ', l.name, l.specialty, l.location))) > 0);

  SELECT COALESCE(
           jsonb_agg(to_jsonb(page_rows)
             ORDER BY page_rows.rating DESC, page_rows.name ASC, page_rows.id ASC),
           '[]'::jsonb
         )
    INTO v_items
    FROM (
      SELECT l.*
        FROM public.lawyers AS l
       WHERE (p_category_id IS NULL OR l.category_id = p_category_id)
         AND (p_is_popular IS NULL OR l.is_popular = p_is_popular)
         AND (p_is_top IS NULL OR l.is_top = p_is_top)
         AND (v_search IS NULL OR position(lower(v_search) IN lower(concat_ws(' ', l.name, l.specialty, l.location))) > 0)
       ORDER BY l.rating DESC, l.name ASC, l.id ASC
       OFFSET ((v_page - 1) * v_limit)
       LIMIT v_limit
    ) AS page_rows;

  RETURN jsonb_build_object(
    'items', v_items,
    'page', v_page,
    'limit', v_limit,
    'total', v_total,
    'totalPages', GREATEST(1, CEIL(v_total::numeric / v_limit)::integer)
  );
END;
$$
REVOKE ALL ON FUNCTION public.rpc_admin_lawyers_page(integer, integer, text, text, boolean, boolean)
  FROM PUBLIC, anon, service_role
GRANT EXECUTE ON FUNCTION public.rpc_admin_lawyers_page(integer, integer, text, text, boolean, boolean)
  TO authenticated
-- This is the only client-authorized lawyer catalogue write surface. The
-- function validates the category, requires a lawyer-role profile for every
-- linked account, and serializes link changes so one account cannot be linked
-- to multiple lawyer records through concurrent administrator requests.
CREATE OR REPLACE FUNCTION public.rpc_admin_lawyer_save(
  p_lawyer_id text,
  p_name text DEFAULT NULL,
  p_user_id text DEFAULT NULL,
  p_category_id text DEFAULT NULL,
  p_experience text DEFAULT NULL,
  p_price text DEFAULT NULL,
  p_price_value numeric DEFAULT NULL,
  p_image text DEFAULT NULL,
  p_rating numeric DEFAULT NULL,
  p_location text DEFAULT NULL,
  p_bio text DEFAULT NULL,
  p_is_popular boolean DEFAULT NULL,
  p_is_top boolean DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_lawyer public.lawyers%ROWTYPE;
  v_category public.legal_categories%ROWTYPE;
  v_user_id text;
  v_category_id text;
  v_name text;
  v_experience text;
  v_price text;
  v_price_value numeric(12,2);
  v_image text;
  v_rating numeric(3,2);
  v_location text;
  v_bio text;
  v_is_popular boolean;
  v_is_top boolean;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'ADMIN_REQUIRED';
  END IF;

  IF p_lawyer_id IS NULL OR btrim(p_lawyer_id) = '' THEN
    v_name := btrim(COALESCE(p_name, ''));
    v_category_id := NULLIF(btrim(COALESCE(p_category_id, '')), '');
    v_experience := COALESCE(p_experience, '');
    v_price := COALESCE(p_price, '');
    v_price_value := p_price_value;
    v_image := COALESCE(NULLIF(p_image, ''), 'images/lawyer2.png');
    v_rating := COALESCE(p_rating, 0);
    v_location := COALESCE(p_location, '');
    v_bio := COALESCE(p_bio, '');
    v_is_popular := COALESCE(p_is_popular, false);
    v_is_top := COALESCE(p_is_top, false);
    v_user_id := NULLIF(btrim(COALESCE(p_user_id, '')), '');
  ELSE
    SELECT * INTO v_lawyer
      FROM public.lawyers
     WHERE id = p_lawyer_id
     FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'LAWYER_NOT_FOUND';
    END IF;
    v_name := CASE WHEN p_name IS NULL THEN v_lawyer.name ELSE btrim(p_name) END;
    v_category_id := COALESCE(NULLIF(btrim(COALESCE(p_category_id, '')), ''), v_lawyer.category_id);
    v_experience := COALESCE(p_experience, v_lawyer.experience);
    v_price := COALESCE(p_price, v_lawyer.price);
    v_price_value := COALESCE(p_price_value, v_lawyer.price_value);
    v_image := COALESCE(p_image, v_lawyer.image);
    v_rating := COALESCE(p_rating, v_lawyer.rating);
    v_location := COALESCE(p_location, v_lawyer.location);
    v_bio := COALESCE(p_bio, v_lawyer.bio);
    v_is_popular := COALESCE(p_is_popular, v_lawyer.is_popular);
    v_is_top := COALESCE(p_is_top, v_lawyer.is_top);
    v_user_id := CASE
      WHEN p_user_id IS NULL THEN v_lawyer.user_id
      ELSE NULLIF(btrim(p_user_id), '')
    END;
  END IF;

  IF char_length(v_name) < 2 OR char_length(v_name) > 160
     OR char_length(v_experience) > 120
     OR char_length(v_price) > 80
     OR char_length(COALESCE(v_image, '')) > 500
     OR char_length(v_location) > 200
     OR char_length(v_bio) > 4000
     OR v_rating < 0 OR v_rating > 5
     OR v_price_value IS NULL OR v_price_value <= 0 OR v_price_value > 1000000
     OR v_price_value <> round(v_price_value, 2) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_LAWYER_PROFILE';
  END IF;

  IF v_category_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'CATEGORY_REQUIRED';
  END IF;
  SELECT * INTO v_category FROM public.legal_categories WHERE id = v_category_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'CATEGORY_NOT_FOUND';
  END IF;

  IF v_user_id IS NOT NULL THEN
    PERFORM pg_advisory_xact_lock(hashtextextended('lawyer-profile:' || v_user_id, 0));
    IF NOT EXISTS (
      SELECT 1 FROM public.users AS u
       WHERE u.id = v_user_id AND u.role = 'lawyer'
    ) THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'LAWYER_ACCOUNT_REQUIRED';
    END IF;
    IF EXISTS (
      SELECT 1 FROM public.lawyers AS l
       WHERE l.user_id = v_user_id
         AND l.id IS DISTINCT FROM NULLIF(p_lawyer_id, '')
    ) THEN
      RAISE EXCEPTION USING ERRCODE = '23505', MESSAGE = 'LAWYER_ACCOUNT_ALREADY_LINKED';
    END IF;
  END IF;

  IF p_lawyer_id IS NULL OR btrim(p_lawyer_id) = '' THEN
    INSERT INTO public.lawyers (
      user_id, name, specialty, experience, category_id, price, price_value,
      image, rating, location, bio, is_popular, is_top
    ) VALUES (
      v_user_id, v_name, v_category.name, v_experience, v_category.id, v_price,
      v_price_value, v_image, v_rating, v_location, v_bio, v_is_popular, v_is_top
    )
    RETURNING * INTO v_lawyer;
  ELSE
    UPDATE public.lawyers
       SET user_id = v_user_id,
           name = v_name,
           specialty = v_category.name,
           experience = v_experience,
           category_id = v_category.id,
           price = v_price,
           price_value = v_price_value,
           image = v_image,
           rating = v_rating,
           location = v_location,
           bio = v_bio,
           is_popular = v_is_popular,
           is_top = v_is_top,
           updated_at = now()
     WHERE id = p_lawyer_id
     RETURNING * INTO v_lawyer;
  END IF;
  RETURN to_jsonb(v_lawyer);
END;
$$
REVOKE ALL ON FUNCTION public.rpc_admin_lawyer_save(text, text, text, text, text, text, numeric, text, numeric, text, text, boolean, boolean)
  FROM PUBLIC, anon, service_role
GRANT EXECUTE ON FUNCTION public.rpc_admin_lawyer_save(text, text, text, text, text, text, numeric, text, numeric, text, text, boolean, boolean)
  TO authenticated
CREATE OR REPLACE FUNCTION public.rpc_admin_lawyer_get(p_lawyer_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_lawyer public.lawyers%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'ADMIN_REQUIRED';
  END IF;
  SELECT * INTO v_lawyer FROM public.lawyers WHERE id = p_lawyer_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'LAWYER_NOT_FOUND';
  END IF;
  RETURN to_jsonb(v_lawyer);
END;
$$
REVOKE ALL ON FUNCTION public.rpc_admin_lawyer_get(text) FROM PUBLIC, anon, service_role
GRANT EXECUTE ON FUNCTION public.rpc_admin_lawyer_get(text) TO authenticated
CREATE OR REPLACE FUNCTION public.rpc_admin_lawyer_delete(p_lawyer_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'ADMIN_REQUIRED';
  END IF;
  DELETE FROM public.lawyers WHERE id = p_lawyer_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'LAWYER_NOT_FOUND';
  END IF;
  RETURN jsonb_build_object('id', p_lawyer_id, 'deleted', true);
END;
$$
REVOKE ALL ON FUNCTION public.rpc_admin_lawyer_delete(text) FROM PUBLIC, anon, service_role
GRANT EXECUTE ON FUNCTION public.rpc_admin_lawyer_delete(text) TO authenticated
COMMIT