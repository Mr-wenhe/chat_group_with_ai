/**
 * Small HTTP API that backs the invite flow.
 *
 * Group *creation* stays in the Flutter client, exactly as it is today — a
 * group is a local Hive record and most groups are never shared. This API is
 * only reached when a host decides to invite someone, which is what "sharing a
 * group" means: register it here, get back a short code a human can read aloud.
 *
 *   POST /v1/groups             -> register a local group, returns an invite code
 *   GET  /v1/groups/{code}      -> resolve an invite code to a room
 *
 * Both require the same shared token as the WebSocket upgrade.
 *
 * POST is idempotent when the body carries a `roomId`: registering a room that
 * is already known returns the same room and the same code (200, not 201).
 */

import type { IncomingMessage, ServerResponse } from 'node:http';
import { isAuthorized } from './config.ts';
import type { GroupRecord, GroupRegistry } from './group_registry.ts';
import {
  maxDisplayNameLength,
  maxGroupNameLength,
  maxRoomIdLength,
  maxUserIdLength,
} from './protocol.ts';
import type { RealtimeConfig } from './types.ts';

/** A create request is three short strings; anything larger is not one. */
const maxRequestBodyBytes = 8 * 1024;

const groupsPath = '/v1/groups';

/**
 * Returns true when the request was handled. An unhandled request falls through
 * to the caller's own routing (health check, 404).
 */
export type GroupApiHandler = (
  request: IncomingMessage,
  response: ServerResponse,
) => Promise<boolean>;

export function createGroupApiHandler(
  registry: GroupRegistry,
  config: RealtimeConfig,
): GroupApiHandler {
  return async (request, response) => {
    const url = new URL(request.url ?? '/', 'http://placeholder');
    if (url.pathname !== groupsPath && !url.pathname.startsWith(`${groupsPath}/`)) {
      return false;
    }
    if (!isAuthorized(readToken(request, url), config)) {
      sendJson(response, 401, { error: 'UNAUTHORIZED' });
      return true;
    }

    if (url.pathname === groupsPath) {
      if (request.method !== 'POST') {
        sendJson(response, 405, { error: 'METHOD_NOT_ALLOWED' }, { allow: 'POST' });
        return true;
      }
      await handleCreateGroup(request, response, registry);
      return true;
    }

    // /v1/groups/{inviteCode}
    let inviteCode: string;
    try {
      inviteCode = decodeURIComponent(url.pathname.slice(groupsPath.length + 1));
    } catch {
      // decodeURIComponent throws on a stray '%'; that is a malformed request,
      // not a server bug, so it must not escape as an unhandled rejection.
      sendJson(response, 400, { error: 'BAD_REQUEST' });
      return true;
    }
    if (inviteCode.includes('/')) {
      sendJson(response, 404, { error: 'NOT_FOUND' });
      return true;
    }
    if (request.method !== 'GET') {
      sendJson(response, 405, { error: 'METHOD_NOT_ALLOWED' }, { allow: 'GET' });
      return true;
    }
    const record = registry.findByInviteCode(inviteCode);
    if (record === null) {
      // Deliberately indistinguishable from a malformed code: probing for valid
      // codes should not be cheaper than guessing them.
      sendJson(response, 404, { error: 'GROUP_NOT_FOUND' });
      return true;
    }
    sendJson(response, 200, toWire(record));
    return true;
  };
}

async function handleCreateGroup(
  request: IncomingMessage,
  response: ServerResponse,
  registry: GroupRegistry,
): Promise<void> {
  const body = await readJsonBody(request);
  if (!body.ok) {
    sendJson(response, body.status, { error: body.error });
    return;
  }

  const name = readBoundedString(body.value.name, maxGroupNameLength);
  const hostUserId = readBoundedString(body.value.hostUserId, maxUserIdLength);
  const hostDisplayName = readBoundedString(body.value.hostDisplayName, maxDisplayNameLength);
  if (name === null || hostUserId === null || hostDisplayName === null) {
    sendJson(response, 400, {
      error: 'BAD_REQUEST',
      message: 'name, hostUserId and hostDisplayName must be non-empty bounded strings',
    });
    return;
  }

  // Optional, and absent for a group that is being shared for the first time.
  // Present means "make sure *this* room is registered", which is how a host
  // repairs an invite code that a server restart invalidated. An explicit
  // `null` is rejected rather than treated as absent so a client that means to
  // repair a room cannot silently end up creating a second one.
  const roomId = readOptionalBoundedString(body.value.roomId, maxRoomIdLength);
  if (roomId === null) {
    sendJson(response, 400, {
      error: 'BAD_REQUEST',
      message: 'roomId, when present, must be a non-empty bounded string',
    });
    return;
  }

  const { record, created } = registry.ensure(
    { name, hostUserId, hostDisplayName, ...(roomId === undefined ? {} : { roomId }) },
    Date.now(),
  );
  // 200 rather than 201 when nothing was created: re-registering a room that is
  // already known is a no-op apart from its display fields.
  sendJson(response, created ? 201 : 200, toWire(record));
}

