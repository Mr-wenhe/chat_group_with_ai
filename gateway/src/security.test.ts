import assert from 'node:assert/strict';
import test from 'node:test';

import { loadConfig, requireAuthorized } from './config.ts';
import { isForbiddenIp, isForbiddenHostname } from './network_security.ts';
import { GatewayError } from './types.ts';

test('blocks private, metadata, reserved, and local upstream addresses', () => {
  for (const address of [
    '127.0.0.1', '10.0.0.1', '169.254.169.254', '172.16.0.1',
    '192.168.1.1', '100.64.0.1', '198.51.100.1', '203.0.113.1',
    '::1', '0:0:0:0:0:0:0:1', 'fc00::1', 'fe80::1',
    '::ffff:127.0.0.1', '::ffff:7f00:1',
    '2001:db8::1', '2001:2::1', '100::1', '64:ff9b::a9fe:a9fe',
  ]) {
    assert.equal(isForbiddenIp(address), true, address);
  }
  assert.equal(isForbiddenIp('8.8.8.8'), false);
  assert.equal(isForbiddenIp('2606:4700:4700::1111'), false);
  assert.equal(isForbiddenHostname('service.127.0.0.1.nip.io'), true);
  assert.equal(isForbiddenHostname('api.search.brave.com'), false);
});

test('production config requires a selected provider key and client token', () => {
  assert.throws(
    () => loadConfig({ NODE_ENV: 'production', SEARCH_PROVIDER: 'brave', BRAVE_API_KEY: 'key' }),
    /GATEWAY_API_TOKENS/,
  );
  const config = loadConfig({
    NODE_ENV: 'production',
    SEARCH_PROVIDER: 'brave',
    BRAVE_API_KEY: 'provider-key',
    GATEWAY_API_TOKENS: 'client-token',
  });
  assert.equal(config.provider, 'brave');
  assert.deepEqual(config.allowedOrigins, new Set());
  assert.equal(requireAuthorized('Bearer client-token', config), 'client-token');
  assert.throws(
    () => requireAuthorized('Bearer wrong-token', config),
    (error: unknown) => error instanceof GatewayError && error.code === 'UNAUTHORIZED',
  );
});

test('normalizes the configured CORS origin list', () => {
  const config = loadConfig({
    NODE_ENV: 'production',
    SEARCH_PROVIDER: 'brave',
    BRAVE_API_KEY: 'provider-key',
    GATEWAY_API_TOKENS: 'client-token',
    ALLOWED_ORIGINS: 'https://app.example.com/, https://admin.example.com',
  });

  assert.deepEqual(
    [...config.allowedOrigins],
    ['https://app.example.com', 'https://admin.example.com'],
  );
  assert.throws(
    () => loadConfig({
      NODE_ENV: 'production',
      SEARCH_PROVIDER: 'brave',
      BRAVE_API_KEY: 'provider-key',
      GATEWAY_API_TOKENS: 'client-token',
      ALLOWED_ORIGINS: 'https://app.example.com/path',
    }),
    /ALLOWED_ORIGINS/,
  );
});

test('rejects integer environment values with trailing characters', () => {
  assert.throws(
    () => loadConfig({
      NODE_ENV: 'production',
      SEARCH_PROVIDER: 'brave',
      BRAVE_API_KEY: 'provider-key',
      GATEWAY_API_TOKENS: 'client-token',
      RATE_LIMIT_PER_MINUTE: '60garbage',
    }),
    /RATE_LIMIT_PER_MINUTE/,
  );
});
