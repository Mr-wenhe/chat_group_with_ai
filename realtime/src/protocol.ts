/**
 * Wire protocol between the realtime server and its clients.
 *
 * The Dart client mirrors these shapes by hand (see
 * `lib/features/realtime/realtime_protocol.dart`); keep the two in sync.
 */

export const maxRoomIdLength = 128;
export const maxUserIdLength = 128;
export const maxDisplayNameLength = 64;
export const maxTextLength = 4000;
export const maxGroupNameLength = 64;

export interface Member {
  readonly userId: string;
  readonly displayName: string;
}

/**
 * Who actually authored a message, when it is not the account that sent the frame.
 *
 * The host client speaks on behalf of the AI characters it runs: the frame comes
 * from the host's own connection, but the words belong to a character. Without
 * this, every AI reply would show up on guest devices as something the host said.
 * The server never interprets it — it only carries it.
 */
export interface Speaker {
  readonly id: string;
  readonly name: string;
}

/** A chat message as broadcast to every member of a room. */
export interface ChatMessage {
  readonly type: 'msg';
  readonly roomId: string;
  readonly seq: number;
  readonly userId: string;
  readonly displayName: string;
  readonly text: string;
  readonly sentAt: number;
  /** Absent when the relaying account is the author. */
  readonly speaker?: Speaker;
}

export type ClientMessage =
  | {
      readonly type: 'join';
      readonly roomId: string;
      readonly userId: string;
      readonly displayName: string;
    }
  | { readonly type: 'say'; readonly text: string; readonly speaker?: Speaker };

export type ServerMessage =
  | {
      readonly type: 'joined';
      readonly roomId: string;
      readonly seq: number;
      readonly members: readonly Member[];
      readonly recent: readonly ChatMessage[];
    }
  | ChatMessage
  | {
      readonly type: 'presence';
      readonly event: 'join' | 'leave';
      readonly member: Member;
      readonly members: readonly Member[];
    }
  | { readonly type: 'error'; readonly code: string; readonly message: string };

export type ParseResult<T> =
  | { readonly ok: true; readonly value: T }
  | { readonly ok: false; readonly error: string };

/**
 * Parses and validates a raw client frame.
 *
 * Validation is deliberately strict: the server listens on a public address,
 * so a malformed frame must be rejected rather than coerced into a room.
 */
export function parseClientMessage(raw: string): ParseResult<ClientMessage> {
  let decoded: unknown;
  try {
    decoded = JSON.parse(raw);
  } catch {
    return { ok: false, error: 'malformed JSON' };
  }
  if (typeof decoded !== 'object' || decoded === null || Array.isArray(decoded)) {
    return { ok: false, error: 'expected a JSON object' };
  }
  const record = decoded as Record<string, unknown>;

  switch (record.type) {
    case 'join': {
      const roomId = readBoundedString(record.roomId, maxRoomIdLength);
      const userId = readBoundedString(record.userId, maxUserIdLength);
      const displayName = readBoundedString(record.displayName, maxDisplayNameLength);
      if (roomId === null) return { ok: false, error: 'roomId must be a non-empty string' };
      if (userId === null) return { ok: false, error: 'userId must be a non-empty string' };
      if (displayName === null) return { ok: false, error: 'displayName must be a non-empty string' };
      return { ok: true, value: { type: 'join', roomId, userId, displayName } };
    }
    case 'say': {
      if (typeof record.text !== 'string') {
        return { ok: false, error: 'text must be a string' };
      }
      const text = record.text.trim();
      if (text.length === 0) return { ok: false, error: 'text must not be empty' };
      if (text.length > maxTextLength) {
        return { ok: false, error: `text must be at most ${maxTextLength} characters` };
      }
      // `speaker` is optional. When present it must be fully well-formed: a
      // half-specified speaker would be displayed as an unnamed sender.
      if (record.speaker === undefined) {
        return { ok: true, value: { type: 'say', text } };
      }
      const speaker = parseSpeaker(record.speaker);
      if (speaker === null) {
        return { ok: false, error: 'speaker must be an object with id and name' };
      }
      return { ok: true, value: { type: 'say', text, speaker } };
    }
    default:
      return { ok: false, error: 'unknown message type' };
  }
}

/** Returns null for anything that is not a complete, in-bounds speaker. */
export function parseSpeaker(value: unknown): Speaker | null {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return null;
  const record = value as Record<string, unknown>;
  const id = readBoundedString(record.id, maxUserIdLength);
  const name = readBoundedString(record.name, maxDisplayNameLength);
  if (id === null || name === null) return null;
  return { id, name };
}

function readBoundedString(value: unknown, maxLength: number): string | null {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  if (trimmed.length === 0 || trimmed.length > maxLength) return null;
  return trimmed;
}
