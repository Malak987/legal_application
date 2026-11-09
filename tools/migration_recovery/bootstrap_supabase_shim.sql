-- =============================================================================
-- Disposable local replay shim — NOT part of the application schema.
-- =============================================================================
-- The 38 migrations were written against a Supabase project, so they reference
-- platform objects that a stock PostgreSQL server does not have. This file
-- creates the minimum stand-ins needed to replay the migrations locally in a
-- throwaway cluster, purely to validate that the recovered SQL is syntactically
-- valid and applies in the recorded order.
--
-- It is a shim, not a reimplementation: it provides only the objects the
-- migrations actually touch (auth.uid/auth.role/auth.users, storage.buckets,
-- storage.objects, storage.foldername, and the three Supabase roles). It is
-- NEVER applied to production and is not referenced by the application.
-- =============================================================================

-- Supabase's fixed roles. service_role is deliberately NOBYPASSRLS off so the
-- "service_role bypasses RLS" production behaviour is reproduced.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN NOINHERIT BYPASSRLS;
  END IF;
  -- Platform role that exists in every Supabase project; 20261105214842 grants
  -- EXECUTE on public.is_admin() to it.
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_auth_admin') THEN
    CREATE ROLE supabase_auth_admin NOLOGIN NOINHERIT;
  END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- auth schema (minimal)
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS auth;

CREATE TABLE IF NOT EXISTS auth.users (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  instance_id           uuid,
  aud                   varchar(255),
  role                  varchar(255),
  email                 varchar(255),
  encrypted_password    varchar(255),
  email_confirmed_at    timestamptz,
  invited_at            timestamptz,
  confirmation_token    varchar(255),
  confirmation_sent_at  timestamptz,
  recovery_token        varchar(255),
  recovery_sent_at      timestamptz,
  email_change_token    varchar(255),
  email_change          varchar(255),
  email_change_sent_at  timestamptz,
  last_sign_in_at       timestamptz,
  raw_app_meta_data     jsonb,
  raw_user_meta_data    jsonb,
  is_super_admin        boolean,
  phone                 text,
  phone_confirmed_at    timestamptz,
  phone_change          text,
  phone_change_token    varchar(255),
  phone_change_sent_at  timestamptz,
  confirmed_at          timestamptz,
  banned_until          timestamptz,
  reauthentication_token varchar(255),
  reauthentication_sent_at timestamptz,
  created_at            timestamptz DEFAULT now(),
  updated_at            timestamptz DEFAULT now()
);

-- In a real project these read the request GUCs set by PostgREST. Offline they
-- simply report "no authenticated user", which is what every migration path
-- must fall back to safely.
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid
LANGUAGE sql STABLE AS $$ SELECT NULL::uuid $$;

CREATE OR REPLACE FUNCTION auth.role() RETURNS text
LANGUAGE sql STABLE AS $$ SELECT NULL::text $$;

CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb
LANGUAGE sql STABLE AS $$ SELECT NULL::jsonb $$;

-- ---------------------------------------------------------------------------
-- storage schema (minimal)
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS storage;

CREATE TABLE IF NOT EXISTS storage.buckets (
  id                  text PRIMARY KEY,
  name                text NOT NULL,
  owner               uuid,
  public              boolean DEFAULT false,
  avif_autodetection  boolean DEFAULT false,
  file_size_limit     bigint,
  allowed_mime_types  text[],
  created_at          timestamptz DEFAULT now(),
  updated_at          timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS storage.objects (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bucket_id        text REFERENCES storage.buckets(id),
  name             text,
  owner            uuid,
  created_at       timestamptz DEFAULT now(),
  updated_at       timestamptz DEFAULT now(),
  last_accessed_at timestamptz DEFAULT now(),
  metadata         jsonb,
  version          text,
  path_tokens      text[] GENERATED ALWAYS AS (string_to_array(name, '/')) STORED
);

-- Supabase's implementation drops the final path element (the file name), so
-- foldername('u1/documents/a.pdf') = '{u1,documents}'. The 20261025140000
-- policies depend on that exact behaviour: they assert array_length(...) = 2
-- and foldername(name)[2] = 'documents'.
CREATE OR REPLACE FUNCTION storage.foldername(name text) RETURNS text[]
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  _parts text[];
BEGIN
  SELECT string_to_array(name, '/') INTO _parts;
  RETURN _parts[1:array_length(_parts, 1) - 1];
END
$$;

-- Realtime publication. Created empty here; 20261028105210 adds
-- public.chat_messages and public.chats to it.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    CREATE PUBLICATION supabase_realtime;
  END IF;
END
$$;
