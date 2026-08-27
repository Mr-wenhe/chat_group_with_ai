import { GatewayError } from './types.ts';
import type { GatewayConfig, SearchProviderName } from './types.ts';

const providerNames = new Set<SearchProviderName>(['brave', 'tavily']);
const minPort = 1;
const maxPort = 65535;
const minTimeoutMs = 1000;
const maxTimeoutMs = 30000;
const minRateLimit = 1;
const maxRateLimit = 10000;
const minDailyQuota = 1;
const maxDailyQuota = 1000000;

export function loadConfig(env: NodeJS.ProcessEnv = process.env): GatewayConfig {
  const provider = env.SEARCH_PROVIDER?.trim().toLowerCase();
  if (!providerNames.has(provider as SearchProviderName)) {
    throw new Error('SEARCH_PROVIDER must be brave or tavily');
  }
  const selectedProvider = provider as SearchProviderName;
  const providerApiKey = selectedProvider === 'brave'
      ? env.BRAVE_API_KEY?.trim()
      : env.TAVILY_API_KEY?.trim();
  if (!providerApiKey) {
    throw new Error('The selected upstream provider key is required');
  }

  const apiTokens = new Set(
    (env.GATEWAY_API_TOKENS ?? '')
      .split(',')
      .map((value) => value.trim())
      .filter((value) => value.length > 0),
  );
  const allowUnauthenticatedDevelopment =
      env.NODE_ENV !== 'production' && env.ALLOW_UNAUTHENTICATED_DEV === 'true';
  if (apiTokens.size === 0 && !allowUnauthenticatedDevelopment) {
    throw new Error(
      'GATEWAY_API_TOKENS is required unless explicit development bypass is enabled',
    );
  }

  return {
    port: readBoundedInt(env.PORT, 8080, minPort, maxPort, 'PORT'),
    provider: selectedProvider,
    providerApiKey,
    apiTokens,
    allowedOrigins: readAllowedOrigins(env.ALLOWED_ORIGINS),
    allowUnauthenticatedDevelopment,
    requestTimeoutMs: readBoundedInt(
      env.REQUEST_TIMEOUT_MS,
      8000,
      minTimeoutMs,
      maxTimeoutMs,
      'REQUEST_TIMEOUT_MS',
    ),
    rateLimitPerMinute: readBoundedInt(
      env.RATE_LIMIT_PER_MINUTE,
      60,
      minRateLimit,
      maxRateLimit,
      'RATE_LIMIT_PER_MINUTE',
    ),
    quotaPerDay: readBoundedInt(
      env.DAILY_QUOTA,
      1000,
      minDailyQuota,
      maxDailyQuota,
      'DAILY_QUOTA',
    ),
  };
}

function readBoundedInt(
  raw: string | undefined,
  fallback: number,
  min: number,
  max: number,
  name: string,
): number {
  if (raw == null || raw.trim().length === 0) return fallback;
  const normalized = raw.trim();
  if (!/^(?:0|[1-9][0-9]*)$/.test(normalized)) {
    throw new Error(`${name} must be an integer between ${min} and ${max}`);
  }
  const parsed = Number.parseInt(normalized, 10);
  if (!Number.isSafeInteger(parsed) || parsed < min || parsed > max) {
    throw new Error(`${name} must be an integer between ${min} and ${max}`);
  }
  return parsed;
}

export function requireAuthorized(
  authorization: string | undefined,
  config: GatewayConfig,
): string | null {
  if (config.allowUnauthenticatedDevelopment) return null;
  const token = authorization?.match(/^Bearer\s+(.+)$/i)?.[1]?.trim() ?? '';
  if (!token || !config.apiTokens.has(token)) {
    throw new GatewayError('UNAUTHORIZED', 401, false);
  }
  return token;
}

function readAllowedOrigins(raw: string | undefined): ReadonlySet<string> {
  if (raw == null || raw.trim().length === 0) return new Set();
  const origins = new Set<string>();
  for (const candidate of raw.split(',')) {
    const value = candidate.trim();
    if (!value) continue;
    let parsed: URL;
    try {
      parsed = new URL(value);
    } catch {
      throw new Error('ALLOWED_ORIGINS must contain valid HTTPS origins only');
    }
    if (parsed.protocol !== 'https:' ||
        parsed.username || parsed.password || parsed.search || parsed.hash ||
        parsed.pathname !== '/') {
      throw new Error('ALLOWED_ORIGINS must contain valid HTTPS origins only');
    }
    origins.add(parsed.origin);
  }
  return origins;
}
