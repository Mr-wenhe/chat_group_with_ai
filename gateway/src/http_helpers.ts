import { createHash, randomUUID } from 'node:crypto';
import type { IncomingMessage, ServerResponse } from 'node:http';

import { GatewayError } from './types.ts';
import type { GatewayConfig, GatewaySearchRequest } from './types.ts';

const maxRequestBodyBytes = 32 * 1024;
const categories = new Set([
  'general', 'news', 'weather', 'finance', 'software', 'policy', 'academic', 'local',
]);
const freshnessValues = new Set(['any', 'day', 'week', 'month', 'year']);
const requestIdPattern = /^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$/;
const localePattern = /^[A-Za-z]{2,3}(?:-[A-Za-z]{2,4})?$/;
const countryPattern = /^[A-Za-z]{2}$/;

export function parseSearchRequest(
  value: unknown,
  fallbackRequestId: string,
): GatewaySearchRequest {
  if (!isRecord(value)) throw new GatewayError('INVALID_REQUEST', 400, false);
  const requestId = safeRequestId(value.request_id) ?? fallbackRequestId;
  const query = stringValue(value.query, 400);
  if (query.length === 0) throw new GatewayError('INVALID_REQUEST', 400, false);
  const category = stringValue(value.category, 32) || 'general';
  const freshness = stringValue(value.freshness, 16) || 'any';
  const locale = stringValue(value.locale, 16) || 'zh-CN';
  const country = optionalCountry(value.country);
  const maxResults = boundedInteger(value.max_results, 1, 20, 5);
  if (!categories.has(category) ||
      !freshnessValues.has(freshness) ||
      !localePattern.test(locale)) {
    throw new GatewayError('INVALID_REQUEST', 400, false);
  }
  return {
    requestId,
    query,
    category,
    freshness,
    locale,
    ...(country == null ? {} : { country }),
    maxResults,
    // The production gateway never allows a caller to disable safe search.
    safeSearch: true,
    forceRefresh: value.force_refresh === true,
  };
}

export async function readJson(
  request: IncomingMessage,
  timeoutMs: number,
): Promise<unknown> {
  if (!header(request, 'content-type')?.toLowerCase().startsWith('application/json')) {
    throw new GatewayError('INVALID_REQUEST', 400, false);
  }
  const declaredLength = header(request, 'content-length');
  if (declaredLength != null) {
    if (!/^\d+$/.test(declaredLength)) {
      throw new GatewayError('INVALID_REQUEST', 400, false);
    }
    const parsedLength = Number(declaredLength);
    if (!Number.isSafeInteger(parsedLength) || parsedLength < 0) {
      throw new GatewayError('INVALID_REQUEST', 400, false);
    }
    if (parsedLength > maxRequestBodyBytes) {
      throw new GatewayError('REQUEST_TOO_LARGE', 413, false);
    }
  }
  const chunks: Buffer[] = [];
  var bytes = 0;
  var deadlineReached = false;
  const bodyDeadline = setTimeout(() => {
    deadlineReached = true;
    request.destroy();
  }, timeoutMs);
  try {
    for await (const chunk of request) {
      bytes += chunk.length;
      if (bytes > maxRequestBodyBytes) {
        throw new GatewayError('REQUEST_TOO_LARGE', 413, false);
      }
      chunks.push(chunk);
    }
  } catch (error) {
    if (deadlineReached) {
      throw new GatewayError('REQUEST_TIMEOUT', 408, true);
    }
    throw error;
  } finally {
    clearTimeout(bodyDeadline);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    throw new GatewayError('INVALID_REQUEST', 400, false);
  }
}

export function writeJson(
  response: ServerResponse,
  statusCode: number,
  body: unknown,
  corsOrigin?: string,
): void {
  const encoded = JSON.stringify(body);
  response.writeHead(statusCode, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(encoded),
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    ...corsHeaders(corsOrigin),
  });
  response.end(encoded);
}

export function writePreflight(
  response: ServerResponse,
  corsOrigin: string | undefined,
): void {
  if (corsOrigin == null) throw new GatewayError('FORBIDDEN', 403, false);
  response.writeHead(204, {
    ...corsHeaders(corsOrigin),
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Authorization, Content-Type, X-Request-Id',
    'Access-Control-Max-Age': '600',
    'Cache-Control': 'no-store',
  });
  response.end();
}

export function requestIdFrom(request: IncomingMessage): string {
  return safeRequestId(header(request, 'x-request-id')) ?? randomUUID();
}

export function allowedCorsOrigin(
  request: IncomingMessage,
  config: GatewayConfig,
): string | undefined {
  const origin = header(request, 'origin');
  if (origin == null) return undefined;
  if (!config.allowedOrigins.has(origin)) {
    throw new GatewayError('FORBIDDEN', 403, false);
  }
  return origin;
}

export function rateLimitKey(
  principal: string | null,
  request: IncomingMessage,
): string {
  if (principal == null) {
    return `ip:${request.socket.remoteAddress ?? 'unknown'}`;
  }
  // The rate limiter must not retain an Authorization header or credential in
  // its buckets. Authentication already normalized this token before hashing.
  return `token:${createHash('sha256').update(principal).digest('base64url')}`;
}

export function header(
  request: IncomingMessage,
  name: string,
): string | undefined {
  const value = request.headers[name];
  return Array.isArray(value) ? value[0] : value;
}

export function asGatewayError(error: unknown): GatewayError {
  return error instanceof GatewayError
      ? error
      : new GatewayError('INTERNAL_ERROR', 500, true);
}

export function publicMessage(code: string): string {
  if (code === 'UNAUTHORIZED') return 'Authentication is required.';
  if (code === 'RATE_LIMITED') return 'Search service is temporarily rate limited.';
  if (code === 'FORBIDDEN') return 'The request origin is not permitted.';
  if (code === 'REQUEST_TOO_LARGE') return 'The search request is too large.';
  if (code === 'INVALID_REQUEST') return 'The search request is invalid.';
  if (code === 'REQUEST_TIMEOUT') return 'The search request timed out.';
  if (code === 'NOT_FOUND') return 'The requested search endpoint was not found.';
  return 'Search service is temporarily unavailable.';
}

export function logOutcome(requestId: string, statusCode: number): void {
  // Never log request body, credentials, provider response, or full query.
  console.info(`[search-gateway] request_id=${requestId} status=${statusCode}`);
}

function corsHeaders(corsOrigin: string | undefined): Record<string, string> {
  return corsOrigin == null
      ? {}
      : {
          'Access-Control-Allow-Origin': corsOrigin,
          Vary: 'Origin',
        };
}

function safeRequestId(value: unknown): string | null {
  return typeof value === 'string' && requestIdPattern.test(value) ? value : null;
}

function optionalCountry(value: unknown): string | null {
  if (value == null || value === '') return null;
  return typeof value === 'string' && countryPattern.test(value)
      ? value.toUpperCase()
      : null;
}

function stringValue(value: unknown, maximumLength: number): string {
  return typeof value === 'string' ? value.trim().slice(0, maximumLength) : '';
}

function boundedInteger(
  value: unknown,
  minimum: number,
  maximum: number,
  fallback: number,
): number {
  return typeof value === 'number' &&
          Number.isInteger(value) &&
          value >= minimum &&
          value <= maximum
      ? value
      : fallback;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value != null && typeof value === 'object' && !Array.isArray(value);
}
