# Realtime Relay

WebSocket relay that lets several clients share one group chat.

It does three things and nothing else:

1. Tracks which connections are in which room.
2. Assigns a monotonic sequence number to every message — this is the single
   authority on message order, and the reason a server exists at all.
3. Fans messages out to the room.

It stores nothing on disk and knows nothing about AI characters. Persistence,
identity of AI members, and reply generation all live in the Flutter client.

## Protocol

JSON frames, one object per WebSocket message.

Client to server:

```jsonc
{ "type": "join", "roomId": "group-1", "userId": "alice", "displayName": "Alice" }
{ "type": "say",  "text": "hello" }
// speaker is optional; see "Speaking for someone else" below.
{ "type": "say",  "text": "hello", "speaker": { "id": "char-1", "name": "阿离" } }
```

Server to client:

```jsonc
{ "type": "joined", "roomId": "group-1", "seq": 0, "members": [...], "recent": [...] }
{ "type": "msg", "roomId": "group-1", "seq": 1, "userId": "alice", "displayName": "Alice", "text": "hello", "sentAt": 1699999999999 }
{ "type": "presence", "event": "join", "member": {...}, "members": [...] }
{ "type": "error", "code": "ROOM_FULL", "message": "..." }
```

`say` is broadcast to **every** member including the sender, so the sender
learns the sequence number the server assigned and can reconcile its local copy.

### Speaking for someone else

All AI generation happens on the host's device. The host therefore relays its
characters' replies over its own connection, which would otherwise make every AI
line arrive looking like something the host said in person.

`speaker` carries the real author. `userId`/`displayName` keep describing the
account that sent the frame — the server never rewrites identity, and it does not
interpret `speaker` at all; it only validates the shape (`id` and `name`, both
non-empty and within `maxUserIdLength` / `maxDisplayNameLength`) and passes it
through. A `say` without `speaker` produces a `msg` with no `speaker` key, so the
frame is byte-identical to the pre-`speaker` protocol for ordinary members.

This is a labelling mechanism, not an authorization one: a client can claim any
speaker it likes. That is acceptable here only because the host is the only party
running AI characters — it is **not** justified by the shared token. A room is
gated by the token only when the deployment enforces one, and the deployment on
`120.26.241.84:9210` deliberately does not (see "No authentication" below). With
or without a token, anyone who learns a room id can join it and post as any
speaker.

Error codes: `BAD_REQUEST`, `JOIN_TIMEOUT`, `ALREADY_JOINED`, `ROOM_FULL`,
`NOT_JOINED`.

## Run locally

```bash
cd realtime
npm install
cp .env.example .env
set -a; source .env; set +a
npm test
npm start
```

For a local smoke test without a token, set `ALLOW_UNAUTHENTICATED_DEV=true`.
That is rejected whenever `NODE_ENV=production`.

`scripts/deploy.py` does the same thing remotely and deliberately — see "No
authentication" below before reading that flag as a smoke-test-only convenience.

## Deploy

```bash
# On the server
cd /opt/chat-group-realtime
npm install --omit=dev

# Provide the secret through the environment, not a committed file.
export REALTIME_SHARED_TOKEN='<generated>'
export PORT=9210
node --experimental-strip-types src/server.ts
```

`PORT` defaults to `9210` rather than the more obvious `9100`, because `9100` is
Dart DevTools' default and a running DevTools binds `127.0.0.1:9100` without
conflicting with our `0.0.0.0` bind, silently swallowing local connections.

Run it under `systemd` so it survives a reboot:

```ini
[Unit]
Description=Chat group realtime relay
After=network.target

[Service]
WorkingDirectory=/opt/chat-group-realtime
EnvironmentFile=/etc/chat-group-realtime.env
ExecStart=/usr/bin/node --experimental-strip-types src/server.ts
Restart=always
User=realtime

[Install]
WantedBy=multi-user.target
```

### Open the port

The service binds to `PORT`, but reachability is a **cloud console** setting.
For Aliyun that is the ECS **security group** inbound rule — adding a rule with
`ufw` or `iptables` over SSH does not open it, because the security group is
enforced outside the instance. Add an inbound TCP rule for the chosen port
before testing from a client.

### No TLS

The relay speaks plain `ws://`, so anything sent to it — the shared token when
there is one, and every message regardless — crosses the network in clear text.
That is acceptable only because this is a course demo. Anything real needs
`wss://` behind a reverse proxy with a certificate.

### No authentication

`scripts/deploy.py` accepts `RT_ALLOW_UNAUTHENTICATED=true`, which rewrites the
server env file to set `ALLOW_UNAUTHENTICATED_DEV=true` and to **remove**
`NODE_ENV`, because `config.ts` honours the bypass only while
`NODE_ENV !== 'production'`. Leaving `NODE_ENV` in place makes the deploy report
success while every client still gets 401, so the script drops it and then
verifies from the client side that an unauthenticated `POST /v1/groups`
really returns 201.

This is what makes joining a group zero-config on the client: no token to type
in, nothing stored in the keychain. The cost is that the relay is open to anyone
who knows the address, invite codes are brute-forceable, and groups can be
registered without credentials. It is a deliberate trade for a course demo, not
an oversight — turning it back on is one deploy without the flag, but every
client then needs the token before it can join anything.

## Health check

`GET /healthz` returns `{"ok":true,"connections":<n>}`. It is unauthenticated
and reveals only a connection count.

## Known limitations

- **In-memory only.** Restarting the server loses every room; a client
  reconnecting to an emptied room starts again from sequence 0.
- **No message persistence or history API.** A client that was offline longer
  than the `recent` replay buffer cannot recover the gap from the server.
- **Rooms are not gated by the group registry.** Any `roomId` string is accepted
  on join; the registry exists only to turn an invite code into a room, and it
  is not consulted when a client connects. Membership is whatever the live
  connection list happens to hold.
- **Invite codes do not survive a restart.** The registry is in-memory too, so
  after a restart an old code resolves to 404 for anyone who has not already
  joined. Clients that already hold a `roomId` keep working, because joining a
  room that no longer exists simply recreates it. `POST /v1/groups` with the
  room's own `roomId` is how that gets repaired: the server mints a fresh code
  for the *same* room, so guests already pointed at it are not stranded. The
  host client does this every time it opens the invite sheet and tells the host
  when the code it was about to read aloud has changed.
- **Single process.** Sequence numbers are per-process, so this cannot be
  horizontally scaled.
