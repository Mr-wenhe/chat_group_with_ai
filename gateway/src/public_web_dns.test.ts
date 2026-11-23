import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parsePublicDnsAnswer, resolveWebAddresses } from './public_web_dns.ts';

test('DNS fallback admits only public IPv4 answers', () => {
  assert.deepEqual(parsePublicDnsAnswer({ Status: 0, Answer: [{ type: 1, data: '8.8.8.8' }] }), ['8.8.8.8']);
  for (const address of ['127.0.0.1', '198.18.0.1', '10.0.0.1', '::1', 'malformed']) {
    assert.throws(() => parsePublicDnsAnswer({ Status: 0, Answer: [{ type: 1, data: address }] }));
  }
  assert.throws(() => parsePublicDnsAnswer({ Status: 0, Answer: [] }));
  assert.throws(() => parsePublicDnsAnswer({ Status: 3, Answer: [{ type: 1, data: '8.8.8.8' }] }));
});
test('DNS fallback never resolves prohibited hostnames', async () => {
  await assert.rejects(resolveWebAddresses('localhost'), /UPSTREAM_DNS_BLOCKED/);
});
