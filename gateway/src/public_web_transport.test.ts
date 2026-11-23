import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fetchPublicWeb, validatePublicWebUrl } from './public_web_transport.ts';

test('public source URLs reject credentials, local destinations and non-HTTPS', () => {
  for (const url of ['http://example.com', 'https://localhost/',
    'https://127.0.0.1/', 'https://[::1]/', 'https://user:secret@example.com',
    'https://example.com:8443/', 'file:///etc/passwd']) {
    assert.throws(() => validatePublicWebUrl(url));
  }
  assert.equal(validatePublicWebUrl('https://example.com/a#fragment').href, 'https://example.com/a');
});

test('invalid byte limits fail before opening any connection', async () => {
  for (const limit of [0, -1, NaN, 1.5, 64 * 1024 * 1024 + 1]) {
    await assert.rejects(fetchPublicWeb('https://example.com/', limit), /INVALID_BYTE_LIMIT/);
  }
});
