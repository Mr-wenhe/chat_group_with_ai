export interface GatewayConfig {
  requestTimeoutMs: number;
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
