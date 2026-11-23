import assert from 'node:assert/strict';
import test from 'node:test';

import { isForbiddenIp, isForbiddenHostname } from './network_security.ts';

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
  assert.equal(isForbiddenHostname('example.com'), false);
});

test('pinned lookup honors Node all-address requests without re-resolving', async () => {
  const { pinnedLookup } = await import('./network_security.ts');
  const lookup = pinnedLookup(['8.8.8.8', '1.1.1.1']);
  lookup('ignored.example', { all: true }, (error, addresses) => {
    assert.equal(error, null);
    assert.deepEqual(addresses, [{ address: '8.8.8.8', family: 4 }, { address: '1.1.1.1', family: 4 }]);
  });
  lookup('ignored.example', {}, (error, address, family) => {
    assert.equal(error, null);
    assert.equal(address, '8.8.8.8');
    assert.equal(family, 4);
  });
});
