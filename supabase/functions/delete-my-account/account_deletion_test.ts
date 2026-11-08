// @ts-nocheck
/**
 * deno test — behaviour tests for the self-service deletion handler.
 *
 * These run against in-memory fakes of the Supabase clients: no project, no
 * network, no service-role key.
 */
import {
  assert,
  assertEquals,
} from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { createSelfDeleteAccountHandler } from './account_deletion.ts';

const CALLER_AUTH_ID = '11111111-1111-4111-8111-111111111111';
const OTHER_AUTH_ID = '22222222-2222-4222-8222-222222222222';

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
    then(onFulfilled, onRejected) {
      return Promise.resolve(exec()).then(onFulfilled, onRejected);
    },
  };
  return builder;
}

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

function harness({
  users = [],
  lawyers = [],
  storageFiles = {},
  deleteUserImpl,
  signOutError = null,
  listError = null,
  removeError = null,
  profileQueryError = false,
  getUserImpl,
} = {}) {
  const calls = [];
  const world = {
    users: users.map((row) => ({ ...row })),
    lawyers: lawyers.map((row) => ({ ...row })),
    deletedAuthIds: [],
    signOutTokens: [],
    removedStoragePaths: [],
    calls,
  };

  const serviceClient = {
    from(table) {
      if (profileQueryError) {
        return {
          select: () => ({
            eq: () => ({
              maybeSingle: () => Promise.resolve({ data: null, error: { message: 'db error' } }),
            }),
          }),
        };
      }
      const builder = fakeQuery(table === 'users' ? world.users : world.lawyers, calls);
      builder.table = table;
      return builder;
    },
    storage: {
      from(bucket) {
        assertEquals(bucket, 'legal-documents');
        return {
          async list(folder, options) {
            if (listError) return { data: null, error: listError };
            const limit = options?.limit ?? 1000;
            const offset = options?.offset ?? 0;
            const prefix = folder ? `${folder}/` : '';
            const allMatching = [];
            const seenNames = new Set();

            for (const filePath of Object.keys(storageFiles)) {
              if (folder === '' || filePath.startsWith(prefix) || filePath === folder) {
                const sub = folder === '' ? filePath : filePath.substring(prefix.length);
                const slash = sub.indexOf('/');
                if (slash === -1) {
                  if (!seenNames.has(sub) && sub !== '') {
                    seenNames.add(sub);
                    allMatching.push({ id: 'file-id', name: sub, metadata: { mimetype: 'application/pdf' } });
                  }
                } else {
                  const folderName = sub.substring(0, slash);
                  if (!seenNames.has(folderName) && folderName !== '') {
                    seenNames.add(folderName);
                    allMatching.push({ id: null, name: folderName, metadata: null });
                  }
                }
              }
            }

            allMatching.sort((a, b) => a.name.localeCompare(b.name));
            const paged = allMatching.slice(offset, offset + limit);
            return { data: paged, error: null };
          },
          async remove(paths) {
            if (removeError) return { data: null, error: removeError };
            for (const p of paths) {
              assert(!p.endsWith('/'), 'Folder entries must never be passed to remove()');
              world.removedStoragePaths.push(p);
            }
            // Also mutate storageFiles in harness so retry works if files are cleared
            for (const p of paths) {
              delete storageFiles[p];
            }
            return { data: paths, error: null };
          },
        };
      },
    },
    auth: {
      admin: {
        async signOut(jwt) {
          world.signOutTokens.push(jwt);
          if (signOutError) return { error: signOutError };
          return { error: null };
        },
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

Deno.test('missing profile fails closed with 404 and does not delete Auth account', async () => {
  const { handler, world } = harness({ users: [] });
  const response = await handler(post({}));
  assertEquals(response.status, 404);
  assertEquals((await response.json()).code, 'PROFILE_NOT_FOUND');
  assertEquals(world.deletedAuthIds.length, 0);
  assertEquals(world.signOutTokens.length, 0);
});

Deno.test('profile lookup error aborts deletion and does not delete Auth account', async () => {
  const { handler, world } = harness({ users: [profileRow()], profileQueryError: true });
  const response = await handler(post({}));
  assertEquals(response.status, 503);
  assertEquals((await response.json()).code, 'ACCOUNT_LOOKUP_FAILED');
  assertEquals(world.deletedAuthIds.length, 0);
});

Deno.test('storage listing failure aborts deletion and does not delete Auth account', async () => {
  const { handler, world } = harness({
    users: [profileRow()],
    listError: { message: 'Storage unavailable' },
  });
  const response = await handler(post({}));
  assertEquals(response.status, 502);
  assertEquals((await response.json()).code, 'STORAGE_CLEANUP_FAILED');
  assertEquals(world.deletedAuthIds.length, 0);
  assertEquals(world.signOutTokens.length, 0);
});

Deno.test('storage removal failure aborts deletion and does not delete Auth account', async () => {
  const { handler, world } = harness({
    users: [profileRow()],
    storageFiles: { [`${CALLER_AUTH_ID}/doc.pdf`]: true },
    removeError: { message: 'Removal failed' },
  });
  const response = await handler(post({}));
  assertEquals(response.status, 502);
  assertEquals((await response.json()).code, 'STORAGE_CLEANUP_FAILED');
  assertEquals(world.deletedAuthIds.length, 0);
  assertEquals(world.signOutTokens.length, 0);
});

Deno.test('session revocation failure aborts deletion and does not delete Auth account', async () => {
  const { handler, world } = harness({
    users: [profileRow()],
    signOutError: { message: 'Revocation failed' },
  });
  const response = await handler(post({}));
  assertEquals(response.status, 502);
  assertEquals((await response.json()).code, 'SESSION_REVOCATION_FAILED');
  assertEquals(world.deletedAuthIds.length, 0);
  assertEquals(world.signOutTokens, ['valid-token']);
});

Deno.test('auth deletion failure after successful storage cleanup and session revocation reports 502 and preserves profile for retry', async () => {
  const storageFiles = { [`${CALLER_AUTH_ID}/file.pdf`]: true };
  const { handler, world } = harness({
    users: [profileRow()],
    storageFiles,
    deleteUserImpl: () => ({ error: { message: 'Auth service timeout' } }),
  });

  const response = await handler(post({}));
  assertEquals(response.status, 502);
  assertEquals((await response.json()).code, 'ACCOUNT_DELETE_FAILED');

  // Verify operations completed before auth failure
  assertEquals(world.removedStoragePaths, [`${CALLER_AUTH_ID}/file.pdf`]);
  assertEquals(world.signOutTokens, ['valid-token']);
  assertEquals(world.deletedAuthIds, [CALLER_AUTH_ID]);

  // Profile is preserved (no anonymization was performed)
  assertEquals(world.users[0].name, 'Samir Client');
  assertEquals(world.users[0].auth_user_id, CALLER_AUTH_ID);
});

Deno.test('retry behavior: first attempt fails at auth deletion; second attempt finds clean storage and succeeds', async () => {
  let storageFiles = { [`${CALLER_AUTH_ID}/file.pdf`]: true };
  let attempt = 0;
  const { handler, world } = harness({
    users: [profileRow()],
    storageFiles,
    deleteUserImpl: (id, w) => {
      attempt++;
      if (attempt === 1) {
        return { error: { message: 'temporary auth outage' } };
      }
      applyAuthFkSetNull(w, id);
      return { error: null };
    },
  });

  // First attempt: storage and revocation succeed, auth deletion fails
  const res1 = await handler(post({}));
  assertEquals(res1.status, 502);
  assertEquals((await res1.json()).code, 'ACCOUNT_DELETE_FAILED');
  assertEquals(world.removedStoragePaths, [`${CALLER_AUTH_ID}/file.pdf`]);
  assertEquals(world.signOutTokens.length, 1);

  // Second attempt: clean storage (no-op), revocation succeeds, auth deletion succeeds
  const res2 = await handler(post({}));
  assertEquals(res2.status, 200);
  assertEquals((await res2.json()).deleted, true);
  assertEquals(world.deletedAuthIds.length, 2);
  assertEquals(world.signOutTokens.length, 2);
  assertEquals(world.users[0].auth_user_id, null);
});

Deno.test('successful deletion executes storage cleanup and session revocation with JWT before auth deletion', async () => {
  const { handler, world } = harness({
    users: [profileRow()],
    storageFiles: { [`${CALLER_AUTH_ID}/documents/file.pdf`]: true },
  });
  const response = await handler(post({}));
  assertEquals(response.status, 200);
  assertEquals(world.removedStoragePaths, [`${CALLER_AUTH_ID}/documents/file.pdf`]);
  assertEquals(world.signOutTokens, ['valid-token']);
  assertEquals(world.deletedAuthIds, [CALLER_AUTH_ID]);
});

Deno.test('nested folders traversal, prefix isolation, and pagination (>1000 items) are handled correctly', async () => {
  const files = {};
  for (let i = 0; i < 1050; i++) {
    files[`${CALLER_AUTH_ID}/sub/dir${Math.floor(i / 100)}/item_${i}.pdf`] = true;
  }
  files[`${OTHER_AUTH_ID}/other_file.pdf`] = true;

  const { handler, world } = harness({
    users: [profileRow()],
    storageFiles: files,
  });

  const response = await handler(post({}));
  assertEquals(response.status, 200);

  assertEquals(world.removedStoragePaths.length, 1050);

  const foreignRemoved = world.removedStoragePaths.filter((p) => p.startsWith(OTHER_AUTH_ID));
  assertEquals(foreignRemoved.length, 0);

  for (const p of world.removedStoragePaths) {
    assert(p.endsWith('.pdf'), 'Only file paths ending with .pdf should be removed');
  }
});

Deno.test('another users target is rejected without deleting anything', async () => {
  const { handler, world } = harness({ users: [profileRow()] });
  const response = await handler(post({ user_id: OTHER_AUTH_ID }));
  assertEquals(response.status, 403);
  assertEquals((await response.json()).code, 'TARGET_NOT_ALLOWED');
  assertEquals(world.deletedAuthIds.length, 0);
});

Deno.test('owner and admin protection remains intact', async () => {
  const { handler, world } = harness({ users: [profileRow({ role: 'owner' })] });
  const response = await handler(post({}));
  assertEquals(response.status, 403);
  assertEquals((await response.json()).code, 'OWNER_ACCOUNT_PROTECTED');
  assertEquals(world.deletedAuthIds.length, 0);
});
