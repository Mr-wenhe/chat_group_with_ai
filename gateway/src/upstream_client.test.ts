import assert from 'node:assert/strict';
import test from 'node:test';

import { searchUpstream } from './upstream_client.ts';
import type { GatewayConfig, GatewaySearchRequest } from './types.ts';

const baseRequest: GatewaySearchRequest = {
  requestId: 'request-001',
  query: 'Flutter release notes',
  category: 'software',
  freshness: 'month',
  locale: 'en-US',
  country: 'US',
  maxResults: 2,
  safeSearch: true,
  forceRefresh: false,
};

const baseConfig: GatewayConfig = {
  port: 8080,
  provider: 'brave',
  providerApiKey: 'server-only-key',
  apiTokens: new Set(['client-token']),
  allowedOrigins: new Set(),
  allowUnauthenticatedDevelopment: false,
  requestTimeoutMs: 1000,
  rateLimitPerMinute: 60,
};

test('Brave transport is fixed, safe, and normalized before returning to clients',
    async () => {
  let capturedUrl: URL | undefined;
  let capturedHeaders: Record<string, string> | undefined;
  const result = await searchUpstream(
    baseRequest,
    baseConfig,
    async (url, options) => {
      capturedUrl = url;
      capturedHeaders = options.headers;
      return {
        statusCode: 200,
        headers: {'x-request-id': 'brave-request-001'},
        body: {
          web: {
            results: [
              {title: 'Flutter', url: 'https://docs.flutter.dev', description: 'Official'},
              {title: 'Duplicate', url: 'https://docs.flutter.dev', description: 'Ignored'},
              {title: 'Unsafe', url: 'file:///etc/passwd', description: 'Ignored'},
            ],
          },
        },
      };
    },
    async () => ['8.8.8.8'],
  );

  assert.equal(capturedUrl?.origin, 'https://api.search.brave.com');
  assert.equal(capturedUrl?.pathname, '/res/v1/web/search');
  assert.equal(capturedUrl?.searchParams.get('safesearch'), 'moderate');
  assert.equal(capturedHeaders?.['X-Subscription-Token'], 'server-only-key');
  assert.deepEqual(result, {
    providerRequestId: 'brave-request-001',
    provider: 'brave',
    results: [{title: 'Flutter', url: 'https://docs.flutter.dev/', snippet: 'Official'}],
  });
});

test('Tavily transport normalizes its result shape without exposing its key',
    async () => {
  let capturedBody: string | undefined;
  const result = await searchUpstream(
    {...baseRequest, category: 'news'},
    {...baseConfig, provider: 'tavily', providerApiKey: 'tavily-server-key'},
    async (url, options) => {
      assert.equal(url.toString(), 'https://api.tavily.com/search');
      capturedBody = options.body;
      assert.equal(options.headers.Authorization, 'Bearer tavily-server-key');
      return {
        statusCode: 200,
        headers: {},
        body: {
          results: [{
            title: 'Flutter news',
            url: 'https://docs.flutter.dev/news',
            content: 'News content',
            published_date: '2026-08-23T00:00:00Z',
          }],
        },
      };
    },
    async () => ['8.8.8.8'],
  );

  assert.deepEqual(JSON.parse(capturedBody ?? '{}'), {
    query: 'Flutter release notes',
    search_depth: 'basic',
    max_results: 2,
    topic: 'news',
    include_answer: false,
    include_raw_content: false,
    include_images: false,
    include_image_descriptions: false,
    include_favicon: false,
    auto_parameters: false,
    time_range: 'month',
  });
  assert.equal(result.results[0]?.snippet, 'News content');
});

test('insecure HTTP result URLs are discarded', async () => {
  const result = await searchUpstream(
    baseRequest,
    baseConfig,
    async () => ({
      statusCode: 200,
      headers: {},
      body: {
        web: {
          results: [
            {title: 'Insecure', url: 'http://public.example/article'},
          ],
        },
      },
    }),
    async () => ['8.8.8.8'],
  );

  assert.deepEqual(result.results, []);
});

test('credential-like result URLs are discarded', async () => {
  const result = await searchUpstream(
    baseRequest,
    baseConfig,
    async () => ({
      statusCode: 200,
      headers: {},
      body: {
        web: {
          results: [
            {
              title: 'Query credential',
              url: 'https://public.example/article?api_key=sk-test-12345678',
            },
            {
              title: 'Path credential',
              url: 'https://public.example/sk-live-token1234/article',
            },
          ],
        },
      },
    }),
    async () => ['8.8.8.8'],
  );

  assert.deepEqual(result.results, []);
});

test('DNS resolution is bounded by the Gateway request timeout', async () => {
  await assert.rejects(
    Promise.race([
      searchUpstream(
        baseRequest,
        {...baseConfig, requestTimeoutMs: 20},
        async () => {
          throw new Error('transport must not run after DNS timeout');
        },
        async () => new Promise<string[]>(() => {}),
      ),
      new Promise<never>((_, reject) =>
        setTimeout(() => reject(new Error('test timeout')), 100),
      ),
    ]),
    (error: unknown) =>
      error instanceof Error && error.message === 'UPSTREAM_DNS_TIMEOUT',
  );
});

test('an empty DNS answer fails before transport setup', async () => {
  let transportCalled = false;
  await assert.rejects(
    searchUpstream(
      baseRequest,
      baseConfig,
      async () => {
        transportCalled = true;
        throw new Error('transport must not run');
      },
      async () => [],
    ),
    (error: unknown) =>
      error instanceof Error && error.message === 'UPSTREAM_DNS_FAILED',
  );
  assert.equal(transportCalled, false);
});

test('an uncooperative upstream transport is bounded by an absolute timeout',
    async () => {
  await assert.rejects(
    Promise.race([
      searchUpstream(
        baseRequest,
        {...baseConfig, requestTimeoutMs: 20},
        async (_url, options) => new Promise((_, reject) => {
          options.signal?.addEventListener('abort', () => reject(new Error('aborted')), {
            once: true,
          });
        }),
        async () => ['8.8.8.8'],
      ),
      new Promise<never>((_, reject) =>
        setTimeout(() => reject(new Error('test timeout')), 100),
      ),
    ]),
    (error: unknown) =>
      error instanceof Error && error.message === 'UPSTREAM_TIMEOUT',
  );
});
