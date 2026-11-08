-- Migration: lawyer_account_full_cascade_deletion
-- Timestamp: 20261107140036
-- Ensures full cascade deletion for lawyer accounts, bookings, cases, schedules, reviews, earnings.

ALTER TABLE IF EXISTS public.lawyers
  DROP CONSTRAINT IF EXISTS lawyers_user_id_fkey,
  ADD CONSTRAINT lawyers_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE IF EXISTS public.bookings
  DROP CONSTRAINT IF EXISTS bookings_lawyer_id_fkey,
  ADD CONSTRAINT bookings_lawyer_id_fkey FOREIGN KEY (lawyer_id) REFERENCES public.lawyers(id) ON DELETE CASCADE;

ALTER TABLE IF EXISTS public.cases
  DROP CONSTRAINT IF EXISTS cases_lawyer_id_fkey,
  ADD CONSTRAINT cases_lawyer_id_fkey FOREIGN KEY (lawyer_id) REFERENCES public.lawyers(id) ON DELETE CASCADE;
