// @ts-nocheck
/**
 * deno test — behaviour tests for the self-service deletion handler.
 *
 * These run against in-memory fakes of the Supabase clients: no project, no
 * network, no service-role key. They assert real control flow (which requests
 * reached `auth.admin.deleteUser`, with which id) rather than string presence.
 *
 * Run with:  deno test supabase/functions/delete-my-account/
 */
import {
  assert,
  assertEquals,
} from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { createSelfDeleteAccountHandler } from './account_deletion.ts';

const CALLER_AUTH_ID = '11111111-1111-4111-8111-111111111111';
const OTHER_AUTH_ID = '22222222-2222-4222-8222-222222222222';

/**
 * Minimal chainable stand-in for a PostgREST query builder.
 *
 * Like supabase-js, the builder is thenable: the request is executed when the
 * chain is awaited, not only when `.maybeSingle()` is called.
 */
function fakeQuery(rows, calls) {
  const state = { filters: {}, limit: null, op: 'select', payload: null, table: null };

  function exec() {
    const matches = rows.filter((row) =>
      Object.entries(state.filters).every(([key, value]) => row[key] === value),
    );
    calls.push({
      op: state.op,
      table: state.table,
      filters: { ...state.filters },
      payload: state.payload,
    });
    if (state.op === 'update') {
      for (const row of matches) Object.assign(row, state.payload);
      return { data: matches[0] ?? null, error: null };
    }
    const limited = state.limit === null ? matches : matches.slice(0, state.limit);
    return { data: limited[0] ?? null, error: null };
  }

  const builder = {
    select() {
      return builder;
    },
    eq(column, value) {
      state.filters[column] = value;
      return builder;
    },
    limit(n) {
      state.limit = n;
      return builder;
    },
    update(payload) {
      state.op = 'update';
      state.payload = payload;
      return builder;
    },
    maybeSingle() {
      return Promise.resolve(exec());
    },
    // Awaiting the bare chain (e.g. `await from().update(...).eq(...)`).
    then(onFulfilled, onRejected) {
      return Promise.resolve(exec()).then(onFulfilled, onRejected);
    },
  };
  return builder;
}

/**
 * Models the production `users.auth_user_id` FK, which is ON DELETE SET NULL:
 * deleting the auth user detaches the profile instead of removing it.
 */
function applyAuthFkSetNull(world, authId) {
  for (const row of world.users) {
    if (row.auth_user_id === authId) row.auth_user_id = null;
  }
}

function profileRow(overrides = {}) {
  return {
    id: CALLER_AUTH_ID,
    role: 'client',
    name: 'Samir Client',
    email: 'samir@example.com',
    phone: '+201000000000',
    avatar: 'avatar.png',
    address: 'Cairo',
    auth_user_id: CALLER_AUTH_ID,
    ...overrides,
  };
}

/**
 * Builds the fake world used by every test.
 * `users`/`lawyers` are the live table contents and are mutated by the handler.
 */
function harness({
  users = [],
  lawyers = [],
  authUsers = {},
  deleteUserImpl,
  getUserImpl,
} = {}) {
  const calls = [];
  const world = {
    users: users.map((row) => ({ ...row })),
    lawyers: lawyers.map((row) => ({ ...row })),
    deletedAuthIds: [],
    calls,
  };

  const serviceClient = {
    from(table) {
      const builder = fakeQuery(table === 'users' ? world.users : world.lawyers, calls);
      builder.table = table;
      return builder;
    },
    auth: {
      admin: {
        async deleteUser(id) {
          world.deletedAuthIds.push(id);
          const impl =
            deleteUserImpl ??
            ((authId, w) => {
              applyAuthFkSetNull(w, authId);
              return { error: null };
            });
          return impl(id, world);
        },
        async getUserById(id) {
          const user = authUsers[id];
          return user
            ? { data: { user }, error: null }
            : { data: { user: null }, error: null };
        },
      },
    },
  };

  const handler = createSelfDeleteAccountHandler({
    createUserClient() {
      return {
        auth: {
          async getUser(token) {
            if (getUserImpl) return getUserImpl(token);
            if (token === 'valid-token') {
              return {
                data: { user: { id: CALLER_AUTH_ID, email: 'a@example.com' } },
                error: null,
              };
            }
            return { data: { user: null }, error: { message: 'invalid JWT' } };
          },
        },
      };
    },
    createServiceClient() {
      return serviceClient;
    },
  });

  return { handler, world };
}

