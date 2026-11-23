import { request } from 'node:https';
import { isForbiddenHostname, pinnedLookup } from './network_security.ts';
import { resolveWebAddresses } from './public_web_dns.ts';
import { GatewayError } from './types.ts';

export function validatePublicWebUrl(value: string): URL {
  let url: URL;
  try { url = new URL(value); } catch {
    throw new GatewayError('INVALID_SOURCE_URL', 400, false);
  }
  if (url.protocol !== 'https:' || url.username || url.password ||
      (url.port !== '' && url.port !== '443') || isForbiddenHostname(url.hostname.replace(/^\[|\]$/g, ''))) {
    throw new GatewayError('SOURCE_URL_BLOCKED', 400, false);
  }
  url.hash = '';
  return url;
}

/** Each redirect is resolved and pinned independently; no credentials or cookies are forwarded. */
export async function fetchPublicWeb(
  value: string,
  maxBytes: number,
  signal?: AbortSignal,
  stream?: {
    headers: (url: string, contentType: string) => Promise<void>;
    chunk: (bytes: Buffer) => Promise<void>;
  },
): Promise<{ url: string; contentType: string; bytes: Buffer; byteLength: number }> {
  if (!Number.isSafeInteger(maxBytes) || maxBytes < 1 || maxBytes > 64 * 1024 * 1024) {
    throw new GatewayError('INVALID_BYTE_LIMIT', 400, false);
  }
  let url = validatePublicWebUrl(value);
  const searchPage = (url.hostname === 'html.duckduckgo.com' && url.pathname === '/html/') ||
    (url.hostname === 'www.bing.com' && url.pathname === '/search');
  const deadline = AbortSignal.timeout(searchPage ? 8000 : maxBytes > 10 * 1024 * 1024 ? 120_000 : 25_000);
  const combined = signal ? AbortSignal.any([deadline, signal]) : deadline;
  for (let redirects = 0; redirects <= 3; redirects++) {
    combined.throwIfAborted();
    const addresses = await resolveWebAddresses(url.hostname, combined);
    const response = await new Promise<{
      location?: string; contentType: string; bytes: Buffer; byteLength: number;
    }>((resolve, reject) => {
      const req = request(url, {
        lookup: pinnedLookup(addresses), signal: combined,
        headers: { 'User-Agent': 'Banban/1.0', Accept: '*/*', 'Accept-Encoding': 'identity' },
      }, (res) => {
        const status = res.statusCode ?? 0;
        if ([301, 302, 303, 307, 308].includes(status)) {
          res.destroy();
          if (!res.headers.location) return reject(new GatewayError('INVALID_REDIRECT', 502, false));
          return resolve({ location: res.headers.location, contentType: '', bytes: Buffer.alloc(0), byteLength: 0 });
        }
        if (status < 200 || status >= 300) {
          res.destroy();
          return reject(new GatewayError('SOURCE_HTTP_ERROR', status || 502, status === 429 || status >= 500));
        }
        void (async () => {
          const contentType = res.headers['content-type'] ?? '';
          if (stream) await stream.headers(url.href, contentType);
          const chunks: Buffer[] = [];
          let size = 0;
          for await (const raw of res) {
            const chunk = Buffer.isBuffer(raw) ? raw : Buffer.from(raw);
            size += chunk.length;
            if (size > maxBytes) throw new GatewayError('SOURCE_TOO_LARGE', 413, false);
            if (stream) await stream.chunk(chunk);
            else chunks.push(chunk);
          }
          resolve({ contentType, bytes: Buffer.concat(chunks), byteLength: size });
        })().catch((error) => { res.destroy(); reject(error); });
      });
      req.on('error', reject);
      req.end();
    });
    if (response.location === undefined) return { url: url.href, ...response };
    url = validatePublicWebUrl(new URL(response.location, url).href);
  }
  throw new GatewayError('REDIRECT_LIMIT', 502, false);
}
