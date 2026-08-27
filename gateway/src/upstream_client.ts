import { request as httpsRequest } from 'node:https';

import { isForbiddenHostname, pinnedLookup, resolvePublicAddresses } from './network_security.ts';
import { GatewayError } from './types.ts';
import type {
  GatewayConfig,
  GatewaySearchRequest,
  GatewaySearchResult,
} from './types.ts';

const maxUpstreamBodyBytes = 1024 * 1024;
const sensitiveUrlPatterns = [
  /-----BEGIN [^-]+-----[\s\S]*?-----END [^-]+-----/i,
  /\b(?:authorization|proxy-authorization|cookie|set-cookie)\s*[:=]\s*[^\s,;}"']+/i,
  /\b(?:[A-Za-z0-9]+[_-])*(?:api[-_ ]?key|access[-_ ]?key|access[-_ ]?token|client[-_ ]?secret|subscription[-_ ]?key|secret[-_ ]?access[-_ ]?key|session[-_ ]?token|private[-_ ]?key|credential|password|secret|token|authorization|proxy[-_ ]?authorization|cookie|set[-_ ]?cookie)\s*[:=]\s*["']?(?:bearer\s+)?[^\s,;}"']+/i,
  /\bbearer\s+[A-Za-z0-9._~+/=-]{8,}/i,
  /\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\b/,
  /\b(?:sk|pk|tvly|pplx|gsk|xai|hf|r8)-[A-Za-z0-9][A-Za-z0-9_./-]{7,}/i,
  /\bbce-v[23]\/[A-Za-z0-9][A-Za-z0-9_./-]{7,}/i,
  /\bAIza[A-Za-z0-9_-]{20,}/i,
  /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/i,
];

type GatewayUpstreamResponse = {
  statusCode: number;
  headers: Record<string, string | undefined>;
  body: unknown;
};

export type GatewayUpstreamTransport = (
  url: URL,
  options: {
    method: 'GET' | 'POST';
    headers: Record<string, string>;
    body?: string;
    timeoutMs: number;
    addresses: readonly string[];
    signal?: AbortSignal;
  },
) => Promise<GatewayUpstreamResponse>;

export type GatewayAddressResolver = (hostname: string) => Promise<string[]>;

export async function searchUpstream(
  request: GatewaySearchRequest,
  config: GatewayConfig,
  transport: GatewayUpstreamTransport = requestJson,
  addressResolver: GatewayAddressResolver = resolvePublicAddresses,
  signal?: AbortSignal,
): Promise<{
  providerRequestId?: string;
  provider: string;
  results: GatewaySearchResult[];
}> {
  const upstream = buildUpstreamRequest(request, config);
  const addresses = await withTimeout(
    addressResolver(upstream.url.hostname),
    config.requestTimeoutMs,
    () => new GatewayError('UPSTREAM_DNS_TIMEOUT', 502, true),
    {signal},
  );
  if (addresses.length === 0) {
    throw new GatewayError('UPSTREAM_DNS_FAILED', 502, true);
  }
  const transportController = new AbortController();
  const detachAbort = linkAbort(signal, transportController);
  let response: GatewayUpstreamResponse;
  try {
    response = await withTimeout(
      transport(upstream.url, {
        method: upstream.method,
        headers: upstream.headers,
        body: upstream.body,
        timeoutMs: config.requestTimeoutMs,
        addresses,
        signal: transportController.signal,
      }),
      config.requestTimeoutMs,
      () => new GatewayError('UPSTREAM_TIMEOUT', 504, true),
      {
        signal,
        onTimeout: () => transportController.abort(),
      },
    );
  } finally {
    detachAbort();
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw httpError(response.statusCode);
  }
  if (response.body == null) {
    throw new GatewayError('UPSTREAM_INVALID_RESPONSE', 502, false);
  }
  return {
    providerRequestId: safeRequestId(response.headers['x-request-id']),
    provider: config.provider,
    results: config.provider === 'brave'
        ? normalizeBrave(response.body, request.maxResults)
        : normalizeTavily(response.body, request.maxResults),
  };
}

function withTimeout<T>(
  operation: Promise<T>,
  timeoutMs: number,
  timeoutError: () => GatewayError,
  options: {
    signal?: AbortSignal;
    onTimeout?: () => void;
  } = {},
): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    var settled = false;
    let onAbort: (() => void) | undefined;
    const cleanup = (timer: ReturnType<typeof setTimeout>) => {
      clearTimeout(timer);
      if (onAbort != null) {
        options.signal?.removeEventListener('abort', onAbort);
      }
    };
    const timer = setTimeout(() => {
      if (settled) return;
      options.onTimeout?.();
      settled = true;
      cleanup(timer);
      reject(timeoutError());
    }, Math.max(1, timeoutMs));
    onAbort = () => {
      if (settled) return;
      options.onTimeout?.();
      settled = true;
      cleanup(timer);
      reject(new GatewayError('UPSTREAM_CANCELLED', 499, false));
    };
    const finish = (callback: (value: T | unknown) => void, value: T | unknown) => {
      if (settled) return;
      settled = true;
      cleanup(timer);
      callback(value);
    };
    if (options.signal?.aborted) {
      onAbort();
      // The caller may have already cancelled before the operation was
      // wrapped. Attach a rejection handler even though the wrapper settles
      // immediately, otherwise a late DNS/transport rejection becomes an
      // unhandled promise rejection.
      void operation.catch(() => {});
      clearTimeout(timer);
      return;
    }
    options.signal?.addEventListener('abort', onAbort, {once: true});
    operation.then(
      (value) => finish(resolve, value),
      (error) => finish(reject, error),
    );
  });
}

