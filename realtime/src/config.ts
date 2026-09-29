import type { RealtimeConfig } from './types.ts';

const minPort = 1;
const maxPort = 65535;
const minHeartbeatMs = 5000;
const maxHeartbeatMs = 300000;
const minJoinTimeoutMs = 1000;
const maxJoinTimeoutMs = 60000;
const minRecentLimit = 0;
const maxRecentLimit = 1000;
const minRoomCapacity = 1;
const maxRoomCapacity = 10000;

export function loadConfig(env: NodeJS.ProcessEnv = process.env): RealtimeConfig {
  const sharedToken = env.REALTIME_SHARED_TOKEN?.trim() ?? '';
  const allowUnauthenticatedDevelopment =
    env.NODE_ENV !== 'production' && env.ALLOW_UNAUTHENTICATED_DEV === 'true';
  if (sharedToken.length === 0 && !allowUnauthenticatedDevelopment) {
    throw new Error(
      'REALTIME_SHARED_TOKEN is required unless explicit development bypass is enabled',
    );
  }

  return {
    // Not 9100: that is Dart DevTools' default port, and on a developer machine
    // a running DevTools binds 127.0.0.1:9100 without conflicting with our
    // 0.0.0.0 bind, silently swallowing local connections.
    port: readBoundedInt(env.PORT, 9210, minPort, maxPort, 'PORT'),
    sharedToken: sharedToken.length > 0 ? sharedToken : null,
    allowUnauthenticatedDevelopment,
    heartbeatIntervalMs: readBoundedInt(
      env.HEARTBEAT_INTERVAL_MS,
      30000,
      minHeartbeatMs,
      maxHeartbeatMs,
      'HEARTBEAT_INTERVAL_MS',
    ),
    joinTimeoutMs: readBoundedInt(
      env.JOIN_TIMEOUT_MS,
      10000,
      minJoinTimeoutMs,
      maxJoinTimeoutMs,
      'JOIN_TIMEOUT_MS',
    ),
    recentMessageLimit: readBoundedInt(
      env.RECENT_MESSAGE_LIMIT,
      50,
      minRecentLimit,
      maxRecentLimit,
      'RECENT_MESSAGE_LIMIT',
    ),
    maxConnectionsPerRoom: readBoundedInt(
      env.MAX_CONNECTIONS_PER_ROOM,
      50,
      minRoomCapacity,
      maxRoomCapacity,
      'MAX_CONNECTIONS_PER_ROOM',
    ),
  };
}

/**
 * Constant-time-ish token comparison. The demo's threat model is "keep random
 * internet scanners out", not "resist a timing oracle", but comparing without
 * an early return costs nothing here.
 */
export function isAuthorized(token: string | null, config: RealtimeConfig): boolean {
  if (config.allowUnauthenticatedDevelopment) return true;
  if (config.sharedToken === null || token === null) return false;
  if (token.length !== config.sharedToken.length) return false;
  let mismatch = 0;
  for (let i = 0; i < token.length; i += 1) {
    mismatch |= token.charCodeAt(i) ^ config.sharedToken.charCodeAt(i);
  }
  return mismatch === 0;
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
