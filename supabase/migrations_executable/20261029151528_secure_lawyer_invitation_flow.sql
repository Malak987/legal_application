-- Secure owner/admin lawyer invitations.
--
-- A pending profile is created only by the service-role Edge Function's
-- authenticated caller after the database re-checks the caller's role. The
-- invitation token is random, stored as a hash in the private schema, and
-- matched to the confirmed Auth email before the profile is linked or a public
-- lawyer listing is created. Browser-supplied role/metadata is never used to
-- assign a privilege. The Auth redirect remains operator-configured.

BEGIN;

ALTER TABLE public.users
  ADD COLUMN onboarding_status text NOT NULL DEFAULT 'active';
ALTER TABLE public.users
  ADD CONSTRAINT users_onboarding_status_check
  CHECK (onboarding_status IN ('active', 'invitation_pending', 'invitation_failed')) NOT VALID;
ALTER TABLE public.users VALIDATE CONSTRAINT users_onboarding_status_check;

CREATE TABLE private.pending_lawyer_invitations (
  profile_id text PRIMARY KEY
    REFERENCES public.users(id) ON DELETE CASCADE,
  email_normalized text NOT NULL UNIQUE,
  token_hash text NOT NULL UNIQUE
    CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  profile_name text NOT NULL
    CHECK (char_length(btrim(profile_name)) BETWEEN 2 AND 160),
  category_id text NOT NULL
    REFERENCES public.legal_categories(id) ON DELETE RESTRICT,
  experience text NOT NULL DEFAULT ''
    CHECK (char_length(experience) <= 120),
  price text NOT NULL
    CHECK (char_length(price) BETWEEN 1 AND 80),
  price_value numeric(12,2) NOT NULL
    CHECK (price_value > 0 AND price_value <= 1000000),
  image text NOT NULL DEFAULT 'images/lawyer2.png'
    CHECK (char_length(image) <= 500),
  location text NOT NULL DEFAULT ''
    CHECK (char_length(location) <= 200),
  bio text NOT NULL DEFAULT ''
    CHECK (char_length(bio) <= 4000),
  invited_by_auth_user_id uuid
    REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE private.pending_lawyer_invitations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.pending_lawyer_invitations
  FROM PUBLIC, anon, authenticated, service_role;

-- Pending identities are not editable through the ordinary admin profile or
-- role APIs. The verified Auth trigger and the service-only failure RPC are
-- the sole permitted update paths while an invitation is pending.
CREATE OR REPLACE FUNCTION public.guard_pending_lawyer_invitation_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $function$
BEGIN
  IF OLD.onboarding_status IN ('invitation_pending', 'invitation_failed') THEN
    IF current_setting('legal.lawyer_invite_link_in_progress', true) = 'true'
       AND current_user = 'postgres'
       AND pg_trigger_depth() > 1 THEN
      RETURN NEW;
    END IF;

    IF current_user = 'postgres'
       AND auth.role() = 'service_role'
       AND NEW.id IS NOT DISTINCT FROM OLD.id
       AND NEW.uid IS NOT DISTINCT FROM OLD.uid
       AND NEW.auth_user_id IS NOT DISTINCT FROM OLD.auth_user_id
       AND NEW.name IS NOT DISTINCT FROM OLD.name
       AND NEW.email IS NOT DISTINCT FROM OLD.email
       AND NEW.phone IS NOT DISTINCT FROM OLD.phone
       AND NEW.role IS NOT DISTINCT FROM OLD.role
       AND NEW.avatar IS NOT DISTINCT FROM OLD.avatar
       AND NEW.address IS NOT DISTINCT FROM OLD.address
       AND NEW.onboarding_status IN ('invitation_pending', 'invitation_failed') THEN
      RETURN NEW;
    END IF;

    IF NEW.id IS DISTINCT FROM OLD.id
       OR NEW.uid IS DISTINCT FROM OLD.uid
       OR NEW.auth_user_id IS DISTINCT FROM OLD.auth_user_id
       OR NEW.name IS DISTINCT FROM OLD.name
       OR NEW.email IS DISTINCT FROM OLD.email
       OR NEW.phone IS DISTINCT FROM OLD.phone
       OR NEW.role IS DISTINCT FROM OLD.role
       OR NEW.avatar IS DISTINCT FROM OLD.avatar
       OR NEW.address IS DISTINCT FROM OLD.address
       OR NEW.onboarding_status IS DISTINCT FROM OLD.onboarding_status THEN
      RAISE EXCEPTION USING ERRCODE = '42501',
        MESSAGE = 'PENDING_LAWYER_INVITATION_PROFILE_LOCKED';
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;
REVOKE ALL ON FUNCTION public.guard_pending_lawyer_invitation_update()
  FROM PUBLIC, anon, authenticated, service_role;
DROP TRIGGER IF EXISTS guard_pending_lawyer_invitation_update_trigger ON public.users;
CREATE TRIGGER guard_pending_lawyer_invitation_update_trigger
  BEFORE UPDATE OF id, uid, auth_user_id, name, email, phone, role, avatar, address, onboarding_status
  ON public.users
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_pending_lawyer_invitation_update();

-- No public lawyer listing may be connected to an unconfirmed invite. The
-- trigger also protects writes that bypass the dashboard's lawyer-save RPC.
CREATE OR REPLACE FUNCTION public.guard_lawyer_profile_requires_active_account()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $function$
DECLARE
  v_role text;
  v_status text;
BEGIN
  IF NEW.user_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT u.role, u.onboarding_status
    INTO v_role, v_status
    FROM public.users AS u
   WHERE u.id = NEW.user_id;

  IF NOT FOUND OR v_role <> 'lawyer' OR v_status <> 'active' THEN
    RAISE EXCEPTION USING ERRCODE = '42501',
      MESSAGE = 'LAWYER_ACCOUNT_NOT_ACTIVE';
  END IF;
  RETURN NEW;
END;
$function$;
REVOKE ALL ON FUNCTION public.guard_lawyer_profile_requires_active_account()
  FROM PUBLIC, anon, authenticated, service_role;
DROP TRIGGER IF EXISTS guard_lawyer_profile_requires_active_account_trigger ON public.lawyers;
CREATE TRIGGER guard_lawyer_profile_requires_active_account_trigger
  BEFORE INSERT OR UPDATE OF user_id ON public.lawyers
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_lawyer_profile_requires_active_account();

-- Admin case ownership must not attach legal records to an unconfirmed
-- invitation placeholder. Preserve the existing client-only owner policy.
CREATE OR REPLACE FUNCTION private.is_eligible_case_owner(p_user_id text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, private
AS $function$
  SELECT COALESCE(
    private.is_admin()
    AND EXISTS (
      SELECT 1
        FROM public.users AS u
       WHERE u.id = p_user_id
         AND u.role = 'client'
         AND u.onboarding_status = 'active'
    ),
    false
  );
$function$;
REVOKE ALL ON FUNCTION private.is_eligible_case_owner(text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.is_eligible_case_owner(text)
  TO authenticated, service_role;

-- The preparation RPC atomically creates a lawyer-role placeholder and the
-- private one-time claim. It is callable only with the server's service-role
-- JWT, and independently verifies that the invitation was requested by an
-- owner/admin profile. It rejects duplicate public, pending, and Auth emails.
CREATE OR REPLACE FUNCTION public.rpc_admin_lawyer_invitation_prepare(
  p_invited_by_auth_user_id uuid,
  p_name text,
  p_email text,
  p_category_id text,
  p_price text,
  p_price_value numeric,
  p_experience text,
  p_location text,
  p_bio text,
  p_image text,
  p_token_hash text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private, extensions, pg_temp
AS $function$
DECLARE
  v_profile_id text;
  v_name text := btrim(COALESCE(p_name, ''));
  v_email text := lower(btrim(COALESCE(p_email, '')));
  v_category_id text := btrim(COALESCE(p_category_id, ''));
  v_price text := btrim(COALESCE(p_price, ''));
  v_price_value numeric(12,2);
  v_experience text := COALESCE(p_experience, '');
  v_location text := COALESCE(p_location, '');
  v_bio text := COALESCE(p_bio, '');
  v_image text := COALESCE(NULLIF(btrim(p_image), ''), 'images/lawyer2.png');
  v_category public.legal_categories%ROWTYPE;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'ADMIN_REQUIRED';
  END IF;

  IF p_invited_by_auth_user_id IS NULL OR NOT EXISTS (
    SELECT 1
      FROM public.users AS actor
     WHERE (actor.auth_user_id = p_invited_by_auth_user_id
            OR actor.id = p_invited_by_auth_user_id::text)
       AND actor.role IN ('owner', 'admin')
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'ADMIN_REQUIRED';
  END IF;

  IF char_length(v_name) < 2 OR char_length(v_name) > 160
     OR char_length(v_email) > 320
     OR v_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'
     OR char_length(v_category_id) = 0 OR char_length(v_category_id) > 200
     OR char_length(v_price) < 1 OR char_length(v_price) > 80
     OR p_price_value IS NULL OR p_price_value <= 0
     OR p_price_value > 1000000 OR p_price_value <> round(p_price_value, 2)
     OR char_length(v_experience) > 120
     OR char_length(v_location) > 200
     OR char_length(v_bio) > 4000
     OR char_length(v_image) > 500
     OR p_token_hash IS NULL OR p_token_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_LAWYER_INVITATION';
  END IF;

  SELECT * INTO v_category
    FROM public.legal_categories
   WHERE id = v_category_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'CATEGORY_NOT_FOUND';
  END IF;

  v_price_value := p_price_value::numeric(12,2);
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('lawyer-invite:' || v_email, 0)
  );

  IF EXISTS (
       SELECT 1 FROM private.pending_lawyer_invitations AS i
        WHERE i.email_normalized = v_email
     ) THEN
    RAISE EXCEPTION USING ERRCODE = '23505',
      MESSAGE = 'LAWYER_INVITATION_ALREADY_PENDING';
  END IF;

  IF EXISTS (
       SELECT 1 FROM public.users AS u WHERE lower(btrim(u.email)) = v_email
     ) OR EXISTS (
       SELECT 1 FROM auth.users AS au WHERE lower(au.email) = v_email
     ) THEN
    RAISE EXCEPTION USING ERRCODE = '23505', MESSAGE = 'LAWYER_EMAIL_ALREADY_EXISTS';
  END IF;

  v_profile_id := gen_random_uuid()::text;
  INSERT INTO public.users (id, uid, name, email, role, onboarding_status)
  VALUES (v_profile_id, v_profile_id, v_name, v_email, 'lawyer', 'invitation_pending');

  INSERT INTO private.pending_lawyer_invitations (
    profile_id, email_normalized, token_hash, profile_name, category_id,
    experience, price, price_value, image, location, bio,
    invited_by_auth_user_id
  ) VALUES (
    v_profile_id, v_email, p_token_hash, v_name, v_category.id,
    v_experience, v_price, v_price_value, v_image, v_location, v_bio,
    p_invited_by_auth_user_id
  );

  RETURN jsonb_build_object(
    'profile_id', v_profile_id,
    'onboarding_status', 'invitation_pending'
  );
END;
$function$;
REVOKE ALL ON FUNCTION public.rpc_admin_lawyer_invitation_prepare(
  uuid, text, text, text, text, numeric, text, text, text, text, text
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_admin_lawyer_invitation_prepare(
  uuid, text, text, text, text, numeric, text, text, text, text, text
) TO service_role;

-- An email-delivery failure may happen after Auth has created an unconfirmed
-- identity. Retain the one-time claim so a delayed/retried confirmation cannot
-- fall through to the unprivileged client-signup path. Only this server RPC can
-- mark the still-unlinked placeholder as failed; a later valid confirmation
-- can still promote it to active through the Auth trigger below.
CREATE OR REPLACE FUNCTION public.rpc_admin_lawyer_invitation_mark_failed(
  p_profile_id text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private, pg_temp
AS $function$
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'ADMIN_REQUIRED';
  END IF;

  UPDATE public.users AS u
     SET onboarding_status = 'invitation_failed', updated_at = now()
   WHERE u.id = p_profile_id
     AND u.role = 'lawyer'
     AND u.auth_user_id IS NULL
     AND u.onboarding_status = 'invitation_pending'
     AND EXISTS (
       SELECT 1 FROM private.pending_lawyer_invitations AS i
        WHERE i.profile_id = u.id
     );
  RETURN FOUND;
END;
$function$;
REVOKE ALL ON FUNCTION public.rpc_admin_lawyer_invitation_mark_failed(text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_admin_lawyer_invitation_mark_failed(text)
  TO service_role;

-- Auth metadata by itself is not authority. A confirmed email and the
-- unguessable, server-created one-time token must match a private pending row.
-- Only then does the trigger link the Auth identity, activate the profile and
-- create the public lawyer listing in the same Auth transaction.
CREATE OR REPLACE FUNCTION public.link_migrated_auth_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private, extensions, pg_temp
AS $function$
DECLARE
  v_legacy_uid text;
  v_name text;
  v_signup_role text;
  v_email_confirmed boolean;
  v_phone_confirmed boolean;
  v_invite_token text;
  v_invite_hash text;
  v_invite private.pending_lawyer_invitations%ROWTYPE;
  v_profile public.users%ROWTYPE;
  v_category_name text;
  v_updated integer;
BEGIN
  v_email_confirmed := NEW.email IS NOT NULL AND NEW.email_confirmed_at IS NOT NULL;
  v_phone_confirmed := NEW.phone IS NOT NULL AND NEW.phone_confirmed_at IS NOT NULL;
  IF NOT v_email_confirmed AND NOT v_phone_confirmed THEN
    RETURN NEW;
  END IF;

  -- Do not treat an unconfirmed address/number change as a verified identity.
  -- A simultaneous confirmation of the other contact may still provision a
  -- client profile, but only already-confirmed contact values are persisted.
  IF TG_OP = 'UPDATE'
     AND OLD.email IS DISTINCT FROM NEW.email
     AND OLD.email_confirmed_at IS NOT DISTINCT FROM NEW.email_confirmed_at
     AND OLD.phone_confirmed_at IS NOT DISTINCT FROM NEW.phone_confirmed_at THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE'
     AND OLD.phone IS DISTINCT FROM NEW.phone
     AND OLD.phone_confirmed_at IS NOT DISTINCT FROM NEW.phone_confirmed_at
     AND OLD.email_confirmed_at IS NOT DISTINCT FROM NEW.email_confirmed_at THEN
    RETURN NEW;
  END IF;

  -- Keep an existing explicit Auth mapping; update only confirmed contacts,
  -- never the stored application role or identity columns.
  UPDATE public.users
     SET email = CASE WHEN v_email_confirmed THEN NEW.email ELSE email END,
         phone = CASE WHEN v_phone_confirmed THEN NEW.phone ELSE phone END,
         updated_at = now()
   WHERE auth_user_id = NEW.id;
  IF FOUND THEN
    RETURN NEW;
  END IF;

  -- For an invitation, user_metadata carries only an opaque claim. It cannot
  -- choose a role: the private row supplies the role, profile and lawyer data.
  v_invite_token := NULLIF(btrim(COALESCE(NEW.raw_user_meta_data ->> 'lawyer_invite_token', '')), '');
  IF v_invite_token IS NOT NULL THEN
    IF NOT v_email_confirmed THEN
      RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'LAWYER_INVITATION_EMAIL_NOT_CONFIRMED';
    END IF;

    v_invite_hash := encode(
      extensions.digest(convert_to(v_invite_token, 'UTF8'), 'sha256'),
      'hex'
    );
    SELECT * INTO v_invite
      FROM private.pending_lawyer_invitations AS i
     WHERE i.token_hash = v_invite_hash
       AND i.email_normalized = lower(btrim(NEW.email))
     FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'LAWYER_INVITATION_INVALID';
    END IF;

    PERFORM pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended('lawyer-profile:' || v_invite.profile_id, 0)
    );
    SELECT * INTO v_profile
      FROM public.users AS u
     WHERE u.id = v_invite.profile_id
     FOR UPDATE;
    IF NOT FOUND
       OR v_profile.role <> 'lawyer'
       OR v_profile.auth_user_id IS NOT NULL
       OR v_profile.onboarding_status NOT IN ('invitation_pending', 'invitation_failed')
       OR lower(btrim(v_profile.email)) <> v_invite.email_normalized THEN
      RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'LAWYER_INVITATION_PROFILE_INVALID';
    END IF;
    IF EXISTS (
      SELECT 1 FROM public.lawyers AS l WHERE l.user_id = v_invite.profile_id
    ) THEN
      RAISE EXCEPTION USING ERRCODE = '23505', MESSAGE = 'LAWYER_ACCOUNT_ALREADY_LINKED';
    END IF;

    SELECT c.name INTO v_category_name
      FROM public.legal_categories AS c
     WHERE c.id = v_invite.category_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'CATEGORY_NOT_FOUND';
    END IF;

    PERFORM set_config('legal.auth_user_link_in_progress', 'true', true);
    PERFORM set_config('legal.lawyer_invite_link_in_progress', 'true', true);
    UPDATE public.users AS u
       SET auth_user_id = NEW.id,
           email = NEW.email,
           onboarding_status = 'active',
           updated_at = now()
     WHERE u.id = v_invite.profile_id
       AND u.auth_user_id IS NULL
       AND u.role = 'lawyer'
       AND u.onboarding_status IN ('invitation_pending', 'invitation_failed')
       AND lower(btrim(u.email)) = v_invite.email_normalized;
    GET DIAGNOSTICS v_updated = ROW_COUNT;
    PERFORM set_config('legal.auth_user_link_in_progress', 'false', true);
    PERFORM set_config('legal.lawyer_invite_link_in_progress', 'false', true);
    IF v_updated <> 1 THEN
      RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'LAWYER_INVITATION_PROFILE_INVALID';
    END IF;

    INSERT INTO public.lawyers (
      user_id, name, specialty, experience, category_id, price, price_value,
      image, rating, location, bio, is_popular, is_top
    ) VALUES (
      v_invite.profile_id, v_invite.profile_name, v_category_name,
      v_invite.experience, v_invite.category_id, v_invite.price,
      v_invite.price_value, v_invite.image, 0, v_invite.location,
      v_invite.bio, false, false
    );
    DELETE FROM private.pending_lawyer_invitations
     WHERE profile_id = v_invite.profile_id;
    RETURN NEW;
  END IF;

  -- Legacy rows require both an administrator-verified exact ID and a
  -- confirmed, matching email. Phone alone is never used to claim legacy data.
  v_legacy_uid := NULLIF(btrim(NEW.raw_app_meta_data ->> 'legacy_uid'), '');
  IF v_email_confirmed
     AND v_legacy_uid IS NOT NULL
     AND NEW.raw_app_meta_data ->> 'legacy_migration_verified' = 'true' THEN
    PERFORM set_config('legal.auth_user_link_in_progress', 'true', true);
    UPDATE public.users
       SET auth_user_id = NEW.id,
           email = NEW.email,
           updated_at = now()
     WHERE id = v_legacy_uid
       AND auth_user_id IS NULL
       AND lower(email) = lower(NEW.email);
    PERFORM set_config('legal.auth_user_link_in_progress', 'false', true);
    RETURN NEW;
  END IF;

  v_name := btrim(COALESCE(NEW.raw_user_meta_data ->> 'name', ''));
  IF char_length(v_name) < 2 THEN
    v_name := CASE
      WHEN v_email_confirmed THEN split_part(NEW.email, '@', 1)
      ELSE 'Client'
    END;
  END IF;
  IF char_length(btrim(v_name)) < 2 THEN
    v_name := 'Client';
  END IF;

  -- Preserve the existing trusted signup path. The new dashboard-invite path
  -- above does not inspect metadata role fields and accepts only a private
  -- one-time claim; ordinary and phone signups retain the existing policy.
  v_signup_role := CASE
    WHEN v_email_confirmed
     AND NEW.raw_app_meta_data ->> 'signup_role' = 'lawyer' THEN 'lawyer'
    ELSE 'client'
  END;

  INSERT INTO public.users (id, uid, auth_user_id, name, email, phone, role)
  VALUES (
    NEW.id::text,
    NEW.id::text,
    NEW.id,
    v_name,
    CASE WHEN v_email_confirmed THEN NEW.email ELSE '' END,
    CASE WHEN v_phone_confirmed THEN NEW.phone ELSE '' END,
    v_signup_role
  )
  ON CONFLICT DO NOTHING;

  RETURN NEW;
END;
$function$;
REVOKE ALL ON FUNCTION public.link_migrated_auth_user()
  FROM PUBLIC, anon, authenticated, service_role;

COMMIT;