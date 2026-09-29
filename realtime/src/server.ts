/**
 * Realtime relay for shared group chats.
 *
 * Responsibilities are deliberately narrow: keep track of who is in which room,
 * assign a monotonic sequence number to every message, and fan messages out.
 * It stores nothing on disk and knows nothing about AI characters — the Flutter
 * client owns all of that.
 */

import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';
import { WebSocket, WebSocketServer } from 'ws';
import { isAuthorized, loadConfig } from './config.ts';
import { createGroupRegistry } from './group_registry.ts';
import { createGroupApiHandler } from './http_api.ts';
import { createRoomRegistry } from './room_registry.ts';
import { parseClientMessage, type ServerMessage, type Speaker } from './protocol.ts';

/** Frames larger than this are rejected by the WebSocket layer itself. */
const maxPayloadBytes = 64 * 1024;

const config = loadConfig();
const registry = createRoomRegistry({ recentLimit: config.recentMessageLimit });
const groups = createGroupRegistry();
const handleGroupApi = createGroupApiHandler(groups, config);

interface Connection {
  readonly id: string;
  isAlive: boolean;
  /** Cleared once the socket joins; unauthenticated sockets are dropped. */
  joinTimer: NodeJS.Timeout | null;
}

const connectionBySocket = new Map<WebSocket, Connection>();
const socketByConnectionId = new Map<string, WebSocket>();

const httpServer = createServer((request, response) => {
  if (request.url === '/healthz') {
    response.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' });
    response.end(JSON.stringify({ ok: true, connections: connectionBySocket.size }));
    return;
  }
  handleGroupApi(request, response)
    .then((handled) => {
      if (handled) return;
      response.writeHead(404, { 'cache-control': 'no-store' });
      response.end();
    })
    .catch((error: unknown) => {
      console.error('group api failed:', error);
      // A rejection here means the handler threw before responding, so headers
      // are untouched; guard anyway rather than throw inside the catch.
      if (response.headersSent) {
        response.destroy();
        return;
      }
      response.writeHead(500, { 'content-type': 'application/json', 'cache-control': 'no-store' });
      response.end(JSON.stringify({ error: 'INTERNAL_ERROR' }));
    });
});

const webSocketServer = new WebSocketServer({ noServer: true, maxPayload: maxPayloadBytes });

// Authentication happens during the HTTP upgrade: an unauthorized client never
// reaches the WebSocket layer.
httpServer.on('upgrade', (request, socket, head) => {
  const url = new URL(request.url ?? '/', 'http://placeholder');
  if (!isAuthorized(url.searchParams.get('token'), config)) {
    socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
    socket.destroy();
    return;
  }
  webSocketServer.handleUpgrade(request, socket, head, (ws) => {
    webSocketServer.emit('connection', ws, request);
  });
});

webSocketServer.on('connection', (ws) => {
  const connection: Connection = { id: randomUUID(), isAlive: true, joinTimer: null };
  connectionBySocket.set(ws, connection);
  socketByConnectionId.set(connection.id, ws);

  // A socket that authenticates but never joins would otherwise linger forever.
  connection.joinTimer = setTimeout(() => {
    send(ws, { type: 'error', code: 'JOIN_TIMEOUT', message: 'no join message received' });
    ws.close();
  }, config.joinTimeoutMs);

  ws.on('pong', () => {
    connection.isAlive = true;
  });

  ws.on('message', (data) => {
    const parsed = parseClientMessage(data.toString());
    if (!parsed.ok) {
      send(ws, { type: 'error', code: 'BAD_REQUEST', message: parsed.error });
      return;
    }
    if (parsed.value.type === 'join') {
      handleJoin(ws, connection, parsed.value);
    } else {
      handleSay(ws, connection, parsed.value);
    }
  });

  ws.on('close', () => handleDisconnect(ws, connection));
  ws.on('error', () => ws.terminate());
});

function handleJoin(
  ws: WebSocket,
  connection: Connection,
  join: { roomId: string; userId: string; displayName: string },
): void {
  if (registry.roomOf(connection.id) !== undefined) {
    send(ws, { type: 'error', code: 'ALREADY_JOINED', message: 'this socket already joined a room' });
    return;
  }
  if (registry.connectionsIn(join.roomId).length >= config.maxConnectionsPerRoom) {
    send(ws, { type: 'error', code: 'ROOM_FULL', message: 'room is at capacity' });
    return;
  }
  if (connection.joinTimer !== null) {
    clearTimeout(connection.joinTimer);
    connection.joinTimer = null;
  }

  const outcome = registry.join(join.roomId, connection.id, {
    userId: join.userId,
    displayName: join.displayName,
  });

  send(ws, {
    type: 'joined',
    roomId: outcome.roomId,
    seq: outcome.seq,
    members: outcome.members,
    recent: outcome.recent,
  });
  // The joiner already has the member list from `joined`, so presence goes to
  // everyone else.
  broadcast(
    outcome.roomId,
    {
      type: 'presence',
      event: 'join',
      member: { userId: join.userId, displayName: join.displayName },
      members: outcome.members,
    },
    connection.id,
  );
}

function handleSay(
  ws: WebSocket,
  connection: Connection,
  say: { text: string; speaker?: Speaker },
): void {
  const message = registry.append(connection.id, say.text, Date.now(), say.speaker);
  if (message === null) {
    send(ws, { type: 'error', code: 'NOT_JOINED', message: 'join a room before sending' });
    return;
  }
  // Broadcast to everyone including the sender: the sender needs the
  // server-assigned sequence number to reconcile its local copy.
  broadcast(message.roomId, message);
}

function handleDisconnect(ws: WebSocket, connection: Connection): void {
  if (connection.joinTimer !== null) clearTimeout(connection.joinTimer);
  connectionBySocket.delete(ws);
  socketByConnectionId.delete(connection.id);

  const departed = registry.leave(connection.id);
  if (departed === null) return;
  broadcast(departed.roomId, {
    type: 'presence',
    event: 'leave',
    member: departed.member,
    members: departed.members,
  });
}

function broadcast(roomId: string, message: ServerMessage, exceptConnectionId?: string): void {
  for (const connectionId of registry.connectionsIn(roomId)) {
    if (connectionId === exceptConnectionId) continue;
    const socket = socketByConnectionId.get(connectionId);
    if (socket !== undefined) send(socket, message);
  }
}

function send(ws: WebSocket, message: ServerMessage): void {
  if (ws.readyState !== WebSocket.OPEN) return;
  ws.send(JSON.stringify(message));
}

// Detect half-open connections, which a public server sees routinely when a
// client's network drops without a close frame.
setInterval(() => {
  for (const [ws, connection] of connectionBySocket) {
    if (!connection.isAlive) {
      ws.terminate();
      continue;
    }
    connection.isAlive = false;
    ws.ping();
  }
}, config.heartbeatIntervalMs);

httpServer.listen(config.port, () => {
  const mode = config.sharedToken === null ? 'UNAUTHENTICATED (development)' : 'token-authenticated';
  console.log(`realtime relay listening on :${config.port} [${mode}]`);
});

for (const signal of ['SIGINT', 'SIGTERM'] as const) {
  process.on(signal, () => {
    console.log(`received ${signal}, shutting down`);
    for (const ws of connectionBySocket.keys()) ws.close(1001, 'server shutting down');
    webSocketServer.close(() => httpServer.close(() => process.exit(0)));
  });
}