function post(body, { token = 'valid-token', headers = {} } = {}) {
  const finalHeaders = new Headers({ 'Content-Type': 'application/json', ...headers });
  if (token !== null) finalHeaders.set('Authorization', `Bearer ${token}`);
  return new Request('https://project.supabase.co/functions/v1/delete-my-account', {
    method: 'POST',
    headers: finalHeaders,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

// --------------------------------------------------------------------------
// Authentication
// --------------------------------------------------------------------------

Deno.test('rejects a request with no Authorization header', async () => {
  const { handler, world } = harness({ users: [profileRow()] });
  const response = await handler(post({}, { token: null }));
  assertEquals(response.status, 401);
  const body = await response.json();
  assertEquals(body.code, 'AUTHENTICATION_REQUIRED');
  assertEquals(world.deletedAuthIds.length, 0);
});

Deno.test('rejects an unusable token without touching any account', async () => {
  const { handler, world } = harness({ users: [profileRow()] });
  const response = await handler(post({}, { token: 'bogus' }));
  assertEquals(response.status, 401);
  assertEquals((await response.json()).code, 'INVALID_SESSION');
  assertEquals(world.deletedAuthIds.length, 0);
});

Deno.test('rejects a token whose subject is not a UUID', async () => {
  const { handler, world } = harness({
    users: [profileRow()],
    getUserImpl: () => ({ data: { user: { id: 'not-a-uuid' } }, error: null }),
  });
  const response = await handler(post({}));
  assertEquals(response.status, 401);
  assertEquals(world.deletedAuthIds.length, 0);
});

Deno.test('answers CORS preflight without side effects', async () => {
  const { handler, world } = harness({ users: [profileRow()] });
  const response = await handler(
    new Request('https://project.supabase.co/functions/v1/delete-my-account', {
      method: 'OPTIONS',
    }),
  );
  assertEquals(response.status, 200);
  assertEquals(world.deletedAuthIds.length, 0);
});

Deno.test('rejects a non-POST method', async () => {
  const { handler, world } = harness({ users: [profileRow()] });
  const response = await handler(
    new Request('https://project.supabase.co/functions/v1/delete-my-account', {
      method: 'GET',
      headers: { Authorization: 'Bearer valid-token' },
    }),
  );
  assertEquals(response.status, 405);
  assertEquals(world.deletedAuthIds.length, 0);
});

// --------------------------------------------------------------------------
// Target binding — the core authorisation guarantee
// --------------------------------------------------------------------------

Deno.test('refuses when the body names another user, and deletes nobody', async () => {
  const { handler, world } = harness({
    users: [profileRow(), profileRow({ id: OTHER_AUTH_ID, email: 'other@example.com', auth_user_id: OTHER_AUTH_ID })],
  });
  const response = await handler(post({ user_id: OTHER_AUTH_ID }, { token: 'valid-token' }));
  assertEquals(response.status, 403);
  assertEquals((await response.json()).code, 'TARGET_NOT_ALLOWED');
  assertEquals(world.deletedAuthIds.length, 0);
  // The other account is untouched.
  assertEquals(world.users[1].name, 'Samir Client');
});

Deno.test('refuses every alias of a supplied target', async () => {
  for (const key of ['user_id', 'userId', 'profileId', 'profile_id', 'auth_user_id', 'target']) {
    const { handler, world } = harness({
      users: [profileRow(), profileRow({ id: OTHER_AUTH_ID, auth_user_id: OTHER_AUTH_ID })],
    });
    const response = await handler(post({ [key]: OTHER_AUTH_ID }));
    assertEquals(response.status, 403, `alias ${key} must be refused`);
    assertEquals(world.deletedAuthIds.length, 0, `alias ${key} deleted an account`);
  }
});

Deno.test('an echoed own id is accepted but the JWT subject still decides', async () => {
  const { handler, world } = harness({
    users: [profileRow(), profileRow({ id: OTHER_AUTH_ID, auth_user_id: OTHER_AUTH_ID })],
  });
  const response = await handler(post({ user_id: CALLER_AUTH_ID }));
  assertEquals(response.status, 200);
  assertEquals(world.deletedAuthIds, [CALLER_AUTH_ID]);
});

// --------------------------------------------------------------------------
// Protected roles
// --------------------------------------------------------------------------

Deno.test('the owner account can never be deleted from the app', async () => {
  const { handler, world } = harness({ users: [profileRow({ role: 'owner' })] });
  const response = await handler(post({}));
  assertEquals(response.status, 403);
  assertEquals((await response.json()).code, 'OWNER_ACCOUNT_PROTECTED');
  assertEquals(world.deletedAuthIds.length, 0);
  assertEquals(world.users[0].name, 'Samir Client');
});

Deno.test('an administrator cannot self-delete through this endpoint', async () => {
  const { handler, world } = harness({ users: [profileRow({ role: 'admin' })] });
  const response = await handler(post({}));
  assertEquals(response.status, 403);
  assertEquals((await response.json()).code, 'ADMIN_ACCOUNT_PROTECTED');
  assertEquals(world.deletedAuthIds.length, 0);
});

Deno.test('a lawyer with a public directory profile must deactivate first', async () => {
  const { handler, world } = harness({
    users: [profileRow({ role: 'lawyer' })],
    lawyers: [{ id: 'lawyer-1', user_id: CALLER_AUTH_ID }],
  });
  const response = await handler(post({}));
  assertEquals(response.status, 409);
  assertEquals((await response.json()).code, 'LAWYER_PROFILE_REQUIRES_DEACTIVATION');
  assertEquals(world.deletedAuthIds.length, 0);
  assertEquals(world.users[0].name, 'Samir Client');
});

// --------------------------------------------------------------------------
// Success path and retention behaviour
// --------------------------------------------------------------------------

Deno.test('a client deletes their own account and their profile is anonymised', async () => {
  const { handler, world } = harness({ users: [profileRow()] });
  const response = await handler(post({}));
  assertEquals(response.status, 200);
  const body = await response.json();
  assertEquals(body.deleted, true);
  assertEquals(body.profileRetained, true);
  assertEquals(body.profileAnonymised, true);
  assertEquals(body.historyRetained, true);

  assertEquals(world.deletedAuthIds, [CALLER_AUTH_ID]);
  // Personal fields are gone; the row (and its history keys) survive.
  const row = world.users[0];
  assertEquals(row.name, 'Deleted account');
  assertEquals(row.phone, '');
  assertEquals(row.address, '');
  assertEquals(row.avatar, '');
  assert(!row.email.includes('samir'), 'the old address must not survive');
  assertEquals(row.id, CALLER_AUTH_ID);
  assertEquals(row.role, 'client');
});

Deno.test('a repeated request after the auth user is gone is reported, not retried blindly', async () => {
  const { handler, world } = harness({
    users: [profileRow()],
    // The first deletion already ran, so the FK has already detached the profile.
    deleteUserImpl: (id, w) => {
      applyAuthFkSetNull(w, id);
      return { error: { status: 404, message: 'User not found' } };
    },
  });
  const response = await handler(post({}));
  assertEquals(response.status, 200);
  assertEquals((await response.json()).alreadyDeleted, true);
  assertEquals(world.deletedAuthIds.length, 1);
});

Deno.test('a user with no application profile still loses their sign-in account', async () => {
  const { handler, world } = harness({ users: [] });
  const response = await handler(post({}));
  assertEquals(response.status, 200);
  const body = await response.json();
  assertEquals(body.deleted, true);
  assertEquals(body.profileRetained, false);
  assertEquals(world.deletedAuthIds, [CALLER_AUTH_ID]);
});

// --------------------------------------------------------------------------
// Failure handling — must never report success
// --------------------------------------------------------------------------

Deno.test('an auth deletion failure restores the profile and reports failure', async () => {
  const { handler, world } = harness({
    users: [profileRow()],
    deleteUserImpl: () => ({ error: { status: 500, message: 'database unavailable' } }),
  });
  const response = await handler(post({}));
  assertEquals(response.status, 502);
  assertEquals((await response.json()).code, 'ACCOUNT_DELETE_FAILED');
  // Rolled back: the user still sees their own data.
  assertEquals(world.users[0].name, 'Samir Client');
  assertEquals(world.users[0].email, 'samir@example.com');
  assertEquals(world.users[0].auth_user_id, CALLER_AUTH_ID);
});

Deno.test('a thrown auth deletion failure is contained and rolled back', async () => {
  const { handler, world } = harness({
    users: [profileRow()],
    deleteUserImpl: () => {
      throw new Error('network reset');
    },
  });
  const response = await handler(post({}));
  assertEquals(response.status, 502);
  assertEquals(world.users[0].name, 'Samir Client');
});

Deno.test('an invalid JSON body is refused before any account is touched', async () => {
  const { handler, world } = harness({ users: [profileRow()] });
  const request = new Request('https://project.supabase.co/functions/v1/delete-my-account', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: 'Bearer valid-token' },
    body: '{not json',
  });
  const response = await handler(request);
  assertEquals(response.status, 400);
  assertEquals((await response.json()).code, 'INVALID_JSON');
  assertEquals(world.deletedAuthIds.length, 0);
});

Deno.test('a reported profile detach is verified, and an unverified detach is an error', async () => {
  const { handler, world } = harness({
    users: [profileRow()],
    // Deleting the auth user succeeds but the FK link is left in place.
    deleteUserImpl: () => ({ error: null }),
  });
  // Simulate a database where the FK did not fire.
  const realUsers = world.users;
  const response = await handler(post({}));
  // auth_user_id is still set (the fake never nulls it), so the handler must
  // refuse to claim a clean deletion.
  assertEquals(realUsers[0].auth_user_id, CALLER_AUTH_ID);
  assertEquals(response.status, 502);
  assertEquals((await response.json()).code, 'PROFILE_DETACH_UNVERIFIED');
});

Deno.test('a handler-level detach check passes once the FK nulls the link', async () => {
  const { handler, world } = harness({
    users: [profileRow()],
    // Model ON DELETE SET NULL exactly as the production FK does.
    deleteUserImpl: (_id, w) => {
      for (const row of w.users) {
        if (row.auth_user_id === CALLER_AUTH_ID) row.auth_user_id = null;
      }
      return { error: null };
    },
  });
  const response = await handler(post({}));
  assertEquals(response.status, 200);
  assertEquals(world.users[0].auth_user_id, null);
});

Deno.test('the response never contains a token, key or the previous personal data', async () => {
  const { handler } = harness({ users: [profileRow()] });
  const response = await handler(post({}));
  const text = await response.text();
  for (const secret of ['valid-token', 'samir@example.com', '+201000000000', 'service_role']) {
    assert(!text.includes(secret), `response leaked ${secret}`);
  }
});
