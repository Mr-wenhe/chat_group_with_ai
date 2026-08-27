import { createServer } from 'node:http';
import { pathToFileURL } from 'node:url';

import { loadConfig, requireAuthorized } from './config.ts';
import {
  allowedCorsOrigin,
  asGatewayError,
  header,
  logOutcome,
  parseSearchRequest,
  publicMessage,
  rateLimitKey,
  readJson,
  requestIdFrom,
  writeJson,
  writePreflight,
} from './http_helpers.ts';
import { searchUpstream } from './upstream_client.ts';
import { GatewayError } from './types.ts';
import type { GatewayConfig, GatewaySearchRequest } from './types.ts';

const keepAliveTimeoutMs = 5_000;

export class SlidingWindowRateLimiter {
  private readonly buckets = new Map<string, number[]>();
  // Keep a separate cursor so expiry work is spread across requests instead
  // of scanning every principal on each hot-path consume call.
  private readonly knownKeys: string[] = [];
  private readonly keyIndexes = new Map<string, number>();
  private pruneCursor = 0;
  private readonly maximumRequests: number;
  private readonly windowMs: number;
  private readonly maximumPrincipals: number;
  private readonly clock: () => number;
  private static readonly pruneBudgetPerConsume = 64;

  constructor(
    maximumRequests: number,
    windowMs: number,
    options: {
      maxPrincipals?: number;
      clock?: () => number;
    } = {},
  ) {
    this.maximumRequests = maximumRequests;
    this.windowMs = windowMs;
    this.maximumPrincipals = options.maxPrincipals ?? 10_000;
    this.clock = options.clock ?? Date.now;
  }

  get principalCount(): number {
    return this.buckets.size;
  }

  consume(key: string): boolean {
    const now = this.clock();
    const cutoff = now - this.windowMs;
    this.pruneBudget(cutoff);
    let existing = this.buckets.get(key);
    if (existing != null) {
      const retained = existing.filter((value) => value > cutoff);
      if (retained.length === 0) {
        this.removePrincipal(key);
        existing = undefined;
      } else if (retained.length !== existing.length) {
        existing = retained;
        this.buckets.set(key, retained);
      }
    }
    if (existing == null && this.buckets.size >= this.maximumPrincipals) {
      this.evictOldest();
    }
    const values = (existing ?? []).filter((value) => value > cutoff);
    if (values.length >= this.maximumRequests) {
      this.buckets.set(key, values);
      return false;
    }
    values.push(now);
    this.buckets.set(key, values);
    if (existing == null) this.addPrincipal(key);
    return true;
  }

  private pruneBudget(cutoff: number): void {
    let inspected = 0;
    while (inspected < SlidingWindowRateLimiter.pruneBudgetPerConsume &&
        this.knownKeys.length > 0) {
      if (this.pruneCursor >= this.knownKeys.length) this.pruneCursor = 0;
      const key = this.knownKeys[this.pruneCursor];
      this.pruneCursor++;
      const values = this.buckets.get(key);
      if (values == null) {
        this.removePrincipal(key);
      } else {
        const retained = values.filter((value) => value > cutoff);
        if (retained.length === 0) {
          this.removePrincipal(key);
        } else if (retained.length !== values.length) {
          this.buckets.set(key, retained);
        }
      }
      inspected++;
    }
  }

  private evictOldest(): void {
    // Map insertion order is the principal admission order because existing
    // keys are updated in place. Evicting its first key is O(1) and avoids a
    // second full-principal scan when the cardinality cap is reached.
    const first = this.buckets.keys().next();
    if (!first.done) this.removePrincipal(first.value);
  }

  private addPrincipal(key: string): void {
    if (this.keyIndexes.has(key)) return;
    this.keyIndexes.set(key, this.knownKeys.length);
    this.knownKeys.push(key);
  }

