export type SearchProviderName = 'brave' | 'tavily';

export interface GatewayConfig {
  port: number;
  provider: SearchProviderName;
  providerApiKey: string;
  apiTokens: ReadonlySet<string>;
  allowedOrigins: ReadonlySet<string>;
  allowUnauthenticatedDevelopment: boolean;
  requestTimeoutMs: number;
  rateLimitPerMinute: number;
  quotaPerDay: number;
}

export interface GatewaySearchRequest {
  requestId: string;
  query: string;
  category: string;
  freshness: string;
  locale: string;
  country?: string;
  maxResults: number;
  safeSearch: true;
  forceRefresh: boolean;
}

export interface GatewaySearchResult {
  title: string;
  url: string;
  snippet: string;
  published_at?: string;
  score?: number;
  language?: string;
}

export class GatewayError extends Error {
  readonly code: string;
  readonly statusCode: number;
  readonly retryable: boolean;

  constructor(
    code: string,
    statusCode: number,
    retryable: boolean,
  ) {
    super(code);
    this.code = code;
    this.statusCode = statusCode;
    this.retryable = retryable;
  }
}
