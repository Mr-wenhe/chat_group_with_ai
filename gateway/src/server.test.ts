import assert from 'node:assert/strict';
import { request } from 'node:http';
import test from 'node:test';

import {
  createGatewayServer,
  SlidingWindowRateLimiter,
  UpstreamCircuitBreaker,
} from './server.ts';
import { GatewayError } from './types.ts';
import type { GatewayConfig } from './types.ts';

const config: GatewayConfig = {
  port: 0,
  provider: 'brave',
  providerApiKey: 'server-only-key',
  apiTokens: new Set(['client-token']),
  allowedOrigins: new Set(['https://app.example.com']),
  allowUnauthenticatedDevelopment: false,
  requestTimeoutMs: 1000,
  rateLimitPerMinute: 60,
  quotaPerDay: 1000,
};

test('Gateway rejects missing authentication and invalid input without echoing it', async () => {
  const server = createGatewayServer(config);
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  assert.ok(address != null && typeof address !== 'string');
  try {
    const unauthorized = await post(address.port, undefined, { query: 'secret query' });
    assert.equal(unauthorized.statusCode, 401);
    assert.equal(unauthorized.body.error.code, 'UNAUTHORIZED');
    assert.equal(JSON.stringify(unauthorized.body).includes('secret query'), false);

    const invalid = await post(address.port, 'Bearer client-token', { query: '' });
    assert.equal(invalid.statusCode, 400);
    assert.equal(invalid.body.error.code, 'INVALID_REQUEST');
  } finally {
    await new Promise<void>((resolve, reject) => server.close((error) => error == null ? resolve() : reject(error)));
  }
});

test('Gateway rate limits a normalized authenticated principal', async () => {
  const server = createGatewayServer({...config, rateLimitPerMinute: 1});
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  assert.ok(address != null && typeof address !== 'string');
  try {
    const first = await post(address.port, 'Bearer client-token', { query: '' });
    const changedWhitespace = await post(
      address.port,
      'Bearer   client-token',
      { query: '' },
    );

    assert.equal(first.statusCode, 400);
    assert.equal(changedWhitespace.statusCode, 429);
  } finally {
    await new Promise<void>((resolve, reject) => server.close((error) => error == null ? resolve() : reject(error)));
  }
});

test('Gateway enforces a per-principal daily quota after a valid request', async () => {
  const server = createGatewayServer(
    {...config, quotaPerDay: 1},
    {search: async () => successfulUpstream()},
  );
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  assert.ok(address != null && typeof address !== 'string');
  try {
    const first = await post(address.port, 'Bearer client-token', { query: 'Flutter' });
    const second = await post(address.port, 'Bearer client-token', { query: 'Dart' });

    assert.equal(first.statusCode, 200);
    assert.equal(second.statusCode, 402);
    assert.equal(second.body.error.code, 'QUOTA_EXCEEDED');
  } finally {
    await new Promise<void>((resolve, reject) => server.close((error) => error == null ? resolve() : reject(error)));
  }
});

test('Gateway opens a circuit after three retryable upstream failures', async () => {
  var calls = 0;
  const server = createGatewayServer(
    config,
    {
      search: async () => {
        calls++;
        throw new GatewayError('UPSTREAM_UNAVAILABLE', 502, true);
      },
    },
  );
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  assert.ok(address != null && typeof address !== 'string');
  try {
    for (var index = 0; index < 3; index++) {
      assert.equal(
        (await post(address.port, 'Bearer client-token', { query: 'Flutter' })).statusCode,
        502,
      );
    }
    const blocked = await post(address.port, 'Bearer client-token', { query: 'Flutter' });

    assert.equal(calls, 3);
    assert.equal(blocked.statusCode, 503);
    assert.equal(blocked.body.error.code, 'UPSTREAM_UNAVAILABLE');
  } finally {
    await new Promise<void>((resolve, reject) => server.close((error) => error == null ? resolve() : reject(error)));
  }
});

test('half-open circuit probe is released after a non-retryable failure', () => {
  var now = 0;
  const breaker = new UpstreamCircuitBreaker(() => now, 100);
  for (var index = 0; index < 3; index++) {
    breaker.recordFailure('brave', true);
  }

  assert.equal(breaker.canAttempt('brave'), false);
  now = 101;
  assert.equal(breaker.canAttempt('brave'), true);
  breaker.recordFailure('brave', false);
  assert.equal(breaker.canAttempt('brave'), true);
});

test('rate limiter prunes expired principals and bounds cardinality', () => {
  var now = 0;
  const clock = () => now;
  const limiter = new SlidingWindowRateLimiter(1, 100, {
    maxPrincipals: 2,
    clock,
  });

  assert.equal(limiter.consume('one'), true);
  assert.equal(limiter.consume('two'), true);
  assert.equal(limiter.principalCount, 2);
  assert.equal(limiter.consume('three'), true);
  assert.equal(limiter.principalCount, 2);
  now = 101;
  assert.equal(limiter.consume('fresh'), true);
  assert.equal(limiter.principalCount, 1);
});

