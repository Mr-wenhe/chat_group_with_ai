import { strict as assert } from 'node:assert';
import { describe, it } from 'node:test';
import { createRoomRegistry } from './room_registry.ts';

const member = (userId: string) => ({ userId, displayName: `name-${userId}` });

describe('createRoomRegistry', () => {
  it('joins a room and reports an empty room with sequence zero', () => {
    const registry = createRoomRegistry({ recentLimit: 10 });
    const outcome = registry.join('room-a', 'conn-1', member('alice'));

    assert.equal(outcome.roomId, 'room-a');
    assert.equal(outcome.seq, 0);
    assert.deepEqual(outcome.members, [{ userId: 'alice', displayName: 'name-alice' }]);
    assert.deepEqual(outcome.recent, []);
  });

  it('assigns strictly increasing sequence numbers across members', () => {
    const registry = createRoomRegistry({ recentLimit: 10 });
    registry.join('room-a', 'conn-1', member('alice'));
    registry.join('room-a', 'conn-2', member('bob'));

    const first = registry.append('conn-1', 'hello', 1000);
    const second = registry.append('conn-2', 'hi', 1001);

    assert.equal(first?.seq, 1);
    assert.equal(second?.seq, 2);
    assert.equal(second?.userId, 'bob');
    assert.equal(second?.displayName, 'name-bob');
    assert.equal(second?.sentAt, 1001);
  });

  it('keeps sequence numbers independent between rooms', () => {
    const registry = createRoomRegistry({ recentLimit: 10 });
    registry.join('room-a', 'conn-1', member('alice'));
    registry.join('room-b', 'conn-2', member('bob'));

    assert.equal(registry.append('conn-1', 'a', 1)?.seq, 1);
    assert.equal(registry.append('conn-2', 'b', 2)?.seq, 1);
  });

  it('rejects a say from a connection that never joined', () => {
    const registry = createRoomRegistry({ recentLimit: 10 });
    assert.equal(registry.append('conn-unknown', 'hello', 1), null);
  });

  it('attaches a speaker while keeping the relaying account as the sender', () => {
    const registry = createRoomRegistry({ recentLimit: 10 });
    registry.join('room-a', 'conn-1', member('alice'));

    const message = registry.append('conn-1', '在的', 1000, {
      id: 'char-1',
      name: '小明',
    });

    assert.deepEqual(message?.speaker, { id: 'char-1', name: '小明' });
    // The host is still the account that sent it; guests need both.
    assert.equal(message?.userId, 'alice');
  });

  it('leaves the speaker key off messages from ordinary members', () => {
    const registry = createRoomRegistry({ recentLimit: 10 });
    registry.join('room-a', 'conn-1', member('alice'));

    const message = registry.append('conn-1', 'hello', 1000);
    assert.equal(message !== null && 'speaker' in message, false);
  });

  it('replays the speaker to a late joiner', () => {
    const registry = createRoomRegistry({ recentLimit: 10 });
    registry.join('room-a', 'conn-1', member('alice'));
    registry.append('conn-1', '在的', 1000, { id: 'char-1', name: '小明' });

    const outcome = registry.join('room-a', 'conn-2', member('bob'));
    assert.deepEqual(outcome.recent[0]?.speaker, { id: 'char-1', name: '小明' });
  });

  it('bounds the replay buffer and evicts the oldest messages', () => {
    const registry = createRoomRegistry({ recentLimit: 2 });
    registry.join('room-a', 'conn-1', member('alice'));
    registry.append('conn-1', 'one', 1);
    registry.append('conn-1', 'two', 2);
    registry.append('conn-1', 'three', 3);

    const outcome = registry.join('room-a', 'conn-2', member('bob'));
    assert.deepEqual(
      outcome.recent.map((message) => message.text),
      ['two', 'three'],
    );
  });

  it('reports remaining members on leave and drops the room when empty', () => {
    const registry = createRoomRegistry({ recentLimit: 10 });
    registry.join('room-a', 'conn-1', member('alice'));
    registry.join('room-a', 'conn-2', member('bob'));

    const departed = registry.leave('conn-1');
    assert.equal(departed?.roomId, 'room-a');
    assert.equal(departed?.member.userId, 'alice');
    assert.deepEqual(departed?.members, [{ userId: 'bob', displayName: 'name-bob' }]);
    assert.equal(registry.isEmpty('room-a'), false);

    registry.leave('conn-2');
    assert.equal(registry.isEmpty('room-a'), true);
  });

  it('returns null when leaving without ever joining', () => {
    const registry = createRoomRegistry({ recentLimit: 10 });
    assert.equal(registry.leave('conn-unknown'), null);
  });

  it('starts a fresh room once the previous one emptied', () => {
    // Documents a deliberate demo-level limitation: state is in-memory only, so
    // sequence numbers restart after the last member leaves.
    const registry = createRoomRegistry({ recentLimit: 10 });
    registry.join('room-a', 'conn-1', member('alice'));
    registry.append('conn-1', 'hello', 1);
    registry.leave('conn-1');

    const outcome = registry.join('room-a', 'conn-2', member('bob'));
    assert.equal(outcome.seq, 0);
  });

  it('lists the connections in a room for broadcasting', () => {
    const registry = createRoomRegistry({ recentLimit: 10 });
    registry.join('room-a', 'conn-1', member('alice'));
    registry.join('room-a', 'conn-2', member('bob'));

    assert.deepEqual([...registry.connectionsIn('room-a')].sort(), ['conn-1', 'conn-2']);
    assert.deepEqual(registry.connectionsIn('room-missing'), []);
  });
});
