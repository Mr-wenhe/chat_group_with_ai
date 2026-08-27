# Search Gateway

Production search endpoint for the Flutter app. The gateway is intentionally a
fixed upstream proxy, not a general URL fetcher: a client can submit only a
search query to `POST /v1/search`; it can never choose a destination URL.

## Security properties

- The deployment selects exactly one configured upstream (`brave` or `tavily`)
  and keeps that Provider key in environment variables.
- Every upstream request resolves the configured host immediately before use,
  rejects loopback/private/link-local/reserved IPs, then pins the verified IP
  in the TLS connection lookup. `https.request` does not follow redirects.
- Production requires bearer-token authentication. The unauthenticated mode is
  available only with `NODE_ENV != production` and explicit opt-in.
- Browser access is disabled by default. A separately authorized browser
  client may set `ALLOWED_ORIGINS` to exact company HTTPS origins; wildcards,
  paths, query parameters, and non-HTTPS origins are rejected. The Flutter
  app intentionally exposes no Web Release search route because browser
  builds cannot provide the app's native endpoint pinning and credential
  boundary.
- A per-token/IP in-memory 60-second rate limit, daily quota, request-size
  cap, bounded request-body/headers/keep-alive timeouts, upstream timeout,
  3-failure/30-second circuit breaker, response-size cap, and no-store
  responses reduce abuse impact.
- Logs contain only request ID and status; neither query nor credentials nor
  upstream response bodies are logged or returned on failure.

## Run locally

```bash
cd gateway
cp .env.example .env
# Edit .env with a real provider key and a distinct client token.
set -a; source .env; set +a
npm test
npm start
```

For a local, unauthenticated smoke test only, set
`ALLOW_UNAUTHENTICATED_DEV=true`; never use that setting in production.

## Deployment

Run `npm start` under the company's existing process supervisor or platform.
Inject environment variables through that platform's secret manager; do not
create or commit a production `.env` file. The process binds to `PORT` on
`0.0.0.0` and should sit behind the company's HTTPS ingress.

Set `DAILY_QUOTA` to the maximum accepted searches per authenticated principal
in a rolling 24-hour window (default: 1000). The in-memory quota and circuit
breaker are per process; production deployments should use a shared store when
running more than one Gateway instance.

The Flutter Gateway provider expects the configured base URL without the path,
for example `https://search.example.com`; it calls `/v1/search` and sends its
credential as `Authorization: Bearer ...`.