test('rate limiter cleans stale principals in bounded sweeps', () => {
  var now = 0;
  const limiter = new SlidingWindowRateLimiter(1, 100, {
    maxPrincipals: 200,
    clock: () => now,
  });
  for (var index = 0; index < 130; index++) {
    assert.equal(limiter.consume(`stale-${index}`), true);
  }

  now = 101;
  assert.equal(limiter.consume('fresh'), true);
  assert.ok(limiter.principalCount <= 67);
  limiter.consume('fresh');
  limiter.consume('fresh');
  assert.equal(limiter.principalCount, 1);
});

test('non-retryable failures reset a closed circuit failure streak', () => {
  const breaker = new UpstreamCircuitBreaker(() => 0, 100);
  breaker.recordFailure('brave', true);
  breaker.recordFailure('brave', true);
  breaker.recordFailure('brave', false);
  breaker.recordFailure('brave', true);
  breaker.recordFailure('brave', true);

  assert.equal(breaker.canAttempt('brave'), true);
});

test('Gateway forwards the complete client result limit up to twenty', async () => {
  var receivedMaxResults = 0;
  const server = createGatewayServer(
    config,
    {
      search: async (request) => {
        receivedMaxResults = request.maxResults;
        return successfulUpstream();
      },
    },
  );
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  assert.ok(address != null && typeof address !== 'string');
  try {
    const response = await post(
      address.port,
      'Bearer client-token',
      { query: 'Flutter', max_results: 20 },
    );
    assert.equal(response.statusCode, 200);
    assert.equal(receivedMaxResults, 20);
  } finally {
    await new Promise<void>((resolve, reject) => server.close((error) => error == null ? resolve() : reject(error)));
  }
});

test('Gateway returns a structured 413 for an oversized request body', async () => {
  const server = createGatewayServer(config, {search: async () => successfulUpstream()});
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  assert.ok(address != null && typeof address !== 'string');
  try {
    const response = await post(
      address.port,
      'Bearer client-token',
      {query: 'Flutter', padding: 'x'.repeat(40 * 1024)},
    );
    assert.equal(response.statusCode, 413);
    assert.equal(response.body.error.code, 'REQUEST_TOO_LARGE');
  } finally {
    await new Promise<void>((resolve, reject) =>
      server.close((error) => error == null ? resolve() : reject(error)));
  }
});

test('Gateway returns a structured 413 for an oversized chunked body', async () => {
  const server = createGatewayServer(config, {search: async () => successfulUpstream()});
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  assert.ok(address != null && typeof address !== 'string');
  try {
    const response = await new Promise<{
      statusCode: number;
      body: {error: {code: string}};
    }>((resolve, reject) => {
      const client = request({
        hostname: '127.0.0.1',
        port: address.port,
        path: '/v1/search',
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: 'Bearer client-token',
          'Transfer-Encoding': 'chunked',
        },
      }, (incoming) => {
        let raw = '';
        incoming.setEncoding('utf8');
        incoming.on('data', (chunk) => raw += chunk);
        incoming.on('end', () => {
          try {
            resolve({statusCode: incoming.statusCode ?? 0, body: JSON.parse(raw)});
          } catch (error) {
            reject(error);
          }
        });
      });
      client.on('error', reject);
      client.end(JSON.stringify({query: 'Flutter', padding: 'x'.repeat(40 * 1024)}));
    });
    assert.equal(response.statusCode, 413);
    assert.equal(response.body.error.code, 'REQUEST_TOO_LARGE');
  } finally {
    await new Promise<void>((resolve, reject) =>
      server.close((error) => error == null ? resolve() : reject(error)));
  }
});

test('Gateway serves CORS only to configured origins', async () => {
  const server = createGatewayServer(config);
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  assert.ok(address != null && typeof address !== 'string');
  try {
    const preflight = await options(address.port, 'https://app.example.com');
    assert.equal(preflight.statusCode, 204);
    assert.equal(preflight.headers['access-control-allow-origin'], 'https://app.example.com');
    assert.match(preflight.headers.vary ?? '', /Origin/);
    const browserPost = await post(
      address.port,
      'Bearer client-token',
      { query: '' },
      'https://app.example.com',
    );
    assert.equal(browserPost.statusCode, 400);
    assert.equal(browserPost.headers['access-control-allow-origin'], 'https://app.example.com');
    const rejected = await options(address.port, 'https://untrusted.example.com');
    assert.equal(rejected.statusCode, 403);
    assert.equal(rejected.headers['access-control-allow-origin'], undefined);
  } finally {
    await new Promise<void>((resolve, reject) => server.close((error) => error == null ? resolve() : reject(error)));
  }
});