  private removePrincipal(key: string): void {
    this.buckets.delete(key);
    const index = this.keyIndexes.get(key);
    if (index == null) return;
    this.keyIndexes.delete(key);
    const lastIndex = this.knownKeys.length - 1;
    const lastKey = this.knownKeys[lastIndex];
    if (index !== lastIndex) {
      this.knownKeys[index] = lastKey;
      this.keyIndexes.set(lastKey, index);
    }
    this.knownKeys.pop();
    if (this.knownKeys.length === 0) {
      this.pruneCursor = 0;
    } else if (index < this.pruneCursor) {
      this.pruneCursor--;
      if (this.pruneCursor < 0) this.pruneCursor = 0;
    } else if (this.pruneCursor >= this.knownKeys.length) {
      this.pruneCursor = 0;
    }
  }
}

export class UpstreamCircuitBreaker {
  static readonly failureThreshold = 3;
  static readonly openDurationMs = 30_000;
  private readonly clock: () => number;
  private readonly openDurationMs: number;
  private readonly states = new Map<string, {
    consecutiveFailures: number;
    openUntil?: number;
    halfOpen: boolean;
  }>();

  constructor(
    clock: () => number = Date.now,
    openDurationMs = UpstreamCircuitBreaker.openDurationMs,
  ) {
    this.clock = clock;
    this.openDurationMs = openDurationMs;
  }

  canAttempt(provider: string): boolean {
    const state = this.states.get(provider);
    if (state == null) return true;
    const now = this.clock();
    if (state.openUntil == null) return !state.halfOpen;
    if (now < state.openUntil || state.halfOpen) return false;
    state.halfOpen = true;
    return true;
  }

  recordSuccess(provider: string): void {
    this.states.delete(provider);
  }

  recordFailure(provider: string, retryable: boolean): void {
    const current = this.states.get(provider);
    // A half-open probe owns the only retry slot. Any terminal response must
    // release that slot; otherwise one 401/403 or malformed response leaves
    // the provider permanently blocked until the process restarts.
    if (!retryable) {
      // A terminal response breaks the consecutive-retryable-failure streak
      // even while the circuit is closed. Clearing the whole state also
      // releases a half-open probe without carrying stale failures forward.
      this.states.delete(provider);
      return;
    }
    const state = this.states.get(provider) ?? {
      consecutiveFailures: 0,
      halfOpen: false,
    };
    state.consecutiveFailures++;
    state.halfOpen = false;
    if (state.consecutiveFailures >= UpstreamCircuitBreaker.failureThreshold) {
      state.openUntil = this.clock() + this.openDurationMs;
    }
    this.states.set(provider, state);
  }
}

type GatewaySearch = (
  request: GatewaySearchRequest,
  config: GatewayConfig,
  signal?: AbortSignal,
) => ReturnType<typeof searchUpstream>;

type GatewayServerDependencies = {
  search?: GatewaySearch;
};

