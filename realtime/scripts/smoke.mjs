// End-to-end smoke test: connect two clients to a relay, have one speak, and
// assert the other receives it with a server-assigned sequence number.
//
//   node scripts/smoke.mjs ws://localhost:9100 <token> [roomId]
//
// Exits 0 on success, 1 on failure. Run it against the deployed host after a
// rollout to prove the relay is actually reachable through the firewall.
import { WebSocket } from 'ws';

const [, , url, token, roomId = 'smoke-room'] = process.argv;
if (!url || !token) {
  console.error('usage: node scripts/smoke.mjs <ws-url> <token> [roomId]');
  process.exit(2);
}

const timeoutMs = 10_000;
const target = `${url}/?token=${encodeURIComponent(token)}`;

function connect(clientId) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(target);
    const timer = setTimeout(() => reject(new Error(`${clientId}: timed out`)), timeoutMs);
    socket.on('open', () => {
      clearTimeout(timer);
      resolve(socket);
    });
    socket.on('error', (error) => {
      clearTimeout(timer);
      reject(new Error(`${clientId}: ${error.message}`));
    });
  });
}

/** Resolves with the first frame matching `predicate`. */
function waitFor(socket, predicate, label) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`timed out waiting for ${label}`)), timeoutMs);
    const onMessage = (data) => {
      const frame = JSON.parse(data.toString());
      if (!predicate(frame)) return;
      clearTimeout(timer);
      socket.off('message', onMessage);
      resolve(frame);
    };
    socket.on('message', onMessage);
  });
}