test('Gateway destroys a request whose body arrives too slowly', async () => {
  const server = createGatewayServer(
    {...config, requestTimeoutMs: 50},
    {search: async () => successfulUpstream()},
  );
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  assert.ok(address != null && typeof address !== 'string');
  try {
    const outcome = await slowBodyPost(address.port);
    assert.match(outcome, /ECONNRESET|socket hang up|response:408/);
  } finally {
    await new Promise<void>((resolve, reject) =>
      server.close((error) => error == null ? resolve() : reject(error)));
  }
});

test('Gateway aborts an in-flight upstream when the client disconnects', async () => {
  let aborted = false;
  let resolveAbort: (() => void) | undefined;
  const abortObserved = new Promise<void>((resolve) => {
    resolveAbort = resolve;
  });
  const server = createGatewayServer(
    {...config, requestTimeoutMs: 500},
    {
      search: async (_request, _config, signal) => {
        await new Promise<never>((_, reject) => {
          signal?.addEventListener('abort', () => {
            aborted = true;
            resolveAbort?.();
            reject(new GatewayError('UPSTREAM_UNAVAILABLE', 502, true));
          }, {once: true});
        });
        throw new GatewayError('UPSTREAM_UNAVAILABLE', 502, true);
      },
    },
  );
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  assert.ok(address != null && typeof address !== 'string');
  try {
    const encoded = JSON.stringify({query: 'Flutter'});
    const client = request({
      hostname: '127.0.0.1',
      port: address.port,
      path: '/v1/search',
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(encoded),
        Authorization: 'Bearer client-token',
      },
    });
    client.on('error', () => {});
    client.end(encoded);
    await new Promise<void>((resolve) => setTimeout(resolve, 20));
    client.destroy();
    await Promise.race([
      abortObserved,
      new Promise<never>((_, reject) =>
        setTimeout(() => reject(new Error('upstream abort was not observed')), 200),
      ),
    ]);
    assert.equal(aborted, true);
  } finally {
    await new Promise<void>((resolve, reject) =>
      server.close((error) => error == null ? resolve() : reject(error)));
  }
});

function post(
  port: number,
  authorization: string | undefined,
  body: unknown,
  origin?: string,
): Promise<{
  statusCode: number;
  body: { error: { code: string } };
  headers: Record<string, string | string[] | undefined>;
}> {
  const encoded = JSON.stringify(body);
  return new Promise((resolve, reject) => {
    const client = request({
      hostname: '127.0.0.1',
      port,
      path: '/v1/search',
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(encoded),
        Connection: 'close',
        ...(authorization == null ? {} : { Authorization: authorization }),
        ...(origin == null ? {} : { Origin: origin }),
      },
    }, (response) => {
      const chunks: Buffer[] = [];
      response.on('data', (chunk: Buffer) => chunks.push(chunk));
      response.on('end', () => resolve({
        statusCode: response.statusCode ?? 0,
        body: JSON.parse(Buffer.concat(chunks).toString('utf8')),
        headers: response.headers,
      }));
    });
    client.on('error', reject);
    client.end(encoded);
  });
}

function slowBodyPost(port: number): Promise<string> {
  return new Promise((resolve, reject) => {
    const client = request({
      hostname: '127.0.0.1',
      port,
      path: '/v1/search',
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': 2,
        Authorization: 'Bearer client-token',
      },
    }, (response) => {
      response.resume();
      response.on('end', () => resolve(`response:${response.statusCode ?? 0}`));
    });
    client.on('error', (error: NodeJS.ErrnoException) =>
      resolve(error.code ?? error.message),
    );
    client.write('{');
    setTimeout(() => client.end('}'), 200);
    client.setTimeout(1000, () => client.destroy());
    client.on('close', () => {
      if (!client.destroyed) reject(new Error('slow-body client did not close'));
    });
  });
}

function options(port: number, origin: string): Promise<{
  statusCode: number;
  headers: Record<string, string | string[] | undefined>;
}> {
  return new Promise((resolve, reject) => {
    const client = request({
      hostname: '127.0.0.1',
      port,
      path: '/v1/search',
      method: 'OPTIONS',
      headers: {
        Origin: origin,
        Connection: 'close',
        'Access-Control-Request-Method': 'POST',
        'Access-Control-Request-Headers': 'authorization, content-type, x-request-id',
      },
    }, (response) => {
      response.resume();
      response.on('end', () => resolve({
        statusCode: response.statusCode ?? 0,
        headers: response.headers,
      }));
    });
    client.on('error', reject);
    client.end();
  });
}

function successfulUpstream() {
  return {
    provider: 'brave',
    results: [{title: 'Flutter', url: 'https://docs.flutter.dev/', snippet: 'Official'}],
  };
}