function linkAbort(
  parent: AbortSignal | undefined,
  child: AbortController,
): () => void {
  if (parent == null) return () => {};
  const onAbort = () => child.abort();
  if (parent.aborted) {
    onAbort();
  } else {
    parent.addEventListener('abort', onAbort, {once: true});
  }
  return () => parent.removeEventListener('abort', onAbort);
}

function buildUpstreamRequest(
  request: GatewaySearchRequest,
  config: GatewayConfig,
): { url: URL; method: 'GET' | 'POST'; headers: Record<string, string>; body?: string } {
  if (config.provider === 'brave') {
    const url = new URL('https://api.search.brave.com/res/v1/web/search');
    url.search = new URLSearchParams({
      q: request.query,
      count: String(request.maxResults),
      country: request.country ?? 'CN',
      search_lang: request.locale.split('-')[0] || 'en',
      ui_lang: request.locale,
      safesearch: 'moderate',
      text_decorations: 'false',
      extra_snippets: 'false',
      result_filter: 'web',
      ...(freshnessForBrave(request.freshness) == null
          ? {}
          : { freshness: freshnessForBrave(request.freshness)! }),
    }).toString();
    return {
      url,
      method: 'GET',
      headers: {
        Accept: 'application/json',
        'X-Subscription-Token': config.providerApiKey,
      },
    };
  }

  const body = JSON.stringify({
    query: request.query,
    search_depth: 'basic',
    max_results: request.maxResults,
    topic: request.category === 'news' ? 'news' : 'general',
    include_answer: false,
    include_raw_content: false,
    include_images: false,
    include_image_descriptions: false,
    include_favicon: false,
    auto_parameters: false,
    ...(timeRangeForTavily(request.freshness) == null
        ? {}
        : { time_range: timeRangeForTavily(request.freshness) }),
  });
  return {
    url: new URL('https://api.tavily.com/search'),
    method: 'POST',
    headers: {
      Authorization: `Bearer ${config.providerApiKey}`,
      'Content-Type': 'application/json',
      Accept: 'application/json',
      'Content-Length': String(Buffer.byteLength(body)),
    },
    body,
  };
}

async function requestJson(
  url: URL,
  options: {
    method: 'GET' | 'POST';
    headers: Record<string, string>;
    body?: string;
    timeoutMs: number;
    addresses: readonly string[];
    signal?: AbortSignal;
  },
): Promise<GatewayUpstreamResponse> {
  return new Promise((resolve, reject) => {
    var settled = false;
    const timer = setTimeout(() => {
      finishReject(new GatewayError('UPSTREAM_TIMEOUT', 504, true));
      upstream.destroy(new Error('upstream timeout'));
    }, Math.max(1, options.timeoutMs));
    const finishResolve = (value: GatewayUpstreamResponse) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(value);
    };
    const finishReject = (error: unknown) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      reject(error);
    };
    let upstream: ReturnType<typeof httpsRequest>;
    try {
      upstream = httpsRequest(url, {
        method: options.method,
        headers: options.headers,
        lookup: pinnedLookup(options.addresses),
        servername: url.hostname,
        rejectUnauthorized: true,
        ...(options.signal == null ? {} : {signal: options.signal}),
      }, (response) => {
        const chunks: Buffer[] = [];
        var bytes = 0;
        response.on('data', (chunk: Buffer) => {
          bytes += chunk.length;
          if (bytes > maxUpstreamBodyBytes) {
            finishReject(new GatewayError('UPSTREAM_RESPONSE_TOO_LARGE', 502, true));
            response.destroy(new Error('response too large'));
            return;
          }
          chunks.push(chunk);
        });
        response.on('error', () =>
          finishReject(new GatewayError('UPSTREAM_UNAVAILABLE', 502, true)));
        response.on('end', () => {
          let body: unknown = null;
          try {
            body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
          } catch {
            // A non-JSON upstream response is intentionally never returned.
          }
          finishResolve({
            statusCode: response.statusCode ?? 502,
            headers: {
              'x-request-id': headerValue(response.headers['x-request-id']),
            },
            body,
          });
        });
      });
      upstream.setTimeout(options.timeoutMs, () => {
        finishReject(new GatewayError('UPSTREAM_TIMEOUT', 504, true));
        upstream.destroy(new Error('upstream timeout'));
      });
      upstream.on('error', () =>
        finishReject(new GatewayError('UPSTREAM_UNAVAILABLE', 502, true)));
      if (options.body != null) upstream.write(options.body);
      upstream.end();
    } catch (error) {
      finishReject(error);
    }
  });
}

