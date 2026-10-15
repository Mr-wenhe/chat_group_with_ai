import { createHash } from 'node:crypto';
import { request as httpsRequest } from 'node:https';

import {
  isForbiddenHostname,
  pinnedLookup,
  resolvePublicAddresses,
} from './network_security.ts';
import { GatewayError } from './types.ts';
import type { GatewayConfig } from './types.ts';

const githubApiOrigin = 'https://api.github.com';
const githubHost = 'api.github.com';
const maxUpstreamResponseBytes = 512 * 1024;
const maxFiles = 32;
const maxDirectories = 32;
const maxFileBytes = 256 * 1024;
const maxPackBytes = 1024 * 1024;
const maxDirectoryDepth = 4;
const textExtensions = new Set([
  '.md', '.txt', '.yaml', '.yml', '.json', '.sh', '.py', '.js', '.ts',
  '.dart', '.html', '.css', '.xml', '.toml', '.csv',
]);
const assetExtensions = new Set(['.png', '.jpg', '.jpeg', '.webp', '.gif']);
const refPattern = /^[A-Za-z0-9._/-]{1,128}$/;
const shaPattern = /^[0-9a-f]{40}$/i;

export type GitHubSkillImportRequest = {
  owner: string;
  repo: string;
  path: string;
  ref: string;
};

export type GitHubSkillFile = {
  path: string;
  encoding: 'utf8' | 'base64';
  content: string;
  sha256: string;
};

export type GitHubSkillPack = {
  owner: string;
  repo: string;
  path: string;
  commit: string;
  license: string;
  files: GitHubSkillFile[];
};

type GitHubResponse = { statusCode: number; body: unknown };
export type GitHubSkillTransport = (
  url: URL,
  options: {
    timeoutMs: number;
    addresses: readonly string[];
    signal?: AbortSignal;
  },
) => Promise<GitHubResponse>;
export type GitHubAddressResolver = (hostname: string) => Promise<string[]>;

export function parseGitHubSkillImportRequest(
  value: unknown,
): GitHubSkillImportRequest {
  if (!isRecord(value) ||
      Object.keys(value).some((key) => !['owner', 'repo', 'path', 'ref'].includes(key)) ||
      Object.keys(value).length !== 4) {
    throw new GatewayError('INVALID_REQUEST', 400, false);
  }
  const owner = boundedString(value.owner, 100);
  const repo = boundedString(value.repo, 100);
  const path = boundedString(value.path, 500);
  const ref = boundedString(value.ref, 128);
  if (!/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,98}[A-Za-z0-9])?$/.test(owner) ||
      !/^[A-Za-z0-9](?:[A-Za-z0-9_.-]{0,98}[A-Za-z0-9])?$/.test(repo) ||
      !refPattern.test(ref) || ref.startsWith('/') || ref.endsWith('/') ||
      ref.split('/').some((segment) =>
        segment === '' || segment === '.' || segment === '..') ||
      !isSafeRepositoryPath(path)) {
    throw new GatewayError('INVALID_REQUEST', 400, false);
  }
  return { owner, repo, path, ref };
}

