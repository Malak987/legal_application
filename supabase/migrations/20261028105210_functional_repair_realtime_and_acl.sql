-- 8. ACL + Realtime (RLS remains the row filter; nothing is made public)
REVOKE ALL ON FUNCTION public.rpc_chat_start_with_lawyer(text, text, text, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_chat_send_message(text, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_lawyer_my_profile() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_lawyer_set_availability(text, text, text[]) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_lawyer_my_bookings(integer, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_lawyer_set_booking_status(text, text) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.rpc_chat_start_with_lawyer(text, text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_chat_send_message(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_lawyer_my_profile() TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_lawyer_set_availability(text, text, text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_lawyer_my_bookings(integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_lawyer_set_booking_status(text, text) TO authenticated;

GRANT SELECT ON TABLE public.chats, public.chat_messages TO authenticated;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_rel pr
    JOIN pg_publication p ON p.oid = pr.prpubid
    WHERE p.pubname = 'supabase_realtime' AND pr.prrelid = 'public.chat_messages'::regclass
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.chat_messages;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_rel pr
    JOIN pg_publication p ON p.oid = pr.prpubid
    WHERE p.pubname = 'supabase_realtime' AND pr.prrelid = 'public.chats'::regclass
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.chats;
  END IF;
END $$;