function normalizeBrave(body: unknown, maxResults: number): GatewaySearchResult[] {
  const results = isRecord(body) && isRecord(body.web) && Array.isArray(body.web.results)
      ? body.web.results
      : null;
  return normalizeResults(results, maxResults, (item) => ({
    title: item.title,
    url: item.url,
    snippet: item.description,
    published_at: item.page_age ?? item.published_date,
    score: item.score,
    language: item.language,
  }));
}

function normalizeTavily(body: unknown, maxResults: number): GatewaySearchResult[] {
  const results = isRecord(body) && Array.isArray(body.results) ? body.results : null;
  return normalizeResults(results, maxResults, (item) => ({
    title: item.title,
    url: item.url,
    snippet: item.content,
    published_at: item.published_date ?? item.published_at,
    score: item.score,
    language: item.language,
  }));
}

function normalizeResults(
  raw: unknown[] | null,
  maxResults: number,
  select: (item: Record<string, unknown>) => Record<string, unknown>,
): GatewaySearchResult[] {
  if (raw == null) throw new GatewayError('UPSTREAM_INVALID_RESPONSE', 502, false);
  const results: GatewaySearchResult[] = [];
  const seen = new Set<string>();
  for (const candidate of raw) {
    if (results.length >= maxResults || !isRecord(candidate)) continue;
    const item = select(candidate);
    const url = safeResultUrl(item.url);
    if (url == null || seen.has(url)) continue;
    seen.add(url);
    results.push({
      title: boundedText(item.title, 300) || '搜索结果',
      url,
      snippet: boundedText(item.snippet, 800),
      ...(safeDate(item.published_at) == null ? {} : { published_at: safeDate(item.published_at)! }),
      ...(typeof item.score === 'number' && Number.isFinite(item.score) ? { score: item.score } : {}),
      ...(boundedText(item.language, 32) === '' ? {} : { language: boundedText(item.language, 32) }),
    });
  }
  return results;
}

function safeResultUrl(value: unknown): string | null {
  if (typeof value !== 'string' || value.length > 2048) return null;
  try {
    const url = new URL(value);
    if (url.protocol !== 'https:' ||
        url.username || url.password || isForbiddenHostname(url.hostname)) {
      return null;
    }
    if (containsSensitiveUrlData(url)) return null;
    url.hash = '';
    return url.toString();
  } catch {
    return null;
  }
}

function containsSensitiveUrlData(url: URL): boolean {
  if (sensitiveUrlPatterns.some((pattern) => pattern.test(url.hostname) ||
      pattern.test(url.pathname))) {
    return true;
  }
  for (const [name, value] of url.searchParams.entries()) {
    if (isSensitiveUrlParameter(name)) {
      return true;
    }
    if (sensitiveUrlPatterns.some((pattern) => pattern.test(value))) return true;
  }
  return false;
}

function isSensitiveUrlParameter(name: string): boolean {
  const normalized = name.toLowerCase().replace(/[^a-z0-9]/g, '');
  return normalized.includes('cookie') ||
      normalized.includes('authorization') ||
      normalized.includes('apikey') ||
      normalized.includes('token') ||
      normalized.includes('secret') ||
      normalized.includes('credential') ||
      normalized.includes('password') ||
      normalized === 'key' ||
      normalized.endsWith('key');
}

function boundedText(value: unknown, maxLength: number): string {
  if (typeof value !== 'string') return '';
  return value.replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, maxLength);
}

function safeDate(value: unknown): string | null {
  if (typeof value !== 'string' || Number.isNaN(Date.parse(value))) return null;
  return new Date(value).toISOString();
}

function safeRequestId(value: string | undefined): string | undefined {
  return value != null && /^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$/.test(value) ? value : undefined;
}

function headerValue(value: string | string[] | undefined): string | undefined {
  return Array.isArray(value) ? value[0] : value;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value != null && typeof value === 'object' && !Array.isArray(value);
}

function freshnessForBrave(value: string): string | null {
  return ({ day: 'pd', week: 'pw', month: 'pm', year: 'py' } as Record<string, string>)[value] ?? null;
}

function timeRangeForTavily(value: string): string | null {
  return ({ day: 'day', week: 'week', month: 'month', year: 'year' } as Record<string, string>)[value] ?? null;
}

function httpError(statusCode: number): GatewayError {
  if (statusCode === 401) return new GatewayError('UPSTREAM_UNAUTHORIZED', 502, false);
  if (statusCode === 403) return new GatewayError('UPSTREAM_FORBIDDEN', 502, false);
  if (statusCode === 429) return new GatewayError('RATE_LIMITED', 429, true);
  if (statusCode >= 500) return new GatewayError('UPSTREAM_UNAVAILABLE', 502, true);
  return new GatewayError('UPSTREAM_INVALID_RESPONSE', 502, false);
}
