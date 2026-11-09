
DROP POLICY IF EXISTS bookings_select_assigned_lawyer ON public.bookings;
DROP POLICY IF EXISTS bookings_select_owner_or_admin ON public.bookings;
CREATE POLICY bookings_select_authorized_parties
ON public.bookings
FOR SELECT
TO authenticated
USING (
  private.is_current_user_lawyer_for(lawyer_id)
  OR private.is_admin()
  OR (
    private.current_app_user_role() = 'client'
    AND user_id = private.current_app_user_id()
  )
);

DROP POLICY IF EXISTS cases_select_assigned_lawyer ON public.cases;
DROP POLICY IF EXISTS cases_select_owner_or_admin ON public.cases;
CREATE POLICY cases_select_authorized_parties
ON public.cases
FOR SELECT
TO authenticated
USING (
  private.is_current_user_lawyer_for(lawyer_id)
  OR private.is_admin()
  OR (
    private.current_app_user_role() = 'client'
    AND user_id = private.current_app_user_id()
  )
);
