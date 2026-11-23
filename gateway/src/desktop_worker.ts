import { importGitHubSkill } from './github_skill_upstream.ts';
import { createInterface } from 'node:readline';
import { once } from 'node:events';
import { fetchPublicWeb } from './public_web_transport.ts';
import { resolveWebAddresses } from './public_web_dns.ts';
import { GatewayError } from './types.ts';

// Private parent pipes only: never expose this transport as an HTTP URL proxy.
const pending = new Map<string, AbortController>();
async function emit(value: unknown): Promise<void> {
  if (!process.stdout.write(`${JSON.stringify(value)}\n`)) await once(process.stdout, 'drain');
}
async function handle(raw: string): Promise<void> {
  let id: string | undefined;
  try {
    const input = JSON.parse(raw);
    id = input.id;
    if (typeof id !== 'string' || !/^[a-zA-Z0-9_-]{1,80}$/.test(id)) return;
    if (input.operation === 'cancel') { pending.get(id)?.abort(); return; }
    if (pending.has(id) || pending.size >= 4) throw new GatewayError('WORKER_BUSY', 429, true);
    if (input.operation === 'hello') { await emit({ id, status: 'ok', version: 1 }); return; }
    if (input.operation !== 'github.import' &&
        (input.operation !== 'fetch' || typeof input.url !== 'string' || input.url.length > 4096)) {
      throw new GatewayError('INVALID_REQUEST', 400, false);
    }
    const controller = new AbortController();
    pending.set(id, controller);
    try {
      if (input.operation === 'github.import') {
        const signal = AbortSignal.any([controller.signal, AbortSignal.timeout(120000)]);
        const pack = await importGitHubSkill(input.arguments,
          { requestTimeoutMs: 25000 }, undefined,
          (hostname) => resolveWebAddresses(hostname, signal), signal);
        const bytes = Buffer.from(JSON.stringify(pack), 'utf8');
        await emit({ id, status: 'headers', url: 'https://api.github.com/', contentType: 'application/json' });
        for (let offset = 0; offset < bytes.length; offset += 65536) {
          controller.signal.throwIfAborted();
          await emit({ id, status: 'chunk', data: bytes.subarray(offset, offset + 65536).toString('base64') });
        }
        await emit({ id, status: 'done', byteLength: bytes.length });
        return;
      }
      const result = await fetchPublicWeb(input.url, input.maxBytes, controller.signal, {
        headers: async (url, contentType) => {
          await emit({ id, status: 'headers', url, contentType });
        },
        chunk: async (bytes) => {
          for (let offset = 0; offset < bytes.length; offset += 65536) {
            controller.signal.throwIfAborted();
            await emit({ id, status: 'chunk', data: bytes.subarray(offset, offset + 65536).toString('base64') });
          }
        },
      });
      await emit({ id, status: 'done', byteLength: result.byteLength });
    } finally { pending.delete(id); }
  } catch (error) {
    if (id) {
      const gatewayError = error instanceof GatewayError ? error : undefined;
      await emit({
        id,
        status: 'error',
        code: gatewayError?.code ?? 'REQUEST_FAILED',
        retryable: gatewayError?.retryable ?? false,
        ...(gatewayError?.code === 'SOURCE_HTTP_ERROR'
          ? { sourceStatus: gatewayError.statusCode }
          : {}),
      });
    }
  }
}
const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
lines.on('line', (line) => {
  if (Buffer.byteLength(line) > 8192) { lines.close(); process.stdin.destroy(); return; }
  void handle(line).catch(() => process.exit(1));
});
lines.on('close', () => {
  for (const controller of pending.values()) controller.abort();
});
