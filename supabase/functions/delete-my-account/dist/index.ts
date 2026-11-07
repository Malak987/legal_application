// GENERATED FILE — do not edit.
// Produced by supabase/functions/delete-my-account/bundle.py from
//   account_deletion.ts + index.ts
// Deploy this file as the `delete-my-account` Edge Function.

/**
 * Self-service account deletion — testable handler factory.
 *
 * Security contract (see docs/ACCOUNT_DELETION.md):
 *  - The bearer token is verified server-side; an unauthenticated call is
 *    rejected before any account is looked up.
 *  - The deletion target is ALWAYS the verified JWT subject. A different
 *    identity supplied in the request body is rejected, never honoured.
 *  - The service-role client is created inside the handler from Edge Function
 *    secrets and is never returned, logged or echoed.
 *  - Legal history owned by other participants is preserved. Only the caller's
 *    own account is removed and their own profile is anonymised.
 */

const CORS_HEADERS = {
  'Content-Type': 'application/json; charset=utf-8',
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Cache-Control': 'no-store',
};

const MAX_BODY_BYTES = 2048;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
/** Body keys that would look like a deletion target. None are ever trusted. */
const TARGET_KEYS = ['user_id', 'userId', 'profileId', 'profile_id', 'auth_user_id', 'target'];
/** Profile fields scrubbed on self-deletion. `id`/`uid`/`role` stay intact. */
const ANONYMISED_NAME = 'Deleted account';

function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: CORS_HEADERS });
}

function failure(code, message, status) {
  return jsonResponse({ code, message }, status);
}

/** Reads and parses the body. Never throws; returns { error } on bad input. */
async function readBody(request) {
  let raw = '';
  try {
    raw = await request.text();
  } catch {
    return { error: failure('INVALID_REQUEST', 'The request body could not be read.', 400) };
  }
  if (new TextEncoder().encode(raw).byteLength > MAX_BODY_BYTES) {
    return { error: failure('REQUEST_TOO_LARGE', 'The request is too large.', 413) };
  }
  if (raw.trim() === '') return { body: {}, raw: '' };
  let body;
  try {
    body = JSON.parse(raw);
  } catch {
    return { error: failure('INVALID_JSON', 'Request body must be valid JSON.', 400) };
  }
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    return { error: failure('INVALID_REQUEST', 'Request body must be an object.', 400) };
  }
  return { body, raw };
}

/** Returns the first identity-looking value supplied by the caller, if any. */
export function suppliedTarget(body) {
  for (const key of TARGET_KEYS) {
    const value = body?.[key];
    if (typeof value === 'string' && value.trim() !== '') return value.trim();
  }
  return null;
}

/** Resolves the caller's own application profile from their verified auth id. */
async function findOwnProfile(serviceClient, authUserId) {
  const linked = await serviceClient
    .from('users')
    .select('id,role,name,email,phone,avatar,address,auth_user_id')
    .eq('auth_user_id', authUserId)
    .maybeSingle();
  if (linked.error) throw linked.error;
  if (linked.data) return linked.data;

  // Same exact-UUID fallback the rest of the backend and the app use.
  // Identities are never resolved by email or user-editable metadata.
  const native = await serviceClient
    .from('users')
    .select('id,role,name,email,phone,avatar,address,auth_user_id')
    .eq('id', authUserId)
    .maybeSingle();
  if (native.error) throw native.error;
  return native.data ?? null;
}

/** True when the profile is attached to a public lawyer directory entry. */
async function hasLawyerProfile(serviceClient, profileId) {
  const result = await serviceClient
    .from('lawyers')
    .select('id')
    .eq('user_id', profileId)
    .limit(1)
    .maybeSingle();
  if (result.error) throw result.error;
  return Boolean(result.data);
}

/**
 * Scrubs the caller's own personal fields while keeping the row (and therefore
 * the legal history keyed to it) intact. Returns the previous values so a
 * failed auth deletion can be rolled back.
 */
async function anonymiseOwnProfile(serviceClient, profile) {
  const stamped = String(profile.id ?? '')
    .replace(/[^A-Za-z0-9]/g, '')
    .slice(0, 40) || 'unknown';
  const previous = {
    name: profile.name,
    email: profile.email,
    phone: profile.phone,
    avatar: profile.avatar,
    address: profile.address,
  };
  const scrubbed = {
    name: ANONYMISED_NAME,
    email: `deleted+${stamped}@deleted.invalid`,
    phone: '',
    avatar: '',
    address: '',
  };
  const update = await serviceClient
    .from('users')
    .update(scrubbed)
    .eq('id', profile.id);
  if (update.error) throw update.error;
  return previous;
}

/** Best-effort restore used when the auth deletion fails after anonymisation. */
async function restoreProfile(serviceClient, profileId, previous) {
  try {
    await serviceClient.from('users').update(previous).eq('id', profileId);
    return true;
  } catch {
    return false;
  }
}

/**
 * Builds the handler. All Supabase clients are injected so the module can be
 * exercised without a live project.
 */
