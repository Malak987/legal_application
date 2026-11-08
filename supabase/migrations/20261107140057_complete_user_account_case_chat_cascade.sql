-- Migration: complete_user_account_case_chat_cascade
-- Timestamp: 20261107140057
-- Ensures user profile cascade, case user_id cascade, and chat message/conversation purging.

ALTER TABLE IF EXISTS public.users
  DROP CONSTRAINT IF EXISTS users_auth_user_id_fkey,
  ADD CONSTRAINT users_auth_user_id_fkey FOREIGN KEY (auth_user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

ALTER TABLE IF EXISTS public.cases
  DROP CONSTRAINT IF EXISTS cases_user_id_fkey,
  ADD CONSTRAINT cases_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

CREATE OR REPLACE FUNCTION private.purge_lawyer_chats_before_delete()
RETURNS TRIGGER AS $$
BEGIN
  DELETE FROM public.chats WHERE lawyer_id = OLD.id;
  RETURN OLD;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION private.purge_user_chats_before_delete()
RETURNS TRIGGER AS $$
BEGIN
  DELETE FROM public.chats WHERE user_id = OLD.id;
  RETURN OLD;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
