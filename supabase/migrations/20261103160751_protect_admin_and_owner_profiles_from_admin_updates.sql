DROP POLICY IF EXISTS users_update_self_or_admin ON public.users;
CREATE POLICY users_update_self_or_authorized_admin_or_owner
ON public.users
FOR UPDATE
TO authenticated
USING (
  id = private.current_app_user_id()
  OR private.current_app_user_role() = 'owner'
  OR (
    private.current_app_user_role() = 'admin'
    AND role NOT IN ('admin','owner')
  )
)
WITH CHECK (
  id = private.current_app_user_id()
  OR private.current_app_user_role() = 'owner'
  OR (
    private.current_app_user_role() = 'admin'
    AND role NOT IN ('admin','owner')
  )
);