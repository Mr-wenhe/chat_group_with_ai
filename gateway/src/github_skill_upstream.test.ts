import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import test from 'node:test';

import {
  importGitHubSkill,
  parseGitHubSkillImportRequest,
} from './github_skill_upstream.ts';
import { GatewayError } from './types.ts';
import type { GatewayConfig } from './types.ts';

const config: GatewayConfig = {
  port: 0,
  provider: 'brave',
  providerApiKey: 'server-key',
  apiTokens: new Set(['client-token']),
  allowedOrigins: new Set(),
  allowUnauthenticatedDevelopment: false,
  requestTimeoutMs: 1000,
  rateLimitPerMinute: 60,
  quotaPerDay: 1000,
};
const commit = '0123456789abcdef0123456789abcdef01234567';
const skill = '---\nname: Demo\ndescription: Demo skill\nallowed-tools: Bash\n---\nRead [guide](references/guide.md).';
const script = '#!/bin/sh\necho checked\n';
const guide = '# Guide\n';
const simpleSkill = '---\nname: X\ndescription: X\n---\n';

test('imports referenced scripts and docs with every file pinned to one commit SHA', async () => {
  const requestedUrls: string[] = [];
  const pack = await importGitHubSkill(
    { owner: 'octo', repo: 'skills', path: 'skills/demo', ref: commit },
    config,
    async (url) => {
      requestedUrls.push(url.toString());
      if (url.pathname.endsWith('/license')) {
        assert.equal(url.searchParams.get('ref'), commit);
        return { statusCode: 200, body: { license: { spdx_id: 'MIT' } } };
      }
      if (url.pathname.endsWith('/contents/skills/demo')) {
        return { statusCode: 200, body: [
          file('skills/demo/SKILL.md', skill),
          directory('skills/demo/scripts'),
          directory('skills/demo/references'),
        ] };
      }
      if (url.pathname.endsWith('/contents/skills/demo/scripts')) {
        return { statusCode: 200, body: [file('skills/demo/scripts/check.sh', script)] };
      }
      if (url.pathname.endsWith('/contents/skills/demo/references')) {
        return { statusCode: 200, body: [file('skills/demo/references/guide.md', guide)] };
      }
      const path = decodeURIComponent(url.pathname);
      const content = path.endsWith('SKILL.md') ? skill :
        path.endsWith('check.sh') ? script : guide;
      return { statusCode: 200, body: base64File(content) };
    },
    async (host) => {
      assert.equal(host, 'api.github.com');
      return ['8.8.8.8'];
    },
  );

  assert.equal(pack.commit, commit);
  assert.equal(pack.license, 'MIT');
  assert.deepEqual(pack.files.map((entry) => entry.path), [
    'references/guide.md', 'scripts/check.sh', 'SKILL.md',
  ]);
  assert.ok(requestedUrls.every((url) => new URL(url).host === 'api.github.com'));
  assert.ok(requestedUrls
    .filter((url) => url.includes('/contents/'))
    .every((url) => url.includes(`?ref=${commit}`)));
});

test('resolves a branch once, then reads all content using its resulting SHA', async () => {
  const contentRefs: string[] = [];
  const pack = await importGitHubSkill(
    { owner: 'octo', repo: 'skills', path: 'skills/demo/SKILL.md', ref: 'main' },
    config,
    async (url) => {
      if (url.pathname.endsWith('/commits/main')) {
        return { statusCode: 200, body: { sha: commit } };
      }
      if (url.pathname.endsWith('/license')) {
        return { statusCode: 404, body: {} };
      }
      if (url.pathname.includes('/contents')) {
        contentRefs.push(url.searchParams.get('ref') ?? '');
      }
      if (url.pathname.endsWith('/contents/skills/demo')) {
        return { statusCode: 200, body: [file('skills/demo/SKILL.md', simpleSkill)] };
      }
      return { statusCode: 200, body: base64File(simpleSkill) };
    },
    async () => ['8.8.4.4'],
  );
  assert.equal(pack.commit, commit);
  assert.equal(pack.license, 'NOASSERTION');
  assert.deepEqual(contentRefs, [commit, commit]);
});

