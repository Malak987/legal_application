CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- 1. Timestamp trigger function
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

-- 2. Core Tables

-- 2.1 users
CREATE TABLE IF NOT EXISTS public.users (
  id TEXT PRIMARY KEY,
  uid TEXT NOT NULL UNIQUE,
  auth_user_id UUID UNIQUE REFERENCES auth.users(id) ON DELETE SET NULL,
  name TEXT NOT NULL CHECK (char_length(trim(name)) >= 2),
  email TEXT NOT NULL,
  phone TEXT NOT NULL DEFAULT '',
  role TEXT NOT NULL DEFAULT 'client' CHECK (role IN ('client', 'lawyer', 'admin')),
  avatar TEXT NOT NULL DEFAULT '',
  address TEXT NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT users_uid_matches_id CHECK (uid = id)
);

CREATE INDEX IF NOT EXISTS idx_users_email_lower ON public.users (lower(email));
CREATE INDEX IF NOT EXISTS idx_users_role ON public.users (role);
CREATE INDEX IF NOT EXISTS idx_users_created_at ON public.users (created_at DESC);

DROP TRIGGER IF EXISTS trg_users_updated_at ON public.users;
CREATE TRIGGER trg_users_updated_at
  BEFORE UPDATE ON public.users
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

CREATE OR REPLACE FUNCTION public.link_migrated_auth_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.email IS NOT NULL THEN
    UPDATE public.users
       SET auth_user_id = NEW.id,
           updated_at = now()
     WHERE lower(email) = lower(NEW.email)
       AND auth_user_id IS NULL;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_auth_users_link_migrated ON auth.users;
CREATE TRIGGER trg_auth_users_link_migrated
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.link_migrated_auth_user();

