import { lookup } from 'node:dns/promises';
import { isIP } from 'node:net';

import { GatewayError } from './types.ts';

export async function resolvePublicAddresses(hostname: string): Promise<string[]> {
  const normalized = hostname.trim().replace(/\.$/, '').toLowerCase();
  if (!normalized || isForbiddenHostname(normalized)) {
    throw new GatewayError('UPSTREAM_DNS_BLOCKED', 502, false);
  }
  let addresses: { address: string }[];
  try {
    addresses = await lookup(normalized, { all: true, verbatim: true });
  } catch {
    throw new GatewayError('UPSTREAM_DNS_FAILED', 502, true);
  }
  if (addresses.length === 0 || addresses.some(({ address }) => isForbiddenIp(address))) {
    throw new GatewayError('UPSTREAM_DNS_BLOCKED', 502, false);
  }
  return [...new Set(addresses.map(({ address }) => address))];
}

/// The configured upstream is resolved immediately before every request and
/// the resulting address is pinned into https.request's lookup callback. This
/// closes the validate-then-re-resolve window used by DNS rebinding attacks.
export function pinnedLookup(addresses: readonly string[]) {
  var index = 0;
  return (
    _hostname: string,
    _options: unknown,
    callback: (error: Error | null, address?: string, family?: number) => void,
  ): void => {
    const address = addresses[index++ % addresses.length];
    callback(null, address, isIP(address));
  };
}

export function isForbiddenHostname(hostname: string): boolean {
  return hostname === 'localhost' ||
      hostname.endsWith('.localhost') ||
      hostname.endsWith('.local') ||
      hostname.endsWith('.internal') ||
      hostname.endsWith('.nip.io') ||
      hostname.endsWith('.xip.io') ||
      hostname.endsWith('.sslip.io') ||
      hostname === 'metadata.google.internal' ||
      hostname === 'host.docker.internal' ||
      (isIP(hostname) !== 0 && isForbiddenIp(hostname));
}

export function isForbiddenIp(address: string): boolean {
  const family = isIP(address);
  if (family === 4) return isForbiddenIpv4(address);
  if (family === 6) return isForbiddenIpv6(address);
  return true;
}

function isForbiddenIpv4(address: string): boolean {
  const parts = address.split('.').map((part) => Number.parseInt(part, 10));
  if (parts.length !== 4 || parts.some((part) => !Number.isInteger(part))) {
    return true;
  }
  const [first, second] = parts;
  return first === 0 ||
      first === 10 ||
      first === 127 ||
      (first === 169 && second === 254) ||
      (first === 172 && second >= 16 && second <= 31) ||
      (first === 192 && (second === 0 || second === 2 || second === 88 || second === 168)) ||
      (first === 100 && second >= 64 && second <= 127) ||
      (first === 198 && (second === 18 || second === 19 || second === 51)) ||
      (first === 203 && second === 0) ||
      first >= 224;
}

function isForbiddenIpv6(address: string): boolean {
  const groups = parseIpv6(address);
  if (groups == null) return true;
  const first = groups[0];
  const unspecified = groups.every((group) => group === 0);
  const loopback = groups.slice(0, 7).every((group) => group === 0) && groups[7] === 1;
  if (unspecified || loopback ||
      (first & 0xfe00) === 0xfc00 || // fc00::/7 unique-local
      (first & 0xffc0) === 0xfe80 || // fe80::/10 link-local
      (first & 0xff00) === 0xff00) { // ff00::/8 multicast
    return true;
  }
  if (isReservedIpv6Range(groups)) return true;
  const mapped = groups.slice(0, 5).every((group) => group === 0) && groups[5] === 0xffff;
  return mapped && isForbiddenIpv4(
    `${groups[6] >> 8}.${groups[6] & 255}.${groups[7] >> 8}.${groups[7] & 255}`,
  );
}

function isReservedIpv6Range(groups: readonly number[]): boolean {
  const [first, second, third, fourth, fifth, sixth] = groups;
  const embeddedNat64 = first === 0x0064 && second === 0xff9b &&
      third === 0 && fourth === 0 && fifth === 0 && sixth === 0;
  const localUseNat64 = first === 0x0064 && second === 0xff9b && third === 1;
  const discardOnly = first === 0x0100 && second === 0 && third === 0 && fourth === 0;
  const dummy = first === 0x0100 && second === 0 && third === 0 && fourth === 1;
  const teredo = first === 0x2001 && second === 0;
  const benchmarking = first === 0x2001 && second === 0x0002;
  const orchid = first === 0x2001 && (second & 0xfff0) === 0x0010;
  const documentation = first === 0x2001 && second === 0x0db8;
  const obsolete6to4 = first === 0x2002;
  const documentationRange = first === 0x3fff && (second & 0xf000) === 0;
  const segmentRouting = first === 0x5f00;
  return embeddedNat64 || localUseNat64 || discardOnly || dummy || teredo ||
      benchmarking || orchid || documentation || obsolete6to4 ||
      documentationRange || segmentRouting;
}

function parseIpv6(value: string): number[] | null {
  const normalized = value.toLowerCase();
  if (normalized.split('::').length > 2) return null;
  const [leftRaw, rightRaw = ''] = normalized.split('::');
  const left = parseIpv6Half(leftRaw);
  const right = parseIpv6Half(rightRaw);
  if (left == null || right == null) return null;
  if (!normalized.includes('::')) return left.length === 8 ? left : null;
  const missing = 8 - left.length - right.length;
  return missing < 1 ? null : [...left, ...Array<number>(missing).fill(0), ...right];
}

function parseIpv6Half(value: string): number[] | null {
  if (value.length === 0) return [];
  const groups: number[] = [];
  const parts = value.split(':');
  for (const [index, part] of parts.entries()) {
    if (part.includes('.')) {
      const ipv4 = parseIpv4Bytes(part);
      if (ipv4 == null || index !== parts.length - 1) return null;
      groups.push((ipv4[0] << 8) | ipv4[1], (ipv4[2] << 8) | ipv4[3]);
      continue;
    }
    if (!/^[0-9a-f]{1,4}$/.test(part)) return null;
    groups.push(Number.parseInt(part, 16));
  }
  return groups;
}

function parseIpv4Bytes(address: string): number[] | null {
  const parts = address.split('.').map((part) => Number.parseInt(part, 10));
  return parts.length === 4 && parts.every((part) => Number.isInteger(part) && part >= 0 && part <= 255)
      ? parts
      : null;
}