export function createGatewayServer(
  config: GatewayConfig,
  dependencies: GatewayServerDependencies = {},
) {
  const limiter = new SlidingWindowRateLimiter(config.rateLimitPerMinute, 60_000);
  const quota = new SlidingWindowRateLimiter(config.quotaPerDay, 24 * 60 * 60 * 1000);
  const circuitBreaker = new UpstreamCircuitBreaker();
  // Keep the server dependency seam cancellation-aware while preserving the
  // lower-level transport/address-resolver hooks exposed by searchUpstream.
  const defaultSearch: GatewaySearch = (request, upstreamConfig, signal) =>
      searchUpstream(request, upstreamConfig, undefined, undefined, signal);
  const search = dependencies.search ?? defaultSearch;
  const server = createServer(async (request, response) => {
    const requestId = requestIdFrom(request);
    var corsOrigin: string | undefined;
    try {
      if (request.url?.split('?')[0] !== '/v1/search') {
        throw new GatewayError('NOT_FOUND', 404, false);
      }
      corsOrigin = allowedCorsOrigin(request, config);
      if (request.method === 'OPTIONS') {
        if (header(request, 'access-control-request-method')?.toUpperCase() !== 'POST') {
          throw new GatewayError('NOT_FOUND', 404, false);
        }
        writePreflight(response, corsOrigin);
        logOutcome(requestId, 204);
        return;
      }
      if (request.method !== 'POST') {
        throw new GatewayError('NOT_FOUND', 404, false);
      }
      const principal = requireAuthorized(header(request, 'authorization'), config);
      if (!limiter.consume(rateLimitKey(principal, request))) {
        throw new GatewayError('RATE_LIMITED', 429, true);
      }
      const payload = parseSearchRequest(
        await readJson(request, config.requestTimeoutMs),
        requestId,
      );
      const principalKey = rateLimitKey(principal, request);
      if (!quota.consume(principalKey)) {
        throw new GatewayError('QUOTA_EXCEEDED', 402, false);
      }
      if (!circuitBreaker.canAttempt(config.provider)) {
        throw new GatewayError('UPSTREAM_UNAVAILABLE', 503, true);
      }
      let upstream;
      const upstreamAbort = new AbortController();
      const abortOnRequest = () => upstreamAbort.abort();
      const abortOnResponseClose = () => {
        if (!response.writableEnded) upstreamAbort.abort();
      };
      if (request.aborted) upstreamAbort.abort();
      request.once('aborted', abortOnRequest);
      response.once('close', abortOnResponseClose);
      try {
        upstream = await search(payload, config, upstreamAbort.signal);
        circuitBreaker.recordSuccess(config.provider);
      } catch (error) {
        const safeError = asGatewayError(error);
        circuitBreaker.recordFailure(config.provider, safeError.retryable);
        throw safeError;
      } finally {
        request.removeListener('aborted', abortOnRequest);
        response.removeListener('close', abortOnResponseClose);
      }
      writeJson(response, 200, {
        request_id: payload.requestId,
        provider_request_id: upstream.providerRequestId,
        provider: upstream.provider,
        searched_at: new Date().toISOString(),
        from_cache: false,
        degraded: false,
        results: upstream.results,
      }, corsOrigin);
      logOutcome(payload.requestId, 200);
    } catch (error) {
      const safeError = asGatewayError(error);
      // A body deadline destroys the socket to stop the slow sender. Oversized
      // bodies remain readable and receive a structured 413 response instead
      // of exposing a transport-level connection reset to clients.
      if (response.destroyed ||
          (request.destroyed &&
              safeError.code == 'REQUEST_TIMEOUT')) {
        logOutcome(requestId, safeError.statusCode);
        return;
      }
      // Early authentication/route failures happen before readJson consumes
      // the body. Drain the already-buffered request so the error response can
      // finish cleanly without leaving the parser waiting on the socket.
      if (!request.readableEnded) request.resume();
      writeJson(response, safeError.statusCode, {
        request_id: requestId,
        error: {
          code: safeError.code,
          message: publicMessage(safeError.code),
          retryable: safeError.retryable,
        },
      }, corsOrigin);
      logOutcome(requestId, safeError.statusCode);
    }
  });
  // Node's defaults are intentionally generous for generic HTTP servers. The
  // gateway has a bounded JSON body and a bounded upstream call, so retain the
  // same deadline at every inbound phase.
  server.requestTimeout = Math.max(config.requestTimeoutMs, keepAliveTimeoutMs + 1_000);
  server.headersTimeout = Math.max(config.requestTimeoutMs, keepAliveTimeoutMs + 1_000);
  server.keepAliveTimeout = keepAliveTimeoutMs;
  return server;
}

export function startGateway(): void {
  const config = loadConfig();
  const server = createGatewayServer(config);
  server.listen(config.port, '0.0.0.0', () => {
    console.info(`[search-gateway] listening on port ${config.port}`);
  });
}

if (process.argv[1] != null && pathToFileURL(process.argv[1]).href === import.meta.url) {
  startGateway();
}
