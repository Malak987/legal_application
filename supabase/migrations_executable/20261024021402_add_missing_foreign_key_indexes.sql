-- Cover foreign-key lookups flagged by Supabase Performance Advisor.
-- Additive and safe for existing data; no RLS or application behavior changes.
CREATE INDEX IF NOT EXISTS idx_booking_slots_user_id ON public.booking_slots (user_id);
CREATE INDEX IF NOT EXISTS idx_lawyers_user_id ON public.lawyers (user_id);
CREATE INDEX IF NOT EXISTS idx_subscriptions_plan_id ON public.subscriptions (plan_id);