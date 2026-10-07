import { strict as assert } from 'node:assert';
import { describe, it } from 'node:test';
import { maxDisplayNameLength, maxTextLength, parseClientMessage } from './protocol.ts';

const joinFrame = JSON.stringify({
  type: 'join',
  roomId: 'group-1',
  userId: 'alice',
  displayName: 'Alice',
});

describe('parseClientMessage', () => {
  it('accepts a well-formed join frame', () => {
    const result = parseClientMessage(joinFrame);
    assert.equal(result.ok, true);
    assert.deepEqual(result.ok && result.value, {
      type: 'join',
      roomId: 'group-1',
      userId: 'alice',
      displayName: 'Alice',
    });
  });

  it('trims surrounding whitespace from a say frame', () => {
    const result = parseClientMessage(JSON.stringify({ type: 'say', text: '  hello  ' }));
    assert.equal(result.ok, true);
    assert.deepEqual(result.ok && result.value, { type: 'say', text: 'hello' });
  });

  it('rejects malformed JSON', () => {
    const result = parseClientMessage('{not json');
    assert.equal(result.ok, false);
    assert.equal(result.ok === false && result.error, 'malformed JSON');
  });

  for (const [label, payload] of [
    ['a JSON array', '[]'],
    ['a JSON string', '"hello"'],
    ['null', 'null'],
  ] as const) {
    it(`rejects ${label}`, () => {
      const result = parseClientMessage(payload);
      assert.equal(result.ok, false);
      assert.equal(result.ok === false && result.error, 'expected a JSON object');
    });
  }

  it('rejects an unknown message type', () => {
    const result = parseClientMessage(JSON.stringify({ type: 'shout', text: 'hi' }));
    assert.equal(result.ok, false);
    assert.equal(result.ok === false && result.error, 'unknown message type');
  });

  it('rejects a join frame with a blank room id', () => {
    const result = parseClientMessage(
      JSON.stringify({ type: 'join', roomId: '   ', userId: 'alice', displayName: 'Alice' }),
    );
    assert.equal(result.ok, false);
    assert.equal(result.ok === false && result.error, 'roomId must be a non-empty string');
  });

  it('rejects a join frame whose room id is not a string', () => {
    const result = parseClientMessage(
      JSON.stringify({ type: 'join', roomId: 42, userId: 'alice', displayName: 'Alice' }),
    );
    assert.equal(result.ok, false);
  });

  it('rejects an over-long room id', () => {
    const result = parseClientMessage(
      JSON.stringify({
        type: 'join',
        roomId: 'x'.repeat(129),
        userId: 'alice',
        displayName: 'Alice',
      }),
    );
    assert.equal(result.ok, false);
  });

  it('rejects empty and whitespace-only text', () => {
    for (const text of ['', '   ']) {
      const result = parseClientMessage(JSON.stringify({ type: 'say', text }));
      assert.equal(result.ok, false);
      assert.equal(result.ok === false && result.error, 'text must not be empty');
    }
  });

  it('rejects text beyond the length cap', () => {
    const result = parseClientMessage(
      JSON.stringify({ type: 'say', text: 'y'.repeat(maxTextLength + 1) }),
    );
    assert.equal(result.ok, false);
    assert.equal(
      result.ok === false && result.error,
      `text must be at most ${maxTextLength} characters`,
    );
  });

  it('rejects a say frame whose text is not a string', () => {
    const result = parseClientMessage(JSON.stringify({ type: 'say', text: 123 }));
    assert.equal(result.ok, false);
    assert.equal(result.ok === false && result.error, 'text must be a string');
  });

  it('carries a speaker through when the host speaks for an AI character', () => {
    const result = parseClientMessage(
      JSON.stringify({
        type: 'say',
        text: '在的',
        speaker: { id: 'char-1', name: '小明' },
      }),
    );
    assert.equal(result.ok, true);
    assert.deepEqual(result.ok && result.value, {
      type: 'say',
      text: '在的',
      speaker: { id: 'char-1', name: '小明' },
    });
  });

  it('omits the speaker key entirely when absent', () => {
    // The relay carries ordinary member messages unchanged, so the key must not
    // appear as an explicit undefined.
    const result = parseClientMessage(JSON.stringify({ type: 'say', text: 'hi' }));
    assert.equal(result.ok, true);
    assert.equal(result.ok && 'speaker' in result.value, false);
  });

  for (const [label, speaker] of [
    ['a string', 'char-1'],
    ['null', null],
    ['an array', ['char-1']],
    ['a missing id', { name: '小明' }],
    ['a missing name', { id: 'char-1' }],
    ['an empty id', { id: '   ', name: '小明' }],
    ['an over-long name', { id: 'char-1', name: 'x'.repeat(maxDisplayNameLength + 1) }],
    ['a non-string id', { id: 7, name: '小明' }],
  ] as const) {
    it(`rejects a speaker that is ${label}`, () => {
      const result = parseClientMessage(
        JSON.stringify({ type: 'say', text: 'hello', speaker }),
      );
      assert.equal(result.ok, false);
      assert.equal(
        result.ok === false && result.error,
        'speaker must be an object with id and name',
      );
    });
  }
});
