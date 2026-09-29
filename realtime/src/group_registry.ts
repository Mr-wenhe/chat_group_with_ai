/**
 * Registry of shareable groups and their invite codes.
 *
 * A group is created locally in the Flutter app exactly as before; it only
 * reaches this server when the host chooses to invite someone. That keeps
 * every pre-existing local-only group completely unaffected.
 *
 * In-memory, like the room state — see the README's known limitations. Because
 * a restart empties it while guests keep holding a perfectly good `roomId`,
 * [GroupRegistry.ensure] has to be able to rebuild a record for a room it no
 * longer remembers, which is why registration takes an optional `roomId`.
 */

import { randomInt, randomUUID } from 'node:crypto';

/**
 * Deliberately excludes 0/O/1/I/L. Invite codes get read aloud and retyped, so
 * visually ambiguous characters cost more than the entropy is worth.
 */
const inviteAlphabet = '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
const inviteCodeLength = 6;
/** Bounded retry so a full code space fails loudly instead of spinning. */
const maxInviteCodeAttempts = 32;

export interface GroupRecord {
  readonly roomId: string;
  readonly inviteCode: string;
  readonly name: string;
  readonly hostUserId: string;
  readonly hostDisplayName: string;
  readonly createdAt: number;
}

export interface CreateGroupInput {
  readonly name: string;
  readonly hostUserId: string;
  readonly hostDisplayName: string;
  /**
   * 已经共享过的群再次注册时带的房间号，让这次调用变成幂等的。
   *
   * 不带就是"给我一个新房间"，带上就是"保证这个房间在注册表里"——后者是
   * 服务端重启后唯一的修复途径：注册表在内存里，重启即清空，主人手上的邀请码
   * 会静默失效，而客人手里那个 roomId 还是好的（重连时房间会被重新建出来）。
   * 重新分配一个 roomId 会把已经在群里的客人甩到空房间，所以必须沿用。
   */
  readonly roomId?: string;
}

export interface EnsureGroupResult {
  readonly record: GroupRecord;
  /** 这次调用真的新建了记录：新群，或者服务端重启后的重建。 */
  readonly created: boolean;
}

export interface GroupRegistry {
  ensure(input: CreateGroupInput, now: number): EnsureGroupResult;
  findByInviteCode(inviteCode: string): GroupRecord | null;
  findByRoomId(roomId: string): GroupRecord | null;
  size(): number;
}

export function createGroupRegistry(): GroupRegistry {
  const byRoomId = new Map<string, GroupRecord>();
  const roomIdByInviteCode = new Map<string, string>();

  return {
    ensure(input, now) {
      const requestedRoomId = input.roomId;
      if (requestedRoomId !== undefined) {
        const existing = byRoomId.get(requestedRoomId);
        if (existing !== undefined) {
          // Re-registering a room that is already here. The room id *and* the
          // invite code are both kept: the code may already be in someone's
          // hands, and handing back a different one would break it for no
          // reason. Only the display fields are refreshed, which is what a
          // local rename looks like from here.
          //
          // The host identity is adopted rather than treated as a conflict.
          // A host who reinstalled the app, or restored a backup onto another
          // device, arrives with the room id but a new device-local user id —
          // refusing that would lock the legitimate owner out of their own
          // room forever. Holding the room id is proof enough: it is a v4 UUID
          // that was never typed by a human, and the whole server already sits
          // behind one shared token.
          const refreshed: GroupRecord = {
            ...existing,
            name: input.name,
            hostUserId: input.hostUserId,
            hostDisplayName: input.hostDisplayName,
          };
          byRoomId.set(requestedRoomId, refreshed);
          return { record: refreshed, created: false };
        }
      }

      const inviteCode = generateInviteCode((candidate) => roomIdByInviteCode.has(candidate));
      // The room id is the WebSocket room name and is never typed by a human,
      // so it can be a plain UUID rather than a short code.
      const record: GroupRecord = {
        roomId: requestedRoomId ?? `grp-${randomUUID()}`,
        inviteCode,
        name: input.name,
        hostUserId: input.hostUserId,
        hostDisplayName: input.hostDisplayName,
        createdAt: now,
      };
      byRoomId.set(record.roomId, record);
      roomIdByInviteCode.set(inviteCode, record.roomId);
      return { record, created: true };
    },

    findByInviteCode(inviteCode) {
      // Codes are shown in upper case but a guest may type lower case.
      const roomId = roomIdByInviteCode.get(inviteCode.trim().toUpperCase());
      return roomId === undefined ? null : (byRoomId.get(roomId) ?? null);
    },

    findByRoomId(roomId) {
      return byRoomId.get(roomId) ?? null;
    },

    size: () => byRoomId.size,
  };
}

function generateInviteCode(isTaken: (code: string) => boolean): string {
  for (let attempt = 0; attempt < maxInviteCodeAttempts; attempt += 1) {
    let code = '';
    for (let index = 0; index < inviteCodeLength; index += 1) {
      // randomInt is used rather than Math.random so code generation is not
      // predictable from previously issued codes.
      code += inviteAlphabet[randomInt(inviteAlphabet.length)];
    }
    if (!isTaken(code)) return code;
  }
  throw new Error('unable to allocate a unique invite code');
}