export function createSelfDeleteAccountHandler(deps) {
  return async function handleSelfDeleteAccount(request) {
    if (request.method === 'OPTIONS') return jsonResponse({}, 200);
    if (request.method !== 'POST') {
      return failure('METHOD_NOT_ALLOWED', 'Use POST.', 405);
    }

    // ---- 1. Authenticate the caller -------------------------------------
    const authorization = request.headers.get('Authorization') ?? '';
    const tokenMatch = authorization.match(/^Bearer\s+(.+)$/i);
    const accessToken = tokenMatch?.[1]?.trim();
    if (!accessToken) {
      return failure('AUTHENTICATION_REQUIRED', 'Sign in to delete your account.', 401);
    }

    let authUser;
    try {
      const userClient = deps.createUserClient(accessToken);
      const { data, error } = await userClient.auth.getUser(accessToken);
      if (error || !data?.user?.id) {
        return failure('INVALID_SESSION', 'Your session is invalid or expired.', 401);
      }
      authUser = data.user;
    } catch {
      return failure('AUTHENTICATION_UNAVAILABLE', 'Could not verify your session.', 503);
    }

    if (!UUID_PATTERN.test(String(authUser.id ?? ''))) {
      return failure('INVALID_SESSION', 'Your session is invalid or expired.', 401);
    }
    const callerAuthId = String(authUser.id);

    // ---- 2. Refuse any attempt to name a different target ----------------
    const parsed = await readBody(request);
    if (parsed.error) return parsed.error;
    const requestedTarget = suppliedTarget(parsed.body);
    if (requestedTarget !== null && requestedTarget.toLowerCase() !== callerAuthId.toLowerCase()) {
      // Defence in depth: the client never needs to send a target. Refusing
      // here makes the misuse visible without touching any account.
      return failure(
        'TARGET_NOT_ALLOWED',
        'You can only delete your own account.',
        403,
      );
    }

    // ---- 3. Authorise against the caller's own profile -------------------
    let serviceClient;
    let profile;
    try {
      serviceClient = deps.createServiceClient();
      profile = await findOwnProfile(serviceClient, callerAuthId);
      if (profile) {
        const role = String(profile.role ?? '').toLowerCase();
        if (role === 'owner') {
          return failure('OWNER_ACCOUNT_PROTECTED', 'The owner account cannot be deleted.', 403);
        }
        if (role === 'admin') {
          return failure(
            'ADMIN_ACCOUNT_PROTECTED',
            'Administrator accounts must be removed by another administrator.',
            403,
          );
        }
        if (role === 'lawyer' && (await hasLawyerProfile(serviceClient, profile.id))) {
          return failure(
            'LAWYER_PROFILE_REQUIRES_DEACTIVATION',
            'Deactivate or reassign your public lawyer profile before deleting this account.',
            409,
          );
        }
      }
    } catch {
      return failure(
        'ACCOUNT_LOOKUP_FAILED',
        'Could not safely verify the account and its linked records. No change was made.',
        503,
      );
    }

    // ---- 4. Scrub personal fields, then delete the sign-in account -------
    let restored = false;
    let previous = null;
    if (profile) {
      try {
        previous = await anonymiseOwnProfile(serviceClient, profile);
      } catch {
        return failure(
          'PROFILE_ANONYMISATION_FAILED',
          'Your profile could not be prepared for deletion. No change was made.',
          503,
        );
      }
    }

    let alreadyDeleted = false;
    try {
      const { error } = await serviceClient.auth.admin.deleteUser(callerAuthId);
      if (error) {
        const message = String(error.message ?? '').toLowerCase();
        const status = Number(error.status ?? 0);
        if (
          status === 404 ||
          message.includes('not found') ||
          message.includes('user_not_found')
        ) {
          // The auth account is already gone: treat as a safe repeat request.
          alreadyDeleted = true;
        } else {
          if (profile) restored = await restoreProfile(serviceClient, profile.id, previous);
          return failure(
            'ACCOUNT_DELETE_FAILED',
            'Your sign-in account could not be deleted. Your profile was not removed.',
            502,
          );
        }
      }
    } catch {
      if (profile) restored = await restoreProfile(serviceClient, profile.id, previous);
      return failure(
        'ACCOUNT_DELETE_FAILED',
        'Your sign-in account could not be deleted. Your profile was not removed.',
        502,
      );
    }

    // ---- 5. Confirm the Auth identity really detached from the profile ---
    let detached = true;
    if (profile) {
      try {
        const after = await serviceClient
          .from('users')
          .select('id,auth_user_id')
          .eq('id', profile.id)
          .maybeSingle();
        if (after.error) throw after.error;
        detached = after.data ? after.data.auth_user_id === null : true;
      } catch {
        detached = false;
      }
    }

    if (!detached) {
      // The account is gone but the link survived: report it instead of
      // pretending everything is consistent.
      return failure(
        'PROFILE_DETACH_UNVERIFIED',
        'Your sign-in account was deleted, but the profile link could not be confirmed as detached. Contact support.',
        502,
      );
    }

    return jsonResponse(
      {
        deleted: true,
        alreadyDeleted,
        profileRetained: Boolean(profile),
        profileAnonymised: Boolean(profile) && !restored,
        historyRetained: true,
      },
      200,
    );
  };
}

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