/** The client-facing projection of a group. `createdAt` is informational only. */
function toWire(record: GroupRecord): Record<string, unknown> {
  return {
    roomId: record.roomId,
    inviteCode: record.inviteCode,
    name: record.name,
    hostUserId: record.hostUserId,
    hostDisplayName: record.hostDisplayName,
    createdAt: record.createdAt,
  };
}

/**
 * Accepts the token either as a bearer header or a query parameter. The header
 * is preferred; the query form exists because the WebSocket upgrade already
 * uses it, so a client can carry one credential shape for both.
 */
function readToken(request: IncomingMessage, url: URL): string | null {
  const header = request.headers.authorization;
  if (typeof header === 'string' && header.toLowerCase().startsWith('bearer ')) {
    return header.slice('bearer '.length).trim();
  }
  return url.searchParams.get('token');
}

type BodyResult =
  | { readonly ok: true; readonly value: Record<string, unknown> }
  | { readonly ok: false; readonly status: number; readonly error: string };

function readJsonBody(request: IncomingMessage): Promise<BodyResult> {
  return new Promise((resolve) => {
    const chunks: Buffer[] = [];
    let bytes = 0;
    let settled = false;
    const finish = (result: BodyResult) => {
      if (settled) return;
      settled = true;
      resolve(result);
    };

    request.on('data', (chunk: Buffer) => {
      // Once settled the remaining body is drained but never buffered, so an
      // oversized upload costs a bounded amount of memory. Destroying the
      // socket instead would take the 413 response down with it.
      if (settled) return;
      bytes += chunk.length;
      if (bytes > maxRequestBodyBytes) {
        finish({ ok: false, status: 413, error: 'PAYLOAD_TOO_LARGE' });
        return;
      }
      chunks.push(chunk);
    });
    request.on('error', () => finish({ ok: false, status: 400, error: 'BAD_REQUEST' }));
    request.on('end', () => {
      if (settled) return;
      let decoded: unknown;
      try {
        decoded = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      } catch {
        finish({ ok: false, status: 400, error: 'MALFORMED_JSON' });
        return;
      }
      if (typeof decoded !== 'object' || decoded === null || Array.isArray(decoded)) {
        finish({ ok: false, status: 400, error: 'BAD_REQUEST' });
        return;
      }
      finish({ ok: true, value: decoded as Record<string, unknown> });
    });
  });
}

/**
 * Like [readBoundedString], but `undefined` means "the field was not sent" and
 * is allowed through. Returns `null` for a value that was sent but is not a
 * usable string, so the caller can tell "absent" from "invalid" — collapsing
 * the two would let a malformed `roomId` quietly create a brand new room.
 */
function readOptionalBoundedString(value: unknown, maxLength: number): string | undefined | null {
  if (value === undefined) return undefined;
  return readBoundedString(value, maxLength);
}

function readBoundedString(value: unknown, maxLength: number): string | null {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  if (trimmed.length === 0 || trimmed.length > maxLength) return null;
  return trimmed;
}

function sendJson(
  response: ServerResponse,
  status: number,
  payload: Record<string, unknown>,
  extraHeaders: Record<string, string> = {},
): void {
  const body = JSON.stringify(payload);
  response.writeHead(status, {
    'content-type': 'application/json',
    'cache-control': 'no-store',
    'content-length': Buffer.byteLength(body),
    ...extraHeaders,
  });
  response.end(body);
}
