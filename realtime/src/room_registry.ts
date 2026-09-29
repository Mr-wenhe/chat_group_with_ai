/**
 * In-memory room state: membership, message ordering, and a short replay buffer.
 *
 * This module is transport agnostic — it never touches a socket. The server
 * maps an opaque connection id to a live socket and calls in here, which keeps
 * the ordering rules unit-testable without opening a port.
 *
 * The sequence counter is the reason this server exists at all: with several
 * clients writing to one room, the server is the single place that decides
 * message order.
 */

import type { ChatMessage, Member, Speaker } from './protocol.ts';

export interface RoomMember extends Member {
  readonly connectionId: string;
}

export interface JoinOutcome {
  readonly roomId: string;
  /** Highest sequence assigned in the room so far; 0 when empty. */
  readonly seq: number;
  readonly members: readonly Member[];
  /** Most recent messages, oldest first, for a late joiner to catch up on. */
  readonly recent: readonly ChatMessage[];
}

export interface RegistryOptions {
  /** How many messages per room to keep for catch-up replay. */
  readonly recentLimit: number;
}

export interface RoomRegistry {
  join(roomId: string, connectionId: string, member: Member): JoinOutcome;
  /** Returns the remaining members, or null when the room no longer exists. */
  leave(connectionId: string): { roomId: string; member: Member; members: readonly Member[] } | null;
  /**
   * Appends a message, assigning the next sequence number.
   *
   * `speaker` is set by the client when the words belong to someone other than
   * the sending account (the host speaking for an AI character). The registry
   * stores it verbatim; it is not an identity claim the server can verify.
   */
  append(
    connectionId: string,
    text: string,
    sentAt: number,
    speaker?: Speaker,
  ): ChatMessage | null;
  membersOf(roomId: string): readonly Member[];
  /** Connection ids currently in the room, used to fan a broadcast out. */
  connectionsIn(roomId: string): readonly string[];
  roomOf(connectionId: string): string | undefined;
  isEmpty(roomId: string): boolean;
}

interface RoomState {
  seq: number;
  members: Map<string, RoomMember>;
  recent: ChatMessage[];
}

export function createRoomRegistry(options: RegistryOptions): RoomRegistry {
  const rooms = new Map<string, RoomState>();
  /** connectionId -> roomId, so `say`/`leave` need no room argument. */
  const roomByConnection = new Map<string, string>();

  function membersOf(roomId: string): readonly Member[] {
    const room = rooms.get(roomId);
    if (!room) return [];
    return [...room.members.values()].map(({ userId, displayName }) => ({
      userId,
      displayName,
    }));
  }

  return {
    join(roomId, connectionId, member) {
      let room = rooms.get(roomId);
      if (!room) {
        room = { seq: 0, members: new Map(), recent: [] };
        rooms.set(roomId, room);
      }
      room.members.set(connectionId, { ...member, connectionId });
      roomByConnection.set(connectionId, roomId);
      return {
        roomId,
        seq: room.seq,
        members: membersOf(roomId),
        recent: [...room.recent],
      };
    },

    leave(connectionId) {
      const roomId = roomByConnection.get(connectionId);
      if (roomId === undefined) return null;
      roomByConnection.delete(connectionId);

      const room = rooms.get(roomId);
      if (!room) return null;
      const member = room.members.get(connectionId);
      room.members.delete(connectionId);
      // Drop the room entirely once the last member leaves; the demo has no
      // persistence requirement, and keeping empty rooms would leak memory.
      if (room.members.size === 0) rooms.delete(roomId);
      if (!member) return null;

      return {
        roomId,
        member: { userId: member.userId, displayName: member.displayName },
        members: membersOf(roomId),
      };
    },

    append(connectionId, text, sentAt, speaker) {
      const roomId = roomByConnection.get(connectionId);
      if (roomId === undefined) return null;
      const room = rooms.get(roomId);
      const member = room?.members.get(connectionId);
      if (!room || !member) return null;

      room.seq += 1;
      const message: ChatMessage = {
        type: 'msg',
        roomId,
        seq: room.seq,
        userId: member.userId,
        displayName: member.displayName,
        text,
        sentAt,
        // Spread rather than `speaker: undefined` so the frame stays identical
        // to the pre-speaker protocol for ordinary member messages.
        ...(speaker === undefined ? {} : { speaker }),
      };
      room.recent.push(message);
      if (room.recent.length > options.recentLimit) {
        room.recent.splice(0, room.recent.length - options.recentLimit);
      }
      return message;
    },

    membersOf,
    connectionsIn: (roomId) => [...(rooms.get(roomId)?.members.keys() ?? [])],
    roomOf: (connectionId) => roomByConnection.get(connectionId),
    isEmpty: (roomId) => !rooms.has(roomId),
  };
}
