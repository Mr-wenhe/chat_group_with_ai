export interface RealtimeConfig {
  readonly port: number;
  /** Null only when the unauthenticated development bypass is active. */
  readonly sharedToken: string | null;
  readonly allowUnauthenticatedDevelopment: boolean;
  readonly heartbeatIntervalMs: number;
  /** How long a socket may stay connected without sending `join`. */
  readonly joinTimeoutMs: number;
  readonly recentMessageLimit: number;
  readonly maxConnectionsPerRoom: number;
}
