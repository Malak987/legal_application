DO $$
DECLARE affected integer;
BEGIN
  UPDATE public.users
  SET role = 'owner'
  WHERE lower(email) = lower('malak@example.com')
    AND role = 'admin';
  GET DIAGNOSTICS affected = ROW_COUNT;
  IF affected <> 1 THEN
    RAISE EXCEPTION 'Expected exactly one matching admin account; updated % rows. No role change should be assumed.', affected;
  END IF;
END $$;