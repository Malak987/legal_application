// GENERATED FILE — do not edit.
// Produced by supabase/functions/delete-my-account/bundle.py from
//   account_deletion.ts + index.ts
// Deploy this file as the `delete-my-account` Edge Function.

/**
 * Self-service account deletion — testable handler factory.
 *
 * Security contract:
 *  - Bearer token verified server-side.
 *  - Target derived strictly from verified JWT subject.
 *  - Service-role client created inside handler from Edge Function secrets.
 *  - Profile presence required (fails closed with 404 if missing).
 *  - Storage listing and removal performed recursively with pagination support.
 *  - Session revocation performed using the verified access JWT.
 *  - Any Storage or revocation failure fails closed (aborts Auth deletion).
 *  - Database cascades remove linked relational records.
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
const TARGET_KEYS = ['user_id', 'userId', 'profileId', 'profile_id', 'auth_user_id', 'target'];

function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: CORS_HEADERS });
}

function failure(code, message, status) {
  return jsonResponse({ code, message }, status);
}

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

export function suppliedTarget(body) {
  for (const key of TARGET_KEYS) {
    const value = body?.[key];
    if (typeof value === 'string' && value.trim() !== '') return value.trim();
  }
  return null;
}

async function findOwnProfile(serviceClient, authUserId) {
  const linked = await serviceClient
    .from('users')
    .select('id,role,name,email,phone,avatar,address,auth_user_id')
    .eq('auth_user_id', authUserId)
    .maybeSingle();
  if (linked.error) throw linked.error;
  if (linked.data) return linked.data;

  const native = await serviceClient
    .from('users')
    .select('id,role,name,email,phone,avatar,address,auth_user_id')
    .eq('id', authUserId)
    .maybeSingle();
  if (native.error) throw native.error;
  return native.data ?? null;
}

/**
 * Explicit recursive traversal and pagination for Supabase Storage objects.
 * Lists folders and files recursively, handles pagination (limit/offset),
 * and collects only files under the exact root prefix (profileId).
 */
async function listAllStorageObjects(storageClient, bucket, prefix) {
  const allFiles = [];
  const foldersToVisit = [prefix];

  while (foldersToVisit.length > 0) {
    const currentFolder = foldersToVisit.pop();
    let offset = 0;
    const limit = 1000;
    let hasMore = true;

    while (hasMore) {
      const { data, error } = await storageClient.storage
        .from(bucket)
        .list(currentFolder, {
          limit,
          offset,
          sortBy: { column: 'name', order: 'asc' },
        });

      if (error) {
        if (error.message && error.message.includes('not found')) {
          hasMore = false;
          break;
        }
        throw error;
      }

      if (!data || data.length === 0) {
        hasMore = false;
        break;
      }

      for (const item of data) {
        const itemPath = currentFolder ? `${currentFolder}/${item.name}` : item.name;
        const isFolder = item.id === null || !item.metadata || item.metadata === null;

        if (isFolder) {
          foldersToVisit.push(itemPath);
        } else {
          // Ensure file belongs strictly under the target profile prefix
          if (itemPath.startsWith(`${prefix}/`)) {
            allFiles.push(itemPath);
          }
        }
      }

      if (data.length < limit) {
        hasMore = false;
      } else {
        offset += limit;
      }
    }
  }

  return allFiles;
}

async function cleanupUserStorage(serviceClient, profileId) {
  const files = await listAllStorageObjects(serviceClient, 'legal-documents', profileId);
  if (files.length === 0) return;

  // Remove files in safe batches of 100
  const batchSize = 100;
  for (let i = 0; i < files.length; i += batchSize) {
    const batch = files.slice(i, i + batchSize);
    const { error: removeError } = await serviceClient.storage
      .from('legal-documents')
      .remove(batch);
    if (removeError) throw removeError;
  }
}

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
      return failure(
        'TARGET_NOT_ALLOWED',
        'You can only delete your own account.',
        403,
      );
    }

    // ---- 3. Authorise against the caller's own profile (Fail closed if missing) ----
    let serviceClient;
    let profile;
    try {
      serviceClient = deps.createServiceClient();
      profile = await findOwnProfile(serviceClient, callerAuthId);
      if (!profile) {
        return failure(
          'PROFILE_NOT_FOUND',
          'Account profile not found. Deletion aborted.',
          404,
        );
      }
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
    } catch (err) {
      if (err instanceof Response) return err;
      return failure(
        'ACCOUNT_LOOKUP_FAILED',
        'Could not safely verify the account and its linked records. No change was made.',
        503,
      );
    }

    // ---- 4. Storage Cleanup (Must succeed before Auth deletion) ----------
    try {
      await cleanupUserStorage(serviceClient, profile.id);
    } catch {
      return failure(
        'STORAGE_CLEANUP_FAILED',
        'Could not remove associated storage files. Account deletion aborted.',
        502,
      );
    }

    // ---- 5. Session Revocation using Access JWT (Must succeed before Auth deletion) ----
    try {
      const { error: signOutError } = await serviceClient.auth.admin.signOut(accessToken);
      if (signOutError) {
        return failure(
          'SESSION_REVOCATION_FAILED',
          'Could not revoke active user sessions. Account deletion aborted.',
          502,
        );
      }
    } catch {
      return failure(
        'SESSION_REVOCATION_FAILED',
        'Could not revoke active user sessions. Account deletion aborted.',
        502,
      );
    }

    // ---- 6. Delete Auth Account -----------------------------------------
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
          alreadyDeleted = true;
        } else {
          return failure(
            'ACCOUNT_DELETE_FAILED',
            'Your sign-in account could not be deleted.',
            502,
          );
        }
      }
    } catch {
      return failure(
        'ACCOUNT_DELETE_FAILED',
        'Your sign-in account could not be deleted.',
        502,
      );
    }

    return jsonResponse(
      {
        deleted: true,
        alreadyDeleted,
        profileDeleted: Boolean(profile),
        historyDeleted: true,
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
