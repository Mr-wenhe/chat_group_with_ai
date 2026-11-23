import { request } from 'node:https';
import { isIP } from 'node:net';
import { isForbiddenHostname, isForbiddenIp, resolvePublicAddresses } from './network_security.ts';
import { GatewayError } from './types.ts';

export function parsePublicDnsAnswer(value: unknown): string[] {
  if (value === null || typeof value !== 'object') throw new GatewayError('DNS_INVALID_RESPONSE', 502, false);
  const body = value as { Status?: unknown; Answer?: unknown };
  if (body.Status !== 0 || !Array.isArray(body.Answer)) throw new GatewayError('DNS_INVALID_RESPONSE', 502, false);
  const addresses = body.Answer.filter((record) => record?.type === 1).map((record) => record.data);
  if (!addresses.length || addresses.some((address) => typeof address !== 'string' || isIP(address) !== 4 || isForbiddenIp(address))) {
    throw new GatewayError('UPSTREAM_DNS_BLOCKED', 502, false);
  }
  return [...new Set(addresses)] as string[];
}

/** Fixed TLS-authenticated DNS bootstrap only; fetched destinations never inherit this exception. */
export async function resolveWebAddresses(hostname: string, signal?: AbortSignal): Promise<string[]> {
  if (isForbiddenHostname(hostname)) throw new GatewayError('UPSTREAM_DNS_BLOCKED', 502, false);
  try { return await resolvePublicAddresses(hostname); } catch {
    signal?.throwIfAborted();
    const url = new URL('https://dns.google/resolve');
    url.search = new URLSearchParams({ name: hostname, type: 'A', edns_client_subnet: '0.0.0.0/0' }).toString();
    const combined = signal ? AbortSignal.any([signal, AbortSignal.timeout(8000)]) : AbortSignal.timeout(8000);
    return await new Promise((resolve, reject) => {
      const req = request(url, { signal: combined, headers: { Accept: 'application/dns-json' } }, (res) => {
        if (res.statusCode !== 200) { res.destroy(); reject(new GatewayError('DNS_LOOKUP_FAILED', 502, true)); return; }
        const chunks: Buffer[] = [];
        let length = 0;
        res.on('error', reject);
        res.on('data', (chunk: Buffer) => {
          length += chunk.length;
          if (length > 65536) res.destroy(new GatewayError('DNS_INVALID_RESPONSE', 502, false));
          else chunks.push(chunk);
        });
        res.on('end', () => {
          try { resolve(parsePublicDnsAnswer(JSON.parse(Buffer.concat(chunks).toString('utf8')))); }
          catch { reject(new GatewayError('DNS_INVALID_RESPONSE', 502, false)); }
        });
      });
      req.on('error', reject);
      req.end();
    });
  }
}