export async function importGitHubSkill(
  value: unknown,
  config: GatewayConfig,
  transport: GitHubSkillTransport = requestGitHubJson,
  addressResolver: GitHubAddressResolver = resolvePublicAddresses,
  signal?: AbortSignal,
): Promise<GitHubSkillPack> {
  const request = parseGitHubSkillImportRequest(value);
  if (isForbiddenHostname(githubHost)) {
    throw new GatewayError('UPSTREAM_DNS_BLOCKED', 502, false);
  }
  const root = request.path === 'SKILL.md'
    ? ''
    : request.path.endsWith('/SKILL.md')
      ? request.path.slice(0, -'/SKILL.md'.length)
      : request.path;
  if (root !== '' && root.split('/').some((part) =>
    part === '' || part === '.' || part === '..')) {
    throw new GatewayError('INVALID_REQUEST', 400, false);
  }

  const commitValue = shaPattern.test(request.ref)
    ? { sha: request.ref.toLowerCase() }
    : await githubGetJson(
      `/repos/${segment(request.owner)}/${segment(request.repo)}/commits/${segment(request.ref)}`,
      config, transport, addressResolver, signal,
    );
  const commit = stringAt(commitValue, 'sha');
  if (!shaPattern.test(commit)) {
    throw new GatewayError('UPSTREAM_INVALID_RESPONSE', 502, false);
  }
  let license = 'NOASSERTION';
  try {
    const licenseValue = await githubGetJson(
      `/repos/${segment(request.owner)}/${segment(request.repo)}/license?ref=${commit}`,
      config, transport, addressResolver, signal,
    );
    const spdx = isRecord(licenseValue) && isRecord(licenseValue.license)
      ? licenseValue.license.spdx_id
      : null;
    if (typeof spdx === 'string' && spdx.trim()) license = spdx.trim().slice(0, 100);
  } catch (error) {
    if (!(error instanceof GatewayError) || error.code !== 'UPSTREAM_NOT_FOUND') {
      throw error;
    }
  }

  const files: GitHubSkillFile[] = [];
  let directories = 0;
  let totalBytes = 0;
  async function walk(directory: string, depth: number): Promise<void> {
    if (depth > maxDirectoryDepth || ++directories > maxDirectories) {
      throw new GatewayError('INVALID_SKILL_PACK', 422, false);
    }
    const contents = await githubGetJson(
      `/repos/${segment(request.owner)}/${segment(request.repo)}/contents${directory ? `/${repositoryPath(directory)}` : ''}?ref=${commit}`,
      config, transport, addressResolver, signal,
    );
    if (!Array.isArray(contents)) {
      throw new GatewayError('INVALID_SKILL_PACK', 422, false);
    }
    for (const raw of contents) {
      if (!isRecord(raw)) throw new GatewayError('INVALID_SKILL_PACK', 422, false);
      const path = boundedString(raw.path, 500);
      const type = raw.type;
      if (!isSafeRepositoryPath(path) ||
          (root !== '' && path !== root && !path.startsWith(`${root}/`))) {
        throw new GatewayError('INVALID_SKILL_PACK', 422, false);
      }
      if (type === 'dir') {
        await walk(path, depth + 1);
        continue;
      }
      if (type !== 'file') throw new GatewayError('INVALID_SKILL_PACK', 422, false);
      const declaredSize = raw.size;
      const extension = extensionOf(path);
      if (typeof declaredSize !== 'number' || !Number.isSafeInteger(declaredSize) ||
          declaredSize < 0 || declaredSize > maxFileBytes ||
          (!textExtensions.has(extension) && !assetExtensions.has(extension)) ||
          files.length >= maxFiles) {
        throw new GatewayError('INVALID_SKILL_PACK', 422, false);
      }
      const body = await githubGetJson(
        `/repos/${segment(request.owner)}/${segment(request.repo)}/contents/${repositoryPath(path)}?ref=${commit}`,
        config, transport, addressResolver, signal,
      );
      if (!isRecord(body) || body.type !== 'file' || body.encoding !== 'base64' ||
          typeof body.content !== 'string') {
        throw new GatewayError('INVALID_SKILL_PACK', 422, false);
      }
      const compact = body.content.replace(/\s/g, '');
      if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(compact)) {
        throw new GatewayError('INVALID_SKILL_PACK', 422, false);
      }
      const bytes = Buffer.from(compact, 'base64');
      if (bytes.length !== declaredSize || bytes.length > maxFileBytes) {
        throw new GatewayError('INVALID_SKILL_PACK', 422, false);
      }
      totalBytes += bytes.length;
      if (totalBytes > maxPackBytes) {
        throw new GatewayError('INVALID_SKILL_PACK', 422, false);
      }
      const isText = textExtensions.has(extension);
      const text = isText ? bytes.toString('utf8') : undefined;
      if (isText && (text!.includes('\u0000') || !Buffer.from(text!, 'utf8').equals(bytes))) {
        throw new GatewayError('INVALID_SKILL_PACK', 422, false);
      }
      files.push({
        path: root === '' ? path : path.slice(root.length + 1),
        encoding: isText ? 'utf8' : 'base64',
        content: isText ? text! : bytes.toString('base64'),
        sha256: createHash('sha256').update(bytes).digest('hex'),
      });
    }
  }
  await walk(root, 0);
  if (!files.some((file) => file.path === 'SKILL.md')) {
    throw new GatewayError('INVALID_SKILL_PACK', 422, false);
  }
  files.sort((a, b) => a.path.localeCompare(b.path));
  validateLocalReferences(files);
  return {
    owner: request.owner,
    repo: request.repo,
    path: root || request.path,
    commit,
    license,
    files,
  };
}

