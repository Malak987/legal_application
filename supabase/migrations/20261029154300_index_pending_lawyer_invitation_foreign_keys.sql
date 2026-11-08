
CREATE INDEX IF NOT EXISTS idx_pending_lawyer_invitations_category_id
  ON private.pending_lawyer_invitations (category_id);

CREATE INDEX IF NOT EXISTS idx_pending_lawyer_invitations_invited_by_auth_user_id
  ON private.pending_lawyer_invitations (invited_by_auth_user_id);
