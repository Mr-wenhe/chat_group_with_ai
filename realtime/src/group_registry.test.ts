import { strict as assert } from 'node:assert';
import { describe, it } from 'node:test';
import { createGroupRegistry } from './group_registry.ts';

const host = { name: '数学建模小组', hostUserId: 'user-a', hostDisplayName: '张三' };

/** Mirrors the alphabet in group_registry.ts, minus the ambiguous characters. */
const unambiguousAlphabet = '23456789ABCDEFGHJKMNPQRSTUVWXYZ';

describe('createGroupRegistry', () => {
  it('issues a six-character invite code', () => {
    const registry = createGroupRegistry();
    const { record, created } = registry.ensure(host, 1000);

    assert.equal(record.inviteCode.length, 6);
    assert.equal(record.name, '数学建模小组');
    assert.equal(record.hostUserId, 'user-a');
    assert.equal(record.hostDisplayName, '张三');
    assert.equal(record.createdAt, 1000);
    assert.equal(created, true);
  });

  it('never issues a visually ambiguous character', () => {
    const registry = createGroupRegistry();
    for (let i = 0; i < 200; i += 1) {
      for (const character of registry.ensure(host, i).record.inviteCode) {
        assert.ok(
          unambiguousAlphabet.includes(character),
          `invite code contained ${character}, which is not in the unambiguous alphabet`,
        );
      }
    }
  });

  it('never issues the same invite code twice', () => {
    const registry = createGroupRegistry();
    const codes = new Set<string>();
    for (let i = 0; i < 500; i += 1) codes.add(registry.ensure(host, i).record.inviteCode);
    assert.equal(codes.size, 500);
  });

  it('never issues the same room id twice', () => {
    const registry = createGroupRegistry();
    const roomIds = new Set<string>();
    for (let i = 0; i < 500; i += 1) roomIds.add(registry.ensure(host, i).record.roomId);
    assert.equal(roomIds.size, 500);
  });

  it('resolves a code regardless of case or surrounding whitespace', () => {
    const registry = createGroupRegistry();
    const { record } = registry.ensure(host, 1000);

    assert.equal(registry.findByInviteCode(record.inviteCode)?.roomId, record.roomId);
    assert.equal(registry.findByInviteCode(record.inviteCode.toLowerCase())?.roomId, record.roomId);
    assert.equal(registry.findByInviteCode(`  ${record.inviteCode}  `)?.roomId, record.roomId);
  });

  it('returns null for a code that was never issued', () => {
    const registry = createGroupRegistry();
    registry.ensure(host, 1000);
    assert.equal(registry.findByInviteCode('ZZZZZZ'), null);
  });

  it('resolves a room by its own id', () => {
    const registry = createGroupRegistry();
    const { record } = registry.ensure(host, 1000);
    assert.equal(registry.findByRoomId(record.roomId)?.inviteCode, record.inviteCode);
    assert.equal(registry.findByRoomId('grp-nope'), null);
  });

  it('reports how many groups it holds', () => {
    const registry = createGroupRegistry();
    assert.equal(registry.size(), 0);
    registry.ensure(host, 1000);
    assert.equal(registry.size(), 1);
  });
});

describe('createGroupRegistry re-registration', () => {
  it('honours a requested room id and reports it as created', () => {
    const registry = createGroupRegistry();
    const { record, created } = registry.ensure({ ...host, roomId: 'grp-fixed' }, 1000);

    assert.equal(record.roomId, 'grp-fixed');
    assert.equal(created, true);
    assert.equal(registry.findByRoomId('grp-fixed')?.inviteCode, record.inviteCode);
  });

  it('keeps the room and the code when the same room is registered again', () => {
    const registry = createGroupRegistry();
    const first = registry.ensure({ ...host, roomId: 'grp-fixed' }, 1000);

    const second = registry.ensure({ ...host, roomId: 'grp-fixed' }, 2000);

    assert.equal(second.created, false);
    assert.equal(second.record.inviteCode, first.record.inviteCode);
    assert.equal(second.record.roomId, 'grp-fixed');
    assert.equal(registry.size(), 1);
  });

  it('refreshes the display fields but not the creation time', () => {
    const registry = createGroupRegistry();
    registry.ensure({ ...host, roomId: 'grp-fixed' }, 1000);

    const renamed = registry.ensure(
      { ...host, name: '数学建模小组（新）', roomId: 'grp-fixed' },
      2000,
    );

    assert.equal(renamed.record.name, '数学建模小组（新）');
    assert.equal(renamed.record.createdAt, 1000);
  });

  it('adopts a new host identity, which is what a restored backup looks like', () => {
    const registry = createGroupRegistry();
    const first = registry.ensure({ ...host, roomId: 'grp-fixed' }, 1000);

    const restored = registry.ensure(
      { ...host, hostUserId: 'user-b', hostDisplayName: '李四', roomId: 'grp-fixed' },
      2000,
    );

    assert.equal(restored.created, false);
    assert.equal(restored.record.hostUserId, 'user-b');
    // The code in the old host's hands still has to work.
    assert.equal(restored.record.inviteCode, first.record.inviteCode);
    assert.equal(registry.findByInviteCode(first.record.inviteCode)?.hostUserId, 'user-b');
  });

  it('mints a fresh code for the same room after a restart wipes the registry', () => {
    const before = createGroupRegistry();
    const stale = before.ensure({ ...host, roomId: 'grp-fixed' }, 1000);

    // A new registry is exactly what a process restart leaves behind.
    const restarted = createGroupRegistry();
    const repaired = restarted.ensure({ ...host, roomId: 'grp-fixed' }, 2000);

    assert.equal(repaired.created, true);
    // Same room, so guests already pointed at it are not stranded...
    assert.equal(repaired.record.roomId, 'grp-fixed');
    // ...but the code the host read aloud is gone, which is why the client has
    // to compare and tell the host it changed.
    assert.notEqual(repaired.record.inviteCode, stale.record.inviteCode);
    assert.equal(restarted.findByInviteCode(stale.record.inviteCode), null);
  });

  it('leaves an unrelated room alone when repairing one', () => {
    const registry = createGroupRegistry();
    const other = registry.ensure(host, 1000);
    const target = registry.ensure({ ...host, roomId: 'grp-fixed' }, 1000);

    const repaired = registry.ensure({ ...host, roomId: 'grp-fixed' }, 2000);

    assert.equal(repaired.record.inviteCode, target.record.inviteCode);
    assert.equal(registry.findByRoomId(other.record.roomId)?.inviteCode, other.record.inviteCode);
    assert.equal(registry.size(), 2);
  });
});