test('rejects arbitrary URL fields and repository traversal before network access', async () => {
  let called = false;
  const transport = async () => {
    called = true;
    return { statusCode: 200, body: {} };
  };
  for (const value of [
    { owner: 'octo', repo: 'skills', path: '../private', ref: commit },
    { owner: 'octo', repo: 'skills', path: 'skills/demo', ref: commit, url: 'https://evil.test' },
    { owner: 'octo', repo: 'skills', path: 'skills/%2e%2e/demo', ref: commit },
  ]) {
    await assert.rejects(
      importGitHubSkill(value, config, transport as never, async () => ['8.8.8.8']),
      (error: unknown) => error instanceof GatewayError && error.code === 'INVALID_REQUEST',
    );
  }
  assert.equal(called, false);
});

test('rejects symlinks, unsupported files, missing references, and external links', async () => {
  for (const entries of [
    [file('skills/demo/SKILL.md', skill), { path: 'skills/demo/escape', type: 'symlink', size: 0 }],
    [file('skills/demo/SKILL.md', skill), file('skills/demo/archive.zip', 'x')],
    [file('skills/demo/SKILL.md', skill.replace('references/guide.md', 'missing.md'))],
    [file('skills/demo/SKILL.md', skill.replace('[guide](references/guide.md)', '[guide](https://evil.test/x)'))],
  ]) {
    await assert.rejects(
      importGitHubSkill(
        { owner: 'octo', repo: 'skills', path: 'skills/demo', ref: commit },
        config,
        async (url) => {
          if (url.pathname.endsWith('/license')) {
            return { statusCode: 404, body: {} };
          }
          if (url.pathname.endsWith('/contents/skills/demo')) {
            return { statusCode: 200, body: entries };
          }
          const path = decodeURIComponent(url.pathname);
          const item = entries.find((entry) =>
            'path' in entry && path.endsWith(`/${String(entry.path)}`));
          const source = item != null && 'testContent' in item
            ? String(item.testContent)
            : path.endsWith('SKILL.md') ? skill : guide;
          return { statusCode: 200, body: base64File(source) };
        },
        async () => ['8.8.8.8'],
      ),
      (error: unknown) => error instanceof GatewayError && error.code === 'INVALID_SKILL_PACK',
    );
  }
});

test('records unknown license and rejects resource paths outside the skill root', async () => {
  assert.throws(
    () => parseGitHubSkillImportRequest({
      owner: 'octo', repo: 'skills', path: 'skills/../demo', ref: commit,
    }),
    (error: unknown) => error instanceof GatewayError && error.code === 'INVALID_REQUEST',
  );
  const pack = await importGitHubSkill(
    { owner: 'octo', repo: 'skills', path: 'skills/demo', ref: commit },
    config,
    async (url) => {
      if (url.pathname.endsWith('/license')) {
        return { statusCode: 200, body: { license: { spdx_id: 'NOASSERTION' } } };
      }
      if (url.pathname.endsWith('/contents/skills/demo')) {
        return { statusCode: 200, body: [file('skills/demo/SKILL.md', simpleSkill)] };
      }
      return { statusCode: 200, body: base64File(simpleSkill) };
    },
    async () => ['8.8.8.8'],
  );
  assert.equal(pack.license, 'NOASSERTION');
});

test('imports a root-level skill and bounds recursive directory discovery', async () => {
  const requested: string[] = [];
  const pack = await importGitHubSkill(
    { owner: 'octo', repo: 'skills', path: 'SKILL.md', ref: commit },
    config,
    async (url) => {
      requested.push(url.pathname);
      if (url.pathname.endsWith('/license')) {
        return { statusCode: 404, body: {} };
      }
      if (url.pathname.endsWith('/contents')) {
        return { statusCode: 200, body: [file('SKILL.md', simpleSkill)] };
      }
      return { statusCode: 200, body: base64File(simpleSkill) };
    },
    async () => ['8.8.8.8'],
  );
  assert.equal(pack.path, 'SKILL.md');
  assert.ok(requested.some((path) => path.endsWith('/contents')));
});

function file(path: string, content: string) {
  return { path, type: 'file', size: Buffer.byteLength(content), testContent: content };
}

function directory(path: string) {
  return { path, type: 'dir', size: 0 };
}

function base64File(content: string) {
  return {
    type: 'file',
    encoding: 'base64',
    content: Buffer.from(content).toString('base64'),
  };
}