function validateLocalReferences(files: readonly GitHubSkillFile[]): void {
  const names = new Set(files.map((file) => file.path));
  for (const file of files) {
    if (!file.path.toLowerCase().endsWith('.md')) continue;
    const text = file.content;
    if (/\b(?:https?|file):\/\//i.test(text)) {
      throw new GatewayError('INVALID_SKILL_PACK', 422, false);
    }
    const targets = [
      ...[...text.matchAll(/\]\(\s*<?([^\s)>]+)>?[^)]*\)/g)].map((match) => match[1]),
      ...[...text.matchAll(/^\s*\[[^\]]+\]:\s*<?([^\s>]+)>?/gm)].map((match) => match[1]),
      ...[...text.matchAll(/\b(?:href|src)\s*=\s*["']([^"']+)["']/gi)].map((match) => match[1]),
    ];
    for (const target of targets) {
      if (target.startsWith('#')) continue;
      if (target.startsWith('/') || target.includes('\\') ||
          /^(?:[a-z][a-z0-9+.-]*:|\/\/)/i.test(target)) {
        throw new GatewayError('INVALID_SKILL_PACK', 422, false);
      }
      let decoded: string;
      try {
        decoded = decodeURIComponent(target.split(/[?#]/)[0]);
      } catch {
        throw new GatewayError('INVALID_SKILL_PACK', 422, false);
      }
      const resolved = normalizeRelativePath(`${parent(file.path)}/${decoded}`);
      if (resolved == null || !names.has(resolved)) {
        throw new GatewayError('INVALID_SKILL_PACK', 422, false);
      }
    }
  }
}

function normalizeRelativePath(value: string): string | null {
  const parts: string[] = [];
  for (const part of value.split('/')) {
    if (part === '' || part === '.') continue;
    if (part === '..') {
      if (parts.length === 0) return null;
      parts.pop();
    } else {
      parts.push(part);
    }
  }
  return parts.join('/');
}

function parent(path: string): string {
  const index = path.lastIndexOf('/');
  return index < 0 ? '' : path.slice(0, index);
}

async function githubGetJson(
  path: string,
  config: GatewayConfig,
  transport: GitHubSkillTransport,
  addressResolver: GitHubAddressResolver,
  signal?: AbortSignal,
): Promise<unknown> {
  const url = new URL(path, githubApiOrigin);
  if (url.protocol !== 'https:' || url.hostname !== githubHost || isForbiddenHostname(url.hostname)) {
    throw new GatewayError('UPSTREAM_DNS_BLOCKED', 502, false);
  }
  const addresses = await withTimeout(
    addressResolver(githubHost), config.requestTimeoutMs, signal,
  );
  if (addresses.length === 0) throw new GatewayError('UPSTREAM_DNS_FAILED', 502, true);
  const response = await withTimeout(
    transport(url, { timeoutMs: config.requestTimeoutMs, addresses, signal }),
    config.requestTimeoutMs, signal,
  );
  if (response.statusCode < 200 || response.statusCode >= 300) {
    if (response.statusCode === 404) throw new GatewayError('UPSTREAM_NOT_FOUND', 404, false);
    if (response.statusCode === 429 || response.statusCode >= 500) {
      throw new GatewayError('UPSTREAM_UNAVAILABLE', 503, true);
    }
    throw new GatewayError('UPSTREAM_REJECTED', 502, false);
  }
  if (response.body == null) throw new GatewayError('UPSTREAM_INVALID_RESPONSE', 502, false);
  return response.body;
}

async function requestGitHubJson(
  url: URL,
  options: { timeoutMs: number; addresses: readonly string[]; signal?: AbortSignal },
): Promise<GitHubResponse> {
  return new Promise((resolve, reject) => {
    let settled = false;
    const finish = (error?: unknown, result?: GitHubResponse) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      options.signal?.removeEventListener('abort', abort);
      if (error != null) reject(error);
      else resolve(result!);
    };
    const request = httpsRequest(url, {
      method: 'GET',
      headers: {
        Accept: 'application/vnd.github+json',
        'User-Agent': 'chat-group-skill-importer',
        'X-GitHub-Api-Version': '2022-11-28',
      },
      lookup: pinnedLookup(options.addresses),
      servername: githubHost,
    }, (response) => {
      const chunks: Buffer[] = [];
      let total = 0;
      response.on('data', (chunk: Buffer) => {
        total += chunk.length;
        if (total > maxUpstreamResponseBytes) {
          response.destroy();
          finish(new GatewayError('UPSTREAM_INVALID_RESPONSE', 502, false));
          return;
        }
        chunks.push(chunk);
      });
      response.on('error', () => finish(new GatewayError('UPSTREAM_UNAVAILABLE', 503, true)));
      response.on('end', () => {
        const statusCode = response.statusCode ?? 502;
        if (statusCode < 200 || statusCode >= 300) {
          finish(undefined, { statusCode, body: {} });
          return;
        }
        try {
          finish(undefined, {
            statusCode,
            body: JSON.parse(Buffer.concat(chunks).toString('utf8')),
          });
        } catch {
          finish(new GatewayError('UPSTREAM_INVALID_RESPONSE', 502, false));
        }
      });
    });
    const timer = setTimeout(() => {
      request.destroy();
      finish(new GatewayError('UPSTREAM_TIMEOUT', 504, true));
    }, Math.max(1, options.timeoutMs));
    const abort = () => {
      request.destroy();
      finish(new GatewayError('UPSTREAM_CANCELLED', 499, false));
    };
    options.signal?.addEventListener('abort', abort, { once: true });
    if (options.signal?.aborted) abort();
    request.on('error', () => finish(new GatewayError('UPSTREAM_UNAVAILABLE', 503, true)));
    request.end();
  });
}

