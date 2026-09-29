import { strict as assert } from 'node:assert';
import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import { describe, it } from 'node:test';
import { createGroupRegistry } from './group_registry.ts';
import { createGroupApiHandler } from './http_api.ts';
import type { RealtimeConfig } from './types.ts';

const token = 'test-token-0123456789';

const testConfig = (sharedToken: string | null): RealtimeConfig => ({
  port: 0,
  sharedToken,
  allowUnauthenticatedDevelopment: false,
  heartbeatIntervalMs: 30_000,
  joinTimeoutMs: 10_000,
  recentMessageLimit: 50,
  maxConnectionsPerRoom: 50,
});

const createBody = {
  name: '数学建模小组',
  hostUserId: 'user-a',
  hostDisplayName: '张三',
};

/**
 * Boots the handler on an ephemeral port so the tests exercise real HTTP.
 *
 * Returns whatever `run` returns, and builds a fresh registry per call — two
 * calls against the same room therefore look exactly like a server restart.
 */
async function withServer<T>(
  run: (baseUrl: string) => Promise<T>,
  sharedToken: string | null = token,
): Promise<T> {
  const handler = createGroupApiHandler(createGroupRegistry(), testConfig(sharedToken));
  const server = createServer((request, response) => {
    void handler(request, response).then((handled) => {
      if (handled) return;
      response.writeHead(404, { 'cache-control': 'no-store' });
      response.end();
    });
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address() as AddressInfo;
  try {
    return await run(`http://127.0.0.1:${port}`);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
}

// `body` has no default on purpose: a default would silently fire on an
// explicit `undefined` and turn a "send nothing" test into a valid request.
const postGroup = (baseUrl: string, headers: Record<string, string>, body: unknown) =>
  fetch(`${baseUrl}/v1/groups`, { method: 'POST', headers, body: JSON.stringify(body) });

function authorized(): Record<string, string> {
  return { authorization: `Bearer ${token}`, 'content-type': 'application/json' };
}

describe('group api authentication', () => {
  it('rejects a request with no token', async () => {
    await withServer(async (baseUrl) => {
      const response = await fetch(`${baseUrl}/v1/groups/K7M2XP`);
      assert.equal(response.status, 401);
      assert.deepEqual(await response.json(), { error: 'UNAUTHORIZED' });
    });
  });

  it('rejects a request with the wrong token', async () => {
    await withServer(async (baseUrl) => {
      const response = await fetch(`${baseUrl}/v1/groups/K7M2XP?token=wrong`);
      assert.equal(response.status, 401);
    });
  });

  it('accepts the token as a bearer header', async () => {
    await withServer(async (baseUrl) => {
      assert.equal((await postGroup(baseUrl, authorized(), createBody)).status, 201);
    });
  });

  it('accepts the token as a query parameter', async () => {
    await withServer(async (baseUrl) => {
      const response = await fetch(`${baseUrl}/v1/groups?token=${token}`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(createBody),
      });
      assert.equal(response.status, 201);
    });
  });
});

describe('group api routing', () => {
  it('leaves unrelated paths to the caller', async () => {
    await withServer(async (baseUrl) => {
      // The stub server answers 404 for anything the handler declines.
      assert.equal((await fetch(`${baseUrl}/healthz`, { headers: authorized() })).status, 404);
      assert.equal((await fetch(`${baseUrl}/v1/other`, { headers: authorized() })).status, 404);
    });
  });

  it('rejects the wrong method with an Allow header', async () => {
    await withServer(async (baseUrl) => {
      const response = await fetch(`${baseUrl}/v1/groups`, { headers: authorized() });
      assert.equal(response.status, 405);
      assert.equal(response.headers.get('allow'), 'POST');
    });
  });

  it('answers a malformed percent-escape with 400 rather than crashing', async () => {
    await withServer(async (baseUrl) => {
      assert.equal((await fetch(`${baseUrl}/v1/groups/%`, { headers: authorized() })).status, 400);
    });
  });
});

describe('group api creation', () => {
  it('registers a group and returns an invite code', async () => {
    await withServer(async (baseUrl) => {
      const response = await postGroup(baseUrl, authorized(), createBody);
      assert.equal(response.status, 201);
      const body = (await response.json()) as Record<string, unknown>;

      assert.equal(body.name, '数学建模小组');
      assert.equal(body.hostUserId, 'user-a');
      assert.equal(body.hostDisplayName, '张三');
      assert.equal(typeof body.inviteCode, 'string');
      assert.equal((body.inviteCode as string).length, 6);
      assert.ok((body.roomId as string).startsWith('grp-'));
      assert.equal(typeof body.createdAt, 'number');
    });
  });

  it('rejects a request that is missing a field', async () => {
    await withServer(async (baseUrl) => {
      const response = await postGroup(baseUrl, authorized(), { name: '只有名字' });
      assert.equal(response.status, 400);
    });
  });

  it('rejects a blank field rather than trimming it into a group', async () => {
    await withServer(async (baseUrl) => {
      const response = await postGroup(baseUrl, authorized(), { ...createBody, hostUserId: '   ' });
      assert.equal(response.status, 400);
    });
  });

  it('rejects a field longer than the protocol allows', async () => {
    await withServer(async (baseUrl) => {
      const response = await postGroup(baseUrl, authorized(), { ...createBody, name: 'x'.repeat(65) });
      assert.equal(response.status, 400);
    });
  });

  it('rejects a body that is not JSON', async () => {
    await withServer(async (baseUrl) => {
      // Sent raw rather than through postGroup: JSON.stringify would reject it first.
      const response = await fetch(`${baseUrl}/v1/groups`, {
        method: 'POST',
        headers: authorized(),
        body: '这是一个群',
      });
      assert.equal(response.status, 400);
      assert.deepEqual(await response.json(), { error: 'MALFORMED_JSON' });
    });
  });

  it('rejects an empty body', async () => {
    await withServer(async (baseUrl) => {
      const response = await fetch(`${baseUrl}/v1/groups`, {
        method: 'POST',
        headers: authorized(),
      });
      assert.equal(response.status, 400);
    });
  });

  it('rejects an oversized body', async () => {
    await withServer(async (baseUrl) => {
      const response = await postGroup(baseUrl, authorized(), { ...createBody, name: 'x'.repeat(9000) });
      assert.equal(response.status, 413);
      assert.deepEqual(await response.json(), { error: 'PAYLOAD_TOO_LARGE' });
    });
  });
});

describe('group api re-registration', () => {
  /** Each withServer call builds its own registry, so two of them is a restart. */
  const register = async (baseUrl: string, body: Record<string, unknown>) =>
    (await (await postGroup(baseUrl, authorized(), body)).json()) as Record<string, string>;

  it('takes the room id it is given and reports 201', async () => {
    await withServer(async (baseUrl) => {
      const response = await postGroup(baseUrl, authorized(), { ...createBody, roomId: 'grp-fixed' });
      assert.equal(response.status, 201);
      const body = (await response.json()) as Record<string, string>;
      assert.equal(body.roomId, 'grp-fixed');
    });
  });

  it('answers 200 with the same code when the room is already registered', async () => {
    await withServer(async (baseUrl) => {
      const first = await register(baseUrl, { ...createBody, roomId: 'grp-fixed' });

      const response = await postGroup(baseUrl, authorized(), { ...createBody, roomId: 'grp-fixed' });

      assert.equal(response.status, 200);
      const second = (await response.json()) as Record<string, string>;
      assert.equal(second.roomId, 'grp-fixed');
      assert.equal(second.inviteCode, first.inviteCode);
    });
  });

  it('issues a new code for the same room once the registry is gone', async () => {
    const stale = await withServer((baseUrl) =>
      register(baseUrl, { ...createBody, roomId: 'grp-fixed' }),
    );

    await withServer(async (baseUrl) => {
      const response = await postGroup(baseUrl, authorized(), { ...createBody, roomId: 'grp-fixed' });
      assert.equal(response.status, 201);
      const repaired = (await response.json()) as Record<string, string>;

      // The guests' room survives; the code the host read aloud does not.
      assert.equal(repaired.roomId, stale.roomId);
      assert.notEqual(repaired.inviteCode, stale.inviteCode);
    });
  });

  it('rejects a roomId that is present but unusable', async () => {
    await withServer(async (baseUrl) => {
      // A null must not be read as "no room id" — that would silently create a
      // second room instead of repairing the one the host asked for.
      for (const roomId of [null, '', '   ', 'x'.repeat(129), 42]) {
        const response = await postGroup(baseUrl, authorized(), { ...createBody, roomId });
        assert.equal(response.status, 400, `roomId ${JSON.stringify(roomId)} was accepted`);
      }
    });
  });
});

describe('group api lookup', () => {
  it('resolves an invite code to the group that was registered', async () => {
    await withServer(async (baseUrl) => {
      const created = (await (await postGroup(baseUrl, authorized(), createBody)).json()) as Record<string, string>;

      const response = await fetch(`${baseUrl}/v1/groups/${created.inviteCode}`, {
        headers: authorized(),
      });
      assert.equal(response.status, 200);
      const found = (await response.json()) as Record<string, string>;
      assert.equal(found.roomId, created.roomId);
      assert.equal(found.hostDisplayName, '张三');
    });
  });

  it('accepts a lower-case code, which is how it gets typed', async () => {
    await withServer(async (baseUrl) => {
      const created = (await (await postGroup(baseUrl, authorized(), createBody)).json()) as Record<string, string>;

      const response = await fetch(`${baseUrl}/v1/groups/${created.inviteCode.toLowerCase()}`, {
        headers: authorized(),
      });
      assert.equal(response.status, 200);
    });
  });

  it('answers 404 for a code that was never issued', async () => {
    await withServer(async (baseUrl) => {
      const response = await fetch(`${baseUrl}/v1/groups/ZZZZZZ`, { headers: authorized() });
      assert.equal(response.status, 404);
      assert.deepEqual(await response.json(), { error: 'GROUP_NOT_FOUND' });
    });
  });
});
