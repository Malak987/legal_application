// @ts-nocheck
/**
 * delete-my-account — Supabase Edge Function (self-service account deletion).
 *
 * Deployed with JWT verification enabled (verify_jwt = true) *and* the token
 * re-verified here, so an unauthenticated caller is rejected twice over.
 *
 * The service-role key is read from the function's own secrets. It never
 * leaves this runtime and is never included in any response or log line.
 */
import { createClient } from 'npm:@supabase/supabase-js@2';
import { createSelfDeleteAccountHandler } from './account_deletion.ts';

const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
const anonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

const handler = createSelfDeleteAccountHandler({
  createUserClient(accessToken: string) {
    if (!supabaseUrl || !anonKey) {
      throw new Error('Supabase function environment is not configured.');
    }
    return createClient(supabaseUrl, anonKey, {
      auth: {
        autoRefreshToken: false,
        persistSession: false,
        detectSessionInUrl: false,
      },
      global: {
        headers: { Authorization: `Bearer ${accessToken}` },
      },
    });
  },
  createServiceClient() {
    if (!supabaseUrl || !serviceRoleKey) {
      throw new Error('The trusted account service is not configured.');
    }
    return createClient(supabaseUrl, serviceRoleKey, {
      auth: {
        autoRefreshToken: false,
        persistSession: false,
        detectSessionInUrl: false,
      },
    });
  },
});

Deno.serve(handler);