try {
  const alice = await connect('alice');
  const bob = await connect('bob');

  // Every listener is registered BEFORE the frame that triggers it. Sending
  // first and awaiting second is a race that localhost hides and a real network
  // exposes: `ws` does not replay messages to late subscribers, so a reply that
  // lands while the previous `await` is still resuming is simply lost.
  const aliceJoinedPromise = waitFor(alice, (f) => f.type === 'joined', 'alice joined');
  alice.send(JSON.stringify({ type: 'join', roomId, userId: 'alice', displayName: 'Alice' }));
  const aliceJoined = await aliceJoinedPromise;
  console.log(`alice joined ${aliceJoined.roomId} at seq ${aliceJoined.seq}`);

  const bobJoinedPromise = waitFor(bob, (f) => f.type === 'joined', 'bob joined');
  // The first joiner must learn about the second through presence, so this
  // listener must already exist when bob's join is broadcast.
  const presencePromise = waitFor(
    alice,
    (f) => f.type === 'presence' && f.event === 'join',
    'presence',
  );
  bob.send(JSON.stringify({ type: 'join', roomId, userId: 'bob', displayName: 'Bob' }));
  const bobJoined = await bobJoinedPromise;
  console.log(`bob joined ${bobJoined.roomId}, members: ${bobJoined.members.map((m) => m.displayName).join(', ')}`);

  const presence = await presencePromise;
  console.log(`alice saw presence join for ${presence.member.displayName}`);

  const expectedSeq = bobJoined.seq + 1;
  const receivedByAlice = waitFor(alice, (f) => f.type === 'msg', 'message');
  const receivedByBob = waitFor(bob, (f) => f.type === 'msg', 'message');
  alice.send(JSON.stringify({ type: 'say', text: 'hello from Alice' }));

  const [seenByAlice, seenByBob] = await Promise.all([receivedByAlice, receivedByBob]);

  const failures = [];
  if (seenByAlice.seq !== expectedSeq) failures.push(`alice saw seq ${seenByAlice.seq}, expected ${expectedSeq}`);
  if (seenByBob.seq !== expectedSeq) failures.push(`bob saw seq ${seenByBob.seq}, expected ${expectedSeq}`);
  if (seenByBob.text !== 'hello from Alice') failures.push(`bob saw text ${JSON.stringify(seenByBob.text)}`);
  if (seenByBob.displayName !== 'Alice') failures.push(`bob saw sender ${seenByBob.displayName}`);
  // The sender must receive its own message so it learns the assigned sequence.
  if (seenByAlice.userId !== 'alice') failures.push('alice did not receive her own message');

  // Round two: alice relays a line on behalf of one of the AI characters she
  // runs. Bob must be able to tell it apart from alice speaking in person —
  // this is the whole reason the speaker field exists.
  const relayedByBob = waitFor(bob, (f) => f.type === 'msg' && f.seq > seenByBob.seq, 'relayed message');
  alice.send(
    JSON.stringify({
      type: 'say',
      text: '大家好，我是阿离',
      speaker: { id: 'char-1', name: '阿离' },
    }),
  );
  const relayed = await relayedByBob;

  if (relayed.speaker?.name !== '阿离') {
    failures.push(`bob saw speaker ${JSON.stringify(relayed.speaker)}, expected 阿离`);
  }
  // The relaying account stays alice: the server never rewrites identity.
  if (relayed.userId !== 'alice') failures.push(`relayed userId was ${relayed.userId}, expected alice`);

  // Round three: an ordinary member message must not grow a speaker field.
  const plainByBob = waitFor(bob, (f) => f.type === 'msg' && f.seq > relayed.seq, 'plain message');
  alice.send(JSON.stringify({ type: 'say', text: '这条是我自己说的' }));
  const plain = await plainByBob;
  if ('speaker' in plain) failures.push(`plain message carried a speaker: ${JSON.stringify(plain.speaker)}`);

  // Round four: the invite-code repair path over real HTTP. Registering the
  // same room twice has to be a no-op the second time — that is what lets a host
  // re-mint a code after a restart without stranding guests who already hold
  // the room id.
  const httpBase = url.replace(/^ws/, 'http');
  const inviteRoomId = `${roomId}-invite`;
  const registered = [];
  for (let attempt = 0; attempt < 2; attempt += 1) {
    const response = await fetch(`${httpBase}/v1/groups`, {
      method: 'POST',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      body: JSON.stringify({
        name: '冒烟测试群',
        hostUserId: 'smoke-host',
        hostDisplayName: '冒烟',
        roomId: inviteRoomId,
      }),
    });
    registered.push({ status: response.status, body: await response.json() });
  }

  const [first, second] = registered;
  if (first.status !== 201) failures.push(`first registration returned ${first.status}, expected 201`);
  if (second.status !== 200) failures.push(`second registration returned ${second.status}, expected 200`);
  if (first.body.roomId !== inviteRoomId) {
    failures.push(`server returned room ${first.body.roomId}, expected ${inviteRoomId}`);
  }
  if (second.body.inviteCode !== first.body.inviteCode) {
    failures.push('re-registering the same room rotated the invite code');
  }

  // The code it just handed back has to resolve to that same room.
  const resolved = await fetch(`${httpBase}/v1/groups/${first.body.inviteCode}`, {
    headers: { authorization: `Bearer ${token}` },
  });
  const resolvedBody = await resolved.json();
  if (resolved.status !== 200 || resolvedBody.roomId !== inviteRoomId) {
    failures.push(
      `invite code ${first.body.inviteCode} resolved to ${resolved.status} ${JSON.stringify(resolvedBody)}`,
    );
  }
  console.log(`invite code ${first.body.inviteCode} registered once and re-registered idempotently`);

  alice.close();
  bob.close();

  if (failures.length > 0) {
    console.error('\nSMOKE TEST FAILED:');
    for (const failure of failures) console.error(`  - ${failure}`);
    // A hard exit on purpose: a socket may still be mid-connect and would hold
    // the loop open for as long as the OS takes to give up on it.
    process.exit(1);
  }
  console.log(`\nSMOKE TEST PASSED: message seq ${seenByBob.seq} delivered to both clients`);
  // Setting the code rather than calling process.exit() lets the loop drain
  // first. Exiting outright while an HTTP request handle is still unwinding
  // trips a libuv assertion on Windows (`!(handle->flags & UV_HANDLE_CLOSING)`)
  // and the process dies with 127 — a passing run would report failure.
  process.exitCode = 0;
} catch (error) {
  console.error(`\nSMOKE TEST FAILED: ${error.message}`);
  process.exit(1);
}