-- 2.2 lawyers
CREATE TABLE IF NOT EXISTS public.lawyers (
  id TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  user_id TEXT REFERENCES public.users(id) ON DELETE SET NULL,
  name TEXT NOT NULL CHECK (char_length(trim(name)) >= 2),
  specialty TEXT NOT NULL DEFAULT 'General Practice',
  price TEXT NOT NULL,
  price_value NUMERIC(12, 2) NOT NULL DEFAULT 0 CHECK (price_value >= 0),
  image TEXT NOT NULL DEFAULT 'images/lawyer2.png',
  rating NUMERIC(3, 2) NOT NULL DEFAULT 0 CHECK (rating >= 0 AND rating <= 5),
  location TEXT NOT NULL DEFAULT '',
  bio TEXT NOT NULL DEFAULT '',
  is_popular BOOLEAN NOT NULL DEFAULT false,
  is_top BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_lawyers_specialty ON public.lawyers (specialty);
CREATE INDEX IF NOT EXISTS idx_lawyers_is_popular ON public.lawyers (is_popular);
CREATE INDEX IF NOT EXISTS idx_lawyers_is_top ON public.lawyers (is_top);
CREATE INDEX IF NOT EXISTS idx_lawyers_created_at ON public.lawyers (created_at DESC);

DROP TRIGGER IF EXISTS trg_lawyers_updated_at ON public.lawyers;
CREATE TRIGGER trg_lawyers_updated_at
  BEFORE UPDATE ON public.lawyers
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- 2.3 cases
CREATE TABLE IF NOT EXISTS public.cases (
  id TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  user_id TEXT REFERENCES public.users(id) ON DELETE SET NULL,
  title TEXT NOT NULL CHECK (char_length(trim(title)) >= 2),
  description TEXT NOT NULL DEFAULT '',
  client_name TEXT NOT NULL DEFAULT '',
  case_type TEXT NOT NULL DEFAULT 'General',
  priority TEXT NOT NULL DEFAULT 'Medium' CHECK (priority IN ('High', 'Medium', 'Low')),
  status TEXT NOT NULL DEFAULT 'Open' CHECK (status IN ('Open', 'In Progress', 'Closed', 'Pending')),
  due_date TEXT NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_cases_user_id_created_at ON public.cases (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_cases_status ON public.cases (status);
CREATE INDEX IF NOT EXISTS idx_cases_priority ON public.cases (priority);
CREATE INDEX IF NOT EXISTS idx_cases_created_at ON public.cases (created_at DESC);

DROP TRIGGER IF EXISTS trg_cases_updated_at ON public.cases;
CREATE TRIGGER trg_cases_updated_at
  BEFORE UPDATE ON public.cases
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- 2.4 bookings
CREATE TABLE IF NOT EXISTS public.bookings (
  id TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  user_id TEXT NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  lawyer_id TEXT NOT NULL REFERENCES public.lawyers(id) ON DELETE RESTRICT,
  lawyer_name TEXT NOT NULL DEFAULT '',
  date TEXT NOT NULL CHECK (date ~ '^\d{4}-\d{2}-\d{2}$'),
  time TEXT NOT NULL,
  hours INTEGER NOT NULL DEFAULT 1 CHECK (hours >= 1 AND hours <= 12),
  total_price NUMERIC(12, 2) NOT NULL DEFAULT 0 CHECK (total_price >= 0),
  status TEXT NOT NULL DEFAULT 'Confirmed' CHECK (status IN ('Pending', 'Confirmed', 'Completed', 'Cancelled')),
  slot_keys TEXT[] NOT NULL DEFAULT '{}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_bookings_user_id_created_at ON public.bookings (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_bookings_lawyer_id_date ON public.bookings (lawyer_id, date);
CREATE INDEX IF NOT EXISTS idx_bookings_status ON public.bookings (status);
CREATE INDEX IF NOT EXISTS idx_bookings_created_at ON public.bookings (created_at DESC);

DROP TRIGGER IF EXISTS trg_bookings_updated_at ON public.bookings;
CREATE TRIGGER trg_bookings_updated_at
  BEFORE UPDATE ON public.bookings
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- 2.5 booking_slots
CREATE TABLE IF NOT EXISTS public.booking_slots (
  id TEXT PRIMARY KEY,
  lawyer_id TEXT NOT NULL REFERENCES public.lawyers(id) ON DELETE CASCADE,
  date TEXT NOT NULL CHECK (date ~ '^\d{4}-\d{2}-\d{2}$'),
  slot INTEGER NOT NULL CHECK (slot >= 0 AND slot < 1440),
  booking_id TEXT NOT NULL REFERENCES public.bookings(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_booking_slots_lawyer_date_slot UNIQUE (lawyer_id, date, slot)
);

CREATE INDEX IF NOT EXISTS idx_booking_slots_booking_id ON public.booking_slots (booking_id);
CREATE INDEX IF NOT EXISTS idx_booking_slots_lawyer_date ON public.booking_slots (lawyer_id, date);

-- 2.6 tasks
CREATE TABLE IF NOT EXISTS public.tasks (
  id TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  user_id TEXT NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  title TEXT NOT NULL CHECK (char_length(trim(title)) >= 2),
  description TEXT NOT NULL DEFAULT '',
  due_date TEXT NOT NULL DEFAULT '',
  priority TEXT NOT NULL DEFAULT 'Medium' CHECK (priority IN ('High', 'Medium', 'Low')),
  status TEXT NOT NULL DEFAULT 'Pending' CHECK (status IN ('Pending', 'In Progress', 'Completed')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_tasks_user_id_created_at ON public.tasks (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_tasks_status ON public.tasks (status);
CREATE INDEX IF NOT EXISTS idx_tasks_priority ON public.tasks (priority);
CREATE INDEX IF NOT EXISTS idx_tasks_created_at ON public.tasks (created_at DESC);

DROP TRIGGER IF EXISTS trg_tasks_updated_at ON public.tasks;
CREATE TRIGGER trg_tasks_updated_at
  BEFORE UPDATE ON public.tasks
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- 2.7 chats
CREATE TABLE IF NOT EXISTS public.chats (
  id TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  participants TEXT[] NOT NULL DEFAULT '{}' CHECK (cardinality(participants) >= 2),
  participant_names JSONB NOT NULL DEFAULT '{}'::jsonb,
  last_message TEXT NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_chats_participants_gin ON public.chats USING GIN (participants);
CREATE INDEX IF NOT EXISTS idx_chats_updated_at ON public.chats (updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_chats_created_at ON public.chats (created_at DESC);

DROP TRIGGER IF EXISTS trg_chats_updated_at ON public.chats;
CREATE TRIGGER trg_chats_updated_at
  BEFORE UPDATE ON public.chats
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- 2.8 chat_messages
CREATE TABLE IF NOT EXISTS public.chat_messages (
  id TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  chat_id TEXT NOT NULL REFERENCES public.chats(id) ON DELETE CASCADE,
  sender_id TEXT NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  sender_name TEXT NOT NULL DEFAULT 'Anonymous',
  text TEXT NOT NULL CHECK (char_length(trim(text)) >= 1),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_chat_messages_chat_id_created_at ON public.chat_messages (chat_id, created_at ASC);
CREATE INDEX IF NOT EXISTS idx_chat_messages_sender_id ON public.chat_messages (sender_id);

-- 2.9 reviews
CREATE TABLE IF NOT EXISTS public.reviews (
  id TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  user_id TEXT NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  user_name TEXT NOT NULL DEFAULT 'Anonymous',
  lawyer_id TEXT NOT NULL REFERENCES public.lawyers(id) ON DELETE CASCADE,
  rating NUMERIC(3, 2) NOT NULL CHECK (rating >= 1 AND rating <= 5),
  comment TEXT NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_reviews_user_lawyer UNIQUE (user_id, lawyer_id)
);

CREATE INDEX IF NOT EXISTS idx_reviews_lawyer_id_created_at ON public.reviews (lawyer_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_reviews_user_id ON public.reviews (user_id);
CREATE INDEX IF NOT EXISTS idx_reviews_created_at ON public.reviews (created_at DESC);

DROP TRIGGER IF EXISTS trg_reviews_updated_at ON public.reviews;
CREATE TRIGGER trg_reviews_updated_at
  BEFORE UPDATE ON public.reviews
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- 2.10 favorites
CREATE TABLE IF NOT EXISTS public.favorites (
  id TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  user_id TEXT NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  lawyer_id TEXT NOT NULL REFERENCES public.lawyers(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_favorites_user_lawyer UNIQUE (user_id, lawyer_id)
);

CREATE INDEX IF NOT EXISTS idx_favorites_user_id_created_at ON public.favorites (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_favorites_lawyer_id ON public.favorites (lawyer_id);

-- 2.11 wallets
CREATE TABLE IF NOT EXISTS public.wallets (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL UNIQUE REFERENCES public.users(id) ON DELETE CASCADE,
  balance NUMERIC(14, 2) NOT NULL DEFAULT 0 CHECK (balance >= 0),
  currency TEXT NOT NULL DEFAULT 'USD',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT wallets_user_id_matches_id CHECK (user_id = id)
);

DROP TRIGGER IF EXISTS trg_wallets_updated_at ON public.wallets;
CREATE TRIGGER trg_wallets_updated_at
  BEFORE UPDATE ON public.wallets
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- 2.12 wallet_transactions
CREATE TABLE IF NOT EXISTS public.wallet_transactions (
  id TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  user_id TEXT NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  type TEXT NOT NULL CHECK (type IN ('credit', 'debit')),
  amount NUMERIC(14, 2) NOT NULL CHECK (amount > 0 AND amount <= 100000),
  description TEXT NOT NULL DEFAULT '',
  balance NUMERIC(14, 2) NOT NULL CHECK (balance >= 0),
  currency TEXT NOT NULL DEFAULT 'USD',
  idempotency_key_hash TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_wallet_tx_user_id_created_at ON public.wallet_transactions (user_id, created_at DESC);

DROP TRIGGER IF EXISTS trg_wallet_transactions_updated_at ON public.wallet_transactions;
CREATE TRIGGER trg_wallet_transactions_updated_at
  BEFORE UPDATE ON public.wallet_transactions
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- 2.13 wallet_idempotency
CREATE TABLE IF NOT EXISTS public.wallet_idempotency (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  type TEXT NOT NULL CHECK (type IN ('credit', 'debit')),
  amount NUMERIC(14, 2) NOT NULL CHECK (amount > 0),
  currency TEXT NOT NULL DEFAULT 'USD',
  balance NUMERIC(14, 2) NOT NULL CHECK (balance >= 0),
  transaction JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_wallet_idempotency_user_id ON public.wallet_idempotency (user_id);

-- 2.14 plans
CREATE TABLE IF NOT EXISTS public.plans (
  id TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  title TEXT NOT NULL CHECK (char_length(trim(title)) >= 2),
  price TEXT NOT NULL,
  price_value NUMERIC(12, 2) NOT NULL DEFAULT 0 CHECK (price_value >= 0),
  color TEXT NOT NULL DEFAULT '#3A86FF',
  features JSONB NOT NULL DEFAULT '[]'::jsonb,
  is_popular BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_plans_price_value ON public.plans (price_value ASC);
CREATE INDEX IF NOT EXISTS idx_plans_created_at ON public.plans (created_at DESC);

DROP TRIGGER IF EXISTS trg_plans_updated_at ON public.plans;
CREATE TRIGGER trg_plans_updated_at
  BEFORE UPDATE ON public.plans
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- 2.15 subscriptions
CREATE TABLE IF NOT EXISTS public.subscriptions (
  id TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  user_id TEXT NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  plan_id TEXT NOT NULL REFERENCES public.plans(id) ON DELETE RESTRICT,
  plan_title TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'Pending' CHECK (status IN ('Pending', 'Active', 'Cancelled', 'Expired')),
  start_date TIMESTAMPTZ NOT NULL DEFAULT now(),
  end_date TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_subscriptions_user_id_created_at ON public.subscriptions (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_subscriptions_status ON public.subscriptions (status);
CREATE INDEX IF NOT EXISTS idx_subscriptions_created_at ON public.subscriptions (created_at DESC);

DROP TRIGGER IF EXISTS trg_subscriptions_updated_at ON public.subscriptions;
CREATE TRIGGER trg_subscriptions_updated_at
  BEFORE UPDATE ON public.subscriptions
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- 2.16 notifications
CREATE TABLE IF NOT EXISTS public.notifications (
  id TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  user_id TEXT NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  title TEXT NOT NULL CHECK (char_length(trim(title)) >= 2),
  content TEXT NOT NULL DEFAULT '',
  type TEXT NOT NULL DEFAULT 'general',
  icon TEXT NOT NULL DEFAULT 'notifications',
  read BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_notifications_user_id_created_at ON public.notifications (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_notifications_user_id_read ON public.notifications (user_id, read);

DROP TRIGGER IF EXISTS trg_notifications_updated_at ON public.notifications;
CREATE TRIGGER trg_notifications_updated_at
  BEFORE UPDATE ON public.notifications
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- 2.17 earnings
CREATE TABLE IF NOT EXISTS public.earnings (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL UNIQUE REFERENCES public.users(id) ON DELETE CASCADE,
  balance NUMERIC(14, 2) NOT NULL DEFAULT 0,
  total_earnings NUMERIC(14, 2) NOT NULL DEFAULT 0,
  breakdown JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT earnings_user_id_matches_id CHECK (user_id = id)
);

DROP TRIGGER IF EXISTS trg_earnings_updated_at ON public.earnings;
CREATE TRIGGER trg_earnings_updated_at
  BEFORE UPDATE ON public.earnings
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- 2.18 availability
CREATE TABLE IF NOT EXISTS public.availability (
  id TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  lawyer_id TEXT NOT NULL REFERENCES public.lawyers(id) ON DELETE CASCADE,
  lawyer_name TEXT NOT NULL DEFAULT '',
  date TEXT NOT NULL CHECK (date ~ '^\d{4}-\d{2}-\d{2}$'),
  slots JSONB NOT NULL DEFAULT '[]'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_availability_lawyer_id_date ON public.availability (lawyer_id, date ASC);
CREATE INDEX IF NOT EXISTS idx_availability_created_at ON public.availability (created_at DESC);

DROP TRIGGER IF EXISTS trg_availability_updated_at ON public.availability;
CREATE TRIGGER trg_availability_updated_at
  BEFORE UPDATE ON public.availability
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- 3. Server-Side Authorization Helper Functions (for RLS)
CREATE OR REPLACE FUNCTION public.current_app_user_id()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    (
      SELECT u.id
        FROM public.users u
       WHERE u.auth_user_id = auth.uid()
          OR u.id = auth.uid()::text
       LIMIT 1
    ),
    auth.uid()::text
  );
$$;

CREATE OR REPLACE FUNCTION public.current_app_user_role()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT u.role
    FROM public.users u
   WHERE u.auth_user_id = auth.uid()
      OR u.id = auth.uid()::text
   LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(public.current_app_user_role() = 'admin', false);
$$;

CREATE OR REPLACE FUNCTION public.is_lawyer_or_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(public.current_app_user_role() IN ('lawyer', 'admin'), false);
$$;

-- 4. Enable Row Level Security (RLS) on All Tables
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lawyers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bookings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.booking_slots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chats ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.favorites ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wallets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wallet_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wallet_idempotency ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.earnings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.availability ENABLE ROW LEVEL SECURITY;

-- 5. Explicit Row Level Security (RLS) Policies

-- 5.1 users policies
DROP POLICY IF EXISTS users_select_self_or_admin ON public.users;
CREATE POLICY users_select_self_or_admin ON public.users
  FOR SELECT
  TO authenticated
  USING (
    id = public.current_app_user_id()
    OR auth_user_id = auth.uid()
    OR public.is_admin()
  );

DROP POLICY IF EXISTS users_insert_self_client_or_admin ON public.users;
CREATE POLICY users_insert_self_client_or_admin ON public.users
  FOR INSERT
  TO authenticated
  WITH CHECK (
    public.is_admin()
    OR (
      id = auth.uid()::text
      AND uid = auth.uid()::text
      AND (auth_user_id IS NULL OR auth_user_id = auth.uid())
      AND role = 'client'
    )
  );

DROP POLICY IF EXISTS users_update_self_or_admin ON public.users;
CREATE POLICY users_update_self_or_admin ON public.users
  FOR UPDATE
  TO authenticated
  USING (
    id = public.current_app_user_id()
    OR auth_user_id = auth.uid()
    OR public.is_admin()
  )
  WITH CHECK (
    public.is_admin()
    OR (
      (id = public.current_app_user_id() OR auth_user_id = auth.uid())
      AND role = (SELECT u.role FROM public.users u WHERE u.id = users.id)
      AND lower(email) = (SELECT lower(u.email) FROM public.users u WHERE u.id = users.id)
    )
  );

DROP POLICY IF EXISTS users_delete_admin_only ON public.users;
CREATE POLICY users_delete_admin_only ON public.users
  FOR DELETE
  TO authenticated
  USING (public.is_admin());

-- 5.2 lawyers policies
DROP POLICY IF EXISTS lawyers_select_public ON public.lawyers;
CREATE POLICY lawyers_select_public ON public.lawyers
  FOR SELECT
  TO anon, authenticated
  USING (true);

DROP POLICY IF EXISTS lawyers_insert_admin_only ON public.lawyers;
CREATE POLICY lawyers_insert_admin_only ON public.lawyers
  FOR INSERT
  TO authenticated
  WITH CHECK (public.is_admin());

DROP POLICY IF EXISTS lawyers_update_admin_only ON public.lawyers;
CREATE POLICY lawyers_update_admin_only ON public.lawyers
  FOR UPDATE
  TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

DROP POLICY IF EXISTS lawyers_delete_admin_only ON public.lawyers;
CREATE POLICY lawyers_delete_admin_only ON public.lawyers
  FOR DELETE
  TO authenticated
  USING (public.is_admin());

-- 5.3 cases policies
DROP POLICY IF EXISTS cases_select_owner_or_admin ON public.cases;
CREATE POLICY cases_select_owner_or_admin ON public.cases
  FOR SELECT
  TO authenticated
  USING (
    user_id = public.current_app_user_id()
    OR public.is_admin()
  );

DROP POLICY IF EXISTS cases_insert_owner_or_admin ON public.cases;
CREATE POLICY cases_insert_owner_or_admin ON public.cases
  FOR INSERT
  TO authenticated
  WITH CHECK (
    user_id = public.current_app_user_id()
    OR public.is_admin()
  );

DROP POLICY IF EXISTS cases_update_owner_or_admin ON public.cases;
CREATE POLICY cases_update_owner_or_admin ON public.cases
  FOR UPDATE
  TO authenticated
  USING (
    user_id = public.current_app_user_id()
    OR public.is_admin()
  )
  WITH CHECK (
    user_id = public.current_app_user_id()
    OR public.is_admin()
  );

DROP POLICY IF EXISTS cases_delete_owner_or_admin ON public.cases;
CREATE POLICY cases_delete_owner_or_admin ON public.cases
  FOR DELETE
  TO authenticated
  USING (
    user_id = public.current_app_user_id()
    OR public.is_admin()
  );

-- 5.4 bookings policies
DROP POLICY IF EXISTS bookings_select_owner_or_admin ON public.bookings;
CREATE POLICY bookings_select_owner_or_admin ON public.bookings
  FOR SELECT
  TO authenticated
  USING (
    user_id = public.current_app_user_id()
    OR public.is_admin()
  );

DROP POLICY IF EXISTS bookings_write_admin_only ON public.bookings;
CREATE POLICY bookings_write_admin_only ON public.bookings
  FOR ALL
  TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- 5.5 booking_slots policies
DROP POLICY IF EXISTS booking_slots_select_owner_or_admin ON public.booking_slots;
CREATE POLICY booking_slots_select_owner_or_admin ON public.booking_slots
  FOR SELECT
  TO authenticated
  USING (
    user_id = public.current_app_user_id()
    OR public.is_admin()
  );

DROP POLICY IF EXISTS booking_slots_write_admin_only ON public.booking_slots;
CREATE POLICY booking_slots_write_admin_only ON public.booking_slots
  FOR ALL
  TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- 5.6 tasks policies
DROP POLICY IF EXISTS tasks_select_owner_or_admin ON public.tasks;
CREATE POLICY tasks_select_owner_or_admin ON public.tasks
  FOR SELECT
  TO authenticated
  USING (
    user_id = public.current_app_user_id()
    OR public.is_admin()
  );

DROP POLICY IF EXISTS tasks_insert_owner_or_admin ON public.tasks;
CREATE POLICY tasks_insert_owner_or_admin ON public.tasks
  FOR INSERT
  TO authenticated
  WITH CHECK (
    user_id = public.current_app_user_id()
    OR public.is_admin()
  );

DROP POLICY IF EXISTS tasks_update_owner_or_admin ON public.tasks;
CREATE POLICY tasks_update_owner_or_admin ON public.tasks
  FOR UPDATE
  TO authenticated
  USING (
    user_id = public.current_app_user_id()
    OR public.is_admin()
  )
  WITH CHECK (
    user_id = public.current_app_user_id()
    OR public.is_admin()
  );

DROP POLICY IF EXISTS tasks_delete_owner_or_admin ON public.tasks;
CREATE POLICY tasks_delete_owner_or_admin ON public.tasks
  FOR DELETE
  TO authenticated
  USING (
    user_id = public.current_app_user_id()
    OR public.is_admin()
  );

-- 5.7 chats policies
DROP POLICY IF EXISTS chats_select_participant_or_admin ON public.chats;
CREATE POLICY chats_select_participant_or_admin ON public.chats
  FOR SELECT
  TO authenticated
  USING (
    public.current_app_user_id() = ANY(participants)
    OR public.is_admin()
  );

DROP POLICY IF EXISTS chats_insert_participant_or_admin ON public.chats;
CREATE POLICY chats_insert_participant_or_admin ON public.chats
  FOR INSERT
  TO authenticated
  WITH CHECK (
    public.current_app_user_id() = ANY(participants)
    OR public.is_admin()
  );

DROP POLICY IF EXISTS chats_update_participant_or_admin ON public.chats;
CREATE POLICY chats_update_participant_or_admin ON public.chats
  FOR UPDATE
  TO authenticated
  USING (
    public.current_app_user_id() = ANY(participants)
    OR public.is_admin()
  )
  WITH CHECK (
    public.current_app_user_id() = ANY(participants)
    OR public.is_admin()
  );

DROP POLICY IF EXISTS chats_delete_admin_only ON public.chats;
CREATE POLICY chats_delete_admin_only ON public.chats
  FOR DELETE
  TO authenticated
  USING (public.is_admin());

-- 5.8 chat_messages policies
DROP POLICY IF EXISTS chat_messages_select_participant_or_admin ON public.chat_messages;
CREATE POLICY chat_messages_select_participant_or_admin ON public.chat_messages
  FOR SELECT
  TO authenticated
  USING (
    public.is_admin()
    OR EXISTS (
      SELECT 1
        FROM public.chats c
       WHERE c.id = chat_messages.chat_id
         AND public.current_app_user_id() = ANY(c.participants)
    )
  );

DROP POLICY IF EXISTS chat_messages_insert_participant_or_admin ON public.chat_messages;
CREATE POLICY chat_messages_insert_participant_or_admin ON public.chat_messages
  FOR INSERT
  TO authenticated
  WITH CHECK (
    public.is_admin()
    OR (
      sender_id = public.current_app_user_id()
      AND EXISTS (
        SELECT 1
          FROM public.chats c
         WHERE c.id = chat_messages.chat_id
           AND public.current_app_user_id() = ANY(c.participants)
      )
    )
  );

DROP POLICY IF EXISTS chat_messages_delete_admin_only ON public.chat_messages;
CREATE POLICY chat_messages_delete_admin_only ON public.chat_messages
  FOR DELETE
  TO authenticated
  USING (public.is_admin());

-- 5.9 reviews policies
DROP POLICY IF EXISTS reviews_select_public ON public.reviews;
CREATE POLICY reviews_select_public ON public.reviews
  FOR SELECT
  TO anon, authenticated
  USING (true);

DROP POLICY IF EXISTS reviews_insert_owner_or_admin ON public.reviews;
CREATE POLICY reviews_insert_owner_or_admin ON public.reviews
  FOR INSERT
  TO authenticated
  WITH CHECK (
    user_id = public.current_app_user_id()
    OR public.is_admin()
  );

DROP POLICY IF EXISTS reviews_update_owner_or_admin ON public.reviews;
CREATE POLICY reviews_update_owner_or_admin ON public.reviews
  FOR UPDATE
  TO authenticated
  USING (
    user_id = public.current_app_user_id()
    OR public.is_admin()
  )
  WITH CHECK (
    user_id = public.current_app_user_id()
    OR public.is_admin()
  );

DROP POLICY IF EXISTS reviews_delete_owner_or_admin ON public.reviews;
CREATE POLICY reviews_delete_owner_or_admin ON public.reviews
  FOR DELETE
  TO authenticated
  USING (
    user_id = public.current_app_user_id()
    OR public.is_admin()
  );

-- 5.10 favorites policies
DROP POLICY IF EXISTS favorites_select_owner_or_admin ON public.favorites;
CREATE POLICY favorites_select_owner_or_admin ON public.favorites
  FOR SELECT
  TO authenticated
  USING (
    user_id = public.current_app_user_id()
    OR public.is_admin()
  );

DROP POLICY IF EXISTS favorites_insert_owner_or_admin ON public.favorites;
CREATE POLICY favorites_insert_owner_or_admin ON public.favorites
  FOR INSERT
  TO authenticated
  WITH CHECK (
    user_id = public.current_app_user_id()
    OR public.is_admin()
  );

DROP POLICY IF EXISTS favorites_delete_owner_or_admin ON public.favorites;
CREATE POLICY favorites_delete_owner_or_admin ON public.favorites
  FOR DELETE
  TO authenticated
  USING (
    user_id = public.current_app_user_id()
    OR public.is_admin()
  );

-- 5.11 wallets policies
DROP POLICY IF EXISTS wallets_select_owner_or_admin ON public.wallets;
CREATE POLICY wallets_select_owner_or_admin ON public.wallets
  FOR SELECT
  TO authenticated
  USING (
    user_id = public.current_app_user_id()
    OR public.is_admin()
  );

DROP POLICY IF EXISTS wallets_write_admin_only ON public.wallets;
CREATE POLICY wallets_write_admin_only ON public.wallets
  FOR ALL
  TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- 5.12 wallet_transactions policies
DROP POLICY IF EXISTS wallet_tx_select_owner_or_admin ON public.wallet_transactions;
CREATE POLICY wallet_tx_select_owner_or_admin ON public.wallet_transactions
  FOR SELECT
  TO authenticated
  USING (
    user_id = public.current_app_user_id()
    OR public.is_admin()
  );

DROP POLICY IF EXISTS wallet_tx_write_admin_only ON public.wallet_transactions;
CREATE POLICY wallet_tx_write_admin_only ON public.wallet_transactions
  FOR ALL
  TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- 5.13 wallet_idempotency policies
DROP POLICY IF EXISTS wallet_idempotency_select_owner_or_admin ON public.wallet_idempotency;
CREATE POLICY wallet_idempotency_select_owner_or_admin ON public.wallet_idempotency
  FOR SELECT
  TO authenticated
  USING (
    user_id = public.current_app_user_id()
    OR public.is_admin()
  );

DROP POLICY IF EXISTS wallet_idempotency_write_admin_only ON public.wallet_idempotency;
CREATE POLICY wallet_idempotency_write_admin_only ON public.wallet_idempotency
  FOR ALL
  TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- 5.14 plans policies
DROP POLICY IF EXISTS plans_select_public ON public.plans;
CREATE POLICY plans_select_public ON public.plans
  FOR SELECT
  TO anon, authenticated
  USING (true);

DROP POLICY IF EXISTS plans_write_admin_only ON public.plans;
CREATE POLICY plans_write_admin_only ON public.plans
  FOR ALL
  TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- 5.15 subscriptions policies
DROP POLICY IF EXISTS subscriptions_select_owner_or_admin ON public.subscriptions;
CREATE POLICY subscriptions_select_owner_or_admin ON public.subscriptions
  FOR SELECT
  TO authenticated
  USING (
    user_id = public.current_app_user_id()
    OR public.is_admin()
  );

DROP POLICY IF EXISTS subscriptions_insert_owner_pending_or_admin ON public.subscriptions;
CREATE POLICY subscriptions_insert_owner_pending_or_admin ON public.subscriptions
  FOR INSERT
  TO authenticated
  WITH CHECK (
    public.is_admin()
    OR (
      user_id = public.current_app_user_id()
      AND status = 'Pending'
    )
  );

DROP POLICY IF EXISTS subscriptions_update_owner_cancel_or_admin ON public.subscriptions;
CREATE POLICY subscriptions_update_owner_cancel_or_admin ON public.subscriptions
  FOR UPDATE
  TO authenticated
  USING (
    user_id = public.current_app_user_id()
    OR public.is_admin()
  )
  WITH CHECK (
    public.is_admin()
    OR (
      user_id = public.current_app_user_id()
      AND status = 'Cancelled'
    )
  );

DROP POLICY IF EXISTS subscriptions_delete_admin_only ON public.subscriptions;
CREATE POLICY subscriptions_delete_admin_only ON public.subscriptions
  FOR DELETE
  TO authenticated
  USING (public.is_admin());

-- 5.16 notifications policies
DROP POLICY IF EXISTS notifications_select_owner_or_admin ON public.notifications;
CREATE POLICY notifications_select_owner_or_admin ON public.notifications
  FOR SELECT
  TO authenticated
  USING (
    user_id = public.current_app_user_id()
    OR public.is_admin()
  );

DROP POLICY IF EXISTS notifications_insert_admin_only ON public.notifications;
CREATE POLICY notifications_insert_admin_only ON public.notifications
  FOR INSERT
  TO authenticated
  WITH CHECK (public.is_admin());

DROP POLICY IF EXISTS notifications_update_owner_or_admin ON public.notifications;
CREATE POLICY notifications_update_owner_or_admin ON public.notifications
  FOR UPDATE
  TO authenticated
  USING (
    user_id = public.current_app_user_id()
    OR public.is_admin()
  )
  WITH CHECK (
    user_id = public.current_app_user_id()
    OR public.is_admin()
  );

DROP POLICY IF EXISTS notifications_delete_owner_or_admin ON public.notifications;
CREATE POLICY notifications_delete_owner_or_admin ON public.notifications
  FOR DELETE
  TO authenticated
  USING (
    user_id = public.current_app_user_id()
    OR public.is_admin()
  );

-- 5.17 earnings policies
DROP POLICY IF EXISTS earnings_select_lawyer_owner_or_admin ON public.earnings;
CREATE POLICY earnings_select_lawyer_owner_or_admin ON public.earnings
  FOR SELECT
  TO authenticated
  USING (
    public.is_admin()
    OR (
      user_id = public.current_app_user_id()
      AND public.is_lawyer_or_admin()
    )
  );

DROP POLICY IF EXISTS earnings_write_admin_only ON public.earnings;
CREATE POLICY earnings_write_admin_only ON public.earnings
  FOR ALL
  TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- 5.18 availability policies
DROP POLICY IF EXISTS availability_select_public ON public.availability;
CREATE POLICY availability_select_public ON public.availability
  FOR SELECT
  TO anon, authenticated
  USING (true);

DROP POLICY IF EXISTS availability_write_lawyer_or_admin ON public.availability;
CREATE POLICY availability_write_lawyer_or_admin ON public.availability
  FOR ALL
  TO authenticated
  USING (public.is_lawyer_or_admin())
  WITH CHECK (public.is_lawyer_or_admin());