function withTimeout<T>(
  operation: Promise<T>,
  timeoutMs: number,
  signal?: AbortSignal,
): Promise<T> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new GatewayError('UPSTREAM_TIMEOUT', 504, true)),
      Math.max(1, timeoutMs),
    );
    const abort = () => reject(new GatewayError('UPSTREAM_CANCELLED', 499, false));
    const cleanup = () => {
      clearTimeout(timer);
      signal?.removeEventListener('abort', abort);
    };
    signal?.addEventListener('abort', abort, { once: true });
    if (signal?.aborted) abort();
    operation.then(
      (value) => { cleanup(); resolve(value); },
      (error) => { cleanup(); reject(error); },
    );
  });
}

function isSafeRepositoryPath(value: unknown): value is string {
  return typeof value === 'string' && value.length > 0 && value.length <= 500 &&
    !value.startsWith('/') && !value.includes('\\') && !value.includes('%') &&
    !/[\u0000-\u001f\u007f]/.test(value) &&
    value.split('/').every((part) => part.length > 0 && part !== '.' && part !== '..');
}

function boundedString(value: unknown, maximum: number): string {
  return typeof value === 'string' && value.length <= maximum ? value.trim() : '';
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value != null && typeof value === 'object' && !Array.isArray(value);
}

function stringAt(value: unknown, key: string): string {
  return isRecord(value) && typeof value[key] === 'string' ? value[key] as string : '';
}

function segment(value: string): string {
  return encodeURIComponent(value);
}

function repositoryPath(path: string): string {
  return path.split('/').map(encodeURIComponent).join('/');
}

function extensionOf(path: string): string {
  const name = path.slice(path.lastIndexOf('/') + 1);
  const dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.slice(dot).toLowerCase();
}
