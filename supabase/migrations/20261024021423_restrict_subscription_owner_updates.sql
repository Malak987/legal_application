-- Subscription owners may cancel their own subscription, but cannot rewrite
-- plan, price snapshot, ownership, or dates. Admins retain full update access.
CREATE OR REPLACE FUNCTION public.guard_subscription_owner_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    IF NEW.user_id IS DISTINCT FROM OLD.user_id
       OR NEW.plan_id IS DISTINCT FROM OLD.plan_id
       OR NEW.plan_title IS DISTINCT FROM OLD.plan_title
       OR NEW.start_date IS DISTINCT FROM OLD.start_date
       OR NEW.end_date IS DISTINCT FROM OLD.end_date
       OR NEW.created_at IS DISTINCT FROM OLD.created_at
       OR (
         NEW.status IS DISTINCT FROM OLD.status
         AND NEW.status <> 'Cancelled'
       )
       OR NEW.status <> 'Cancelled'
    THEN
      RAISE EXCEPTION 'Users may only cancel their own subscription'
        USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.guard_subscription_owner_update() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS guard_subscription_owner_update_trigger ON public.subscriptions;
CREATE TRIGGER guard_subscription_owner_update_trigger
BEFORE UPDATE ON public.subscriptions
FOR EACH ROW
EXECUTE FUNCTION public.guard_subscription_owner_update